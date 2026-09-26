package ir.neovortex.wingdrop

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.io.File
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Video shrinking that never takes frames off the GPU: the hardware decoder
 * renders into a texture, one GL draw scales (and trims a few edge pixels to
 * keep the shape), and the hardware encoder reads straight from that surface.
 * No copies through the CPU and no software scaling, which is what the FFmpeg
 * path spends most of its time on.
 *
 * Writes a video-only MP4; [MediaShrinker] then adds the audio natively.
 * Throws [Unsupported] for inputs the FFmpeg path handles better (HDR, Dolby
 * Vision, no hardware codec), so the caller can fall back.
 */
class GpuShrinker(private val cancel: AtomicBoolean, private val onProgress: (Double) -> Unit) {
    class Unsupported(why: String) : Exception(why)

    fun videoOnly(input: FileDescriptor, out: File, preset: Int) {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(input)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: throw Unsupported("no video track")
            val fmt = ex.getTrackFormat(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            if (mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) throw Unsupported("dolby vision")
            val transfer = fmt.int(MediaFormat.KEY_COLOR_TRANSFER, 0)
            // HDR needs tone mapping to look right in 8-bit; leave it to FFmpeg.
            if (transfer == MediaFormat.COLOR_TRANSFER_ST2084 || transfer == MediaFormat.COLOR_TRANSFER_HLG) throw Unsupported("hdr")
            ex.selectTrack(track)
            transcode(ex, fmt, out, preset)
        } finally {
            ex.release()
        }
    }

    private fun transcode(ex: MediaExtractor, fmt: MediaFormat, out: File, preset: Int) {
        val w = fmt.getInteger(MediaFormat.KEY_WIDTH)
        val h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
        val durationUs = fmt.long(MediaFormat.KEY_DURATION, 0)
        val rotation = fmt.int(MediaFormat.KEY_ROTATION, 0)
        val fps = fmt.int(MediaFormat.KEY_FRAME_RATE, 30).coerceIn(1, 60)

        // Same targets as the FFmpeg path (they live in media.cpp).
        val plan = NativeEngine.nativeVideoPlan(preset)
        val scale = min(1.0, plan[0] / max(w, h))
        // Multiples of 16 suit every hardware encoder; the few pixels this
        // changes are trimmed from the edges, never stretched.
        val ow = max(64, (w * scale / 16).roundToInt() * 16)
        val oh = max(64, (h * scale / 16).roundToInt() * 16)
        val srcBitrate = fmt.int(MediaFormat.KEY_BIT_RATE, 0).toDouble()

        val enc = openEncoder(ow, oh, fps, plan, srcBitrate)
        var dec: MediaCodec? = null
        var egl: Egl? = null
        var muxer: MediaMuxer? = null
        var frames: Frames? = null
        var decSurface: Surface? = null
        val cbThread = HandlerThread("gpu-shrink-frames").apply { start() }
        try {
            egl = Egl(enc.codec.createInputSurface())
            enc.codec.start()
            val fr = Frames(cbThread)
            frames = fr
            val decoder = MediaCodec.createByCodecName(
                MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(fmt.apply {
                    // Some extractors report a frame rate the decoder check trips on.
                    removeKey(MediaFormat.KEY_FRAME_RATE)
                }) ?: throw Unsupported("no decoder"),
            )
            dec = decoder
            decSurface = Surface(fr.texture)
            decoder.configure(fmt, decSurface, null, 0)
            decoder.start()

            val mux = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            mux.setOrientationHint(rotation)
            val drawer = Drawer(w, h, ow, oh)
            var muxTrack = -1
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var decodeDone = false
            var encodeDone = false

            fun drainEncoder(timeoutUs: Long) {
                while (true) {
                    val i = enc.codec.dequeueOutputBuffer(info, timeoutUs)
                    when {
                        i == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                        i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            muxTrack = mux.addTrack(enc.codec.outputFormat)
                            mux.start()
                        }
                        i >= 0 -> {
                            val buf = enc.codec.getOutputBuffer(i)!!
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                            if (info.size > 0 && muxTrack >= 0) mux.writeSampleData(muxTrack, buf, info)
                            enc.codec.releaseOutputBuffer(i, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                encodeDone = true
                                return
                            }
                        }
                    }
                }
            }

            while (!encodeDone) {
                if (cancel.get()) throw InterruptedException("cancelled")
                if (!inputDone) {
                    val i = decoder.dequeueInputBuffer(2_000)
                    if (i >= 0) {
                        val n = ex.readSampleData(decoder.getInputBuffer(i)!!, 0)
                        if (n < 0) {
                            decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                if (!decodeDone) {
                    val o = decoder.dequeueOutputBuffer(info, 2_000)
                    if (o >= 0) {
                        val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        val render = info.size > 0
                        val pts = info.presentationTimeUs
                        decoder.releaseOutputBuffer(o, render)
                        if (render) {
                            fr.await()
                            fr.texture.updateTexImage()
                            fr.texture.getTransformMatrix(drawer.texMatrix)
                            drawer.draw(fr.textureId)
                            egl.present(pts * 1000)
                            if (durationUs > 0) onProgress((pts.toDouble() / durationUs).coerceIn(0.0, 0.99))
                        }
                        if (eos) {
                            decodeDone = true
                            enc.codec.signalEndOfInputStream()
                        }
                    }
                }
                drainEncoder(if (decodeDone) 10_000 else 0)
            }
            if (muxTrack < 0) throw IllegalStateException("encoder produced nothing")
            Diag.i(TAG, "gpu: ${w}x$h -> ${ow}x$oh ${enc.name} ${enc.bitrate / 1000} kbps")
        } finally {
            runCatching { dec?.stop() }
            runCatching { dec?.release() }
            runCatching { enc.codec.stop() }
            runCatching { enc.codec.release() }
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            decSurface?.release()
            frames?.texture?.release()
            egl?.release()
            cbThread.quitSafely()
        }
    }

    private class Encoder(val codec: MediaCodec, val name: String, val bitrate: Int)

    /** HEVC on hardware if it takes this size, else H.264 (which gets 1.35x the bits). */
    private fun openEncoder(ow: Int, oh: Int, fps: Int, plan: DoubleArray, srcBitrate: Double): Encoder {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        for ((mime, factor) in listOf(MediaFormat.MIMETYPE_VIDEO_HEVC to 1.0, MediaFormat.MIMETYPE_VIDEO_AVC to 1.35)) {
            var target = ow.toDouble() * oh * fps * plan[1] * factor
            if (srcBitrate > 0) target = min(target, srcBitrate * plan[2])
            target = max(target, 400e3)
            for (info in list) {
                if (!info.isEncoder || !info.isHardwareAccelerated || mime !in info.supportedTypes) continue
                val caps = info.getCapabilitiesForType(mime)
                if (caps.videoCapabilities?.isSizeSupported(ow, oh) != true) continue
                val f = MediaFormat.createVideoFormat(mime, ow, oh).apply {
                    setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                    setInteger(MediaFormat.KEY_BIT_RATE, target.toInt())
                    setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                    // With surface input the default (VBR) overshot the target by
                    // ~25% on the S25; CBR lands on it, like the FFmpeg path.
                    if (caps.encoderCapabilities?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR) == true) {
                        setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                    }
                }
                val codec = runCatching { MediaCodec.createByCodecName(info.name) }.getOrNull() ?: continue
                if (runCatching { codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) }.isSuccess) {
                    return Encoder(codec, info.name, target.toInt())
                }
                codec.release()
            }
        }
        throw Unsupported("no hardware encoder for ${ow}x$oh")
    }

