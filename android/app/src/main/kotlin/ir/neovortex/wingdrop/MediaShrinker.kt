package ir.neovortex.wingdrop

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicInteger

/**
 * Makes photos, videos and music smaller before sending. Two presets only:
 *  - light: "a bit smaller" (barely visible difference)
 *  - small: "much smaller" (lowest quality that still looks/sounds fine)
 * Photos use ImageDecoder (JPEG/PNG/WebP/HEIC/AVIF/…); videos and music go
 * through the bundled FFmpeg with the phone's hardware encoders.
 */
class MediaShrinker(private val context: Context) {
    private val progress = mutableMapOf<Int, Double>()
    private val jobIds = AtomicInteger(1)
    @Volatile private var active = emptyList<Int>()
    @Volatile private var total = 0

    /** items: {uri|path, name, mime}. Returns per item {path, name} or null (send the original). */
    fun shrink(items: List<Map<String, Any?>>, preset: Int): List<Map<String, Any>?> {
        val dir = File(context.cacheDir, "shrink").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        synchronized(progress) { progress.clear() }
        total = items.size
        val ids = items.map { jobIds.getAndIncrement() }
        active = ids
        val cores = Runtime.getRuntime().availableProcessors().coerceIn(2, 8)
        val pool = Executors.newFixedThreadPool(cores)
        // Hardware video encoders have few sessions; two at once keeps them all busy.
        val videoSlots = Semaphore(2)
        try {
            val jobs = items.mapIndexed { i, item ->
                pool.submit(Callable {
                    val mime = (item["mime"] as String?)?.lowercase() ?: ""
                    val name = item["name"] as String
                    val result = runCatching {
                        when {
                            mime.startsWith("image/") -> photo(item, File(dir, "$i.img"), name, preset)
                            mime.startsWith("video/") -> {
                                videoSlots.acquire()
                                try { av(ids[i], item, File(dir, "$i.mp4"), name, 0, preset, ".mp4") } finally { videoSlots.release() }
                            }
                            mime.startsWith("audio/") -> av(ids[i], item, File(dir, "$i.m4a"), name, 1, preset, ".m4a")
                            else -> null
                        }
                    }.onFailure { Log.w(TAG, "shrink failed for $name", it) }.getOrNull()
                    synchronized(progress) { progress[ids[i]] = 1.0 }
                    result
                })
            }
            return jobs.map { it.get() }
        } finally {
            pool.shutdown()
            active = emptyList()
        }
    }

    fun progress(): Double {
        val ids = active
        if (ids.isEmpty() || total == 0) return 0.0
        var sum = 0.0
        for (id in ids) {
            val done = synchronized(progress) { progress[id] }
            sum += done ?: NativeEngine.nativeTranscodeProgress(id)
        }
        return sum / total
    }

    fun cancel() = active.forEach { NativeEngine.nativeTranscodeCancel(it) }


    private fun openIn(item: Map<String, Any?>): ParcelFileDescriptor {
        val path = item["path"] as String?
        return if (path != null) ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        else context.contentResolver.openFileDescriptor(Uri.parse(item["uri"] as String), "r")!!
    }

    private fun av(id: Int, item: Map<String, Any?>, out: File, name: String, kind: Int, preset: Int, ext: String): Map<String, Any>? {
        openIn(item).use { input ->
            ParcelFileDescriptor.open(
                out, ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE,
            ).use { output ->
                val r = NativeEngine.nativeTranscode(id, input.fd, output.fd, kind, preset)
                if (r != 0) {
                    out.delete()
                    return null
                }
            }
        }
        return mapOf("path" to out.absolutePath, "name" to name.substringBeforeLast('.') + ext, "size" to out.length())
    }

    private fun photo(item: Map<String, Any?>, out: File, name: String, preset: Int): Map<String, Any>? {
        val maxSide = if (preset == 0) 3072 else 1600
        val quality = if (preset == 0) 85 else 75
        val lower = name.lowercase()
        if (lower.endsWith(".gif")) return null // keep animations intact
        val inputSize = openIn(item).use { it.statSize }
        val path = item["path"] as String?
        val src = if (path != null) ImageDecoder.createSource(File(path))
        else ImageDecoder.createSource(context.contentResolver, Uri.parse(item["uri"] as String))
        var alpha = false
        val bmp = ImageDecoder.decodeBitmap(src) { d, info, _ ->
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width
            val h = info.size.height
            val scale = minOf(1.0, maxSide.toDouble() / maxOf(w, h))
            if (scale < 1.0) d.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
            alpha = info.mimeType == "image/png" || info.mimeType == "image/webp"
        }
        val keepAlpha = alpha && bmp.hasAlpha()
        val format = if (keepAlpha) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.JPEG
        out.outputStream().buffered(1 shl 20).use { bmp.compress(format, quality, it) }
        bmp.recycle()
        if (out.length() > inputSize * 9 / 10) {
            out.delete()
            return null
        }
        if (!keepAlpha) copyExif(item, out)
        return mapOf(
            "path" to out.absolutePath,
            "name" to name.substringBeforeLast('.') + if (keepAlpha) ".webp" else ".jpg",
            "size" to out.length(),
        )
    }

    private fun copyExif(item: Map<String, Any?>, out: File) = runCatching {
        val from = openIn(item).use { pfd -> ParcelFileDescriptor.AutoCloseInputStream(pfd).use { ExifInterface(it) } }
        val to = ExifInterface(out.absolutePath)
        for (tag in HeicConverter.EXIF_TAGS) from.getAttribute(tag)?.let { to.setAttribute(tag, it) }
        to.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
        to.saveAttributes()
    }

    companion object {
        private const val TAG = "MediaShrinker"
    }
}