    /** The decoder's output texture, and a wait for each new frame in it. */
    private class Frames(thread: HandlerThread) {
        val textureId: Int
        val texture: SurfaceTexture
        private val lock = Object()
        private var ready = false

        init {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            textureId = ids[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            texture = SurfaceTexture(textureId)
            texture.setOnFrameAvailableListener({
                synchronized(lock) {
                    ready = true
                    lock.notifyAll()
                }
            }, Handler(thread.looper))
        }

        fun await() {
            synchronized(lock) {
                val until = System.currentTimeMillis() + 2_500
                while (!ready) {
                    val left = until - System.currentTimeMillis()
                    if (left <= 0) throw IllegalStateException("decoder frame timeout")
                    lock.wait(left)
                }
                ready = false
            }
        }
    }

    /** Draws the external texture into the encoder surface, trimmed to its shape. */
    private class Drawer(srcW: Int, srcH: Int, outW: Int, outH: Int) {
        val texMatrix = FloatArray(16)
        private val program: Int
        private val quad: FloatBuffer
        private val aPos: Int
        private val aTex: Int
        private val uTex: Int
        private val uCrop: Int
        private val uStep: Int
        private val crop = FloatArray(4) // x0, y0, sx, sy in texture space
        private val step = FloatArray(2)

        init {
            // Crop to fill: keep the output's shape, trim the longer side evenly.
            val src = srcW.toDouble() / srcH
            val dst = outW.toDouble() / outH
            if (src > dst) {
                val keep = (dst / src).toFloat()
                crop[0] = (1 - keep) / 2; crop[1] = 0f; crop[2] = keep; crop[3] = 1f
            } else {
                val keep = (src / dst).toFloat()
                crop[0] = 0f; crop[1] = (1 - keep) / 2; crop[2] = 1f; crop[3] = keep
            }
            // Shrinking by 2-3x: one bilinear sample per pixel would skip
            // source pixels (shimmer, and more bits for the encoder). Four
            // taps, one in each quarter of the pixel's footprint, average it
            // like a proper area filter. 1:1 keeps a single sharp sample.
            if (srcW.toDouble() * crop[2] / outW > 1.2) {
                step[0] = crop[2] / outW / 4
                step[1] = crop[3] / outH / 4
            }
            program = link(VERTEX, FRAGMENT)
            aPos = GLES20.glGetAttribLocation(program, "aPos")
            aTex = GLES20.glGetAttribLocation(program, "aTex")
            uTex = GLES20.glGetUniformLocation(program, "uTexMatrix")
            uCrop = GLES20.glGetUniformLocation(program, "uCrop")
            uStep = GLES20.glGetUniformLocation(program, "uStep")
            val v = floatArrayOf(
                -1f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                -1f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            )
            quad = ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().put(v)
            GLES20.glViewport(0, 0, outW, outH)
        }

        fun draw(textureId: Int) {
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glUniformMatrix4fv(uTex, 1, false, texMatrix, 0)
            GLES20.glUniform4fv(uCrop, 1, crop, 0)
            GLES20.glUniform2fv(uStep, 1, step, 0)
            quad.position(0)
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(aPos)
            quad.position(2)
            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(aTex)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        }

        private fun link(vs: String, fs: String): Int {
            fun shader(type: Int, src: String) = GLES20.glCreateShader(type).also {
                GLES20.glShaderSource(it, src)
                GLES20.glCompileShader(it)
                val ok = IntArray(1)
                GLES20.glGetShaderiv(it, GLES20.GL_COMPILE_STATUS, ok, 0)
                if (ok[0] == 0) throw IllegalStateException("shader: ${GLES20.glGetShaderInfoLog(it)}")
            }
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(p)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            if (ok[0] == 0) throw IllegalStateException("link: ${GLES20.glGetProgramInfoLog(p)}")
            return p
        }

        companion object {
            // highp throughout: mediump (fp16 on many GPUs) can't address
            // single texels of a 4K frame.
            const val VERTEX = """
                precision highp float;
                attribute vec4 aPos;
                attribute vec2 aTex;
                uniform mat4 uTexMatrix;
                uniform vec4 uCrop;
                uniform vec2 uStep;
                varying vec2 vTex;
                varying vec2 vDx;
                varying vec2 vDy;
                void main() {
                    gl_Position = aPos;
                    vTex = (uTexMatrix * vec4(uCrop.xy + aTex * uCrop.zw, 0.0, 1.0)).xy;
                    vDx = (uTexMatrix * vec4(uStep.x, 0.0, 0.0, 0.0)).xy;
                    vDy = (uTexMatrix * vec4(0.0, uStep.y, 0.0, 0.0)).xy;
                }
            """
            const val FRAGMENT = """
                #extension GL_OES_EGL_image_external : require
                precision highp float;
                uniform samplerExternalOES sTex;
                varying vec2 vTex;
                varying vec2 vDx;
                varying vec2 vDy;
                void main() {
                    gl_FragColor = 0.25 * (texture2D(sTex, vTex + vDx + vDy) + texture2D(sTex, vTex + vDx - vDy) +
                                           texture2D(sTex, vTex - vDx + vDy) + texture2D(sTex, vTex - vDx - vDy));
                }
            """
        }
    }

    /** An EGL context whose window is the encoder's input surface. */
    private class Egl(private val surface: Surface) {
        private val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        private val context: EGLContext
        private val window: EGLSurface

        init {
            val v = IntArray(2)
            check(EGL14.eglInitialize(display, v, 0, v, 1)) { "eglInitialize" }
            val attrs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            check(EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, n, 0) && n[0] > 0) { "eglChooseConfig" }
            context = EGL14.eglCreateContext(
                display, configs[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
            )
            check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext" }
            window = EGL14.eglCreateWindowSurface(display, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
            check(EGL14.eglMakeCurrent(display, window, window, context)) { "eglMakeCurrent" }
        }

        fun present(ptsNs: Long) {
            EGLExt.eglPresentationTimeANDROID(display, window, ptsNs)
            EGL14.eglSwapBuffers(display, window)
        }

        fun release() {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, window)
            EGL14.eglDestroyContext(display, context)
            // No eglTerminate: the display is shared with the other video job.
            EGL14.eglReleaseThread()
            surface.release()
        }

        companion object {
            const val EGL_RECORDABLE_ANDROID = 0x3142
        }
    }

    companion object {
        private const val TAG = "GpuShrinker"

        private fun MediaFormat.int(key: String, def: Int) = if (containsKey(key)) runCatching { getInteger(key) }.getOrDefault(def) else def
        private fun MediaFormat.long(key: String, def: Long) = if (containsKey(key)) runCatching { getLong(key) }.getOrDefault(def) else def
    }
}
