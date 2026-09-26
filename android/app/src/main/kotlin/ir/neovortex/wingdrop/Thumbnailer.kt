package ir.neovortex.wingdrop

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Small JPEG previews for the transfer overview (and for the receiver, which
 * gets them before the files). Gallery items use Android's cached thumbnails;
 * anything else (shrunk files, odd containers, videos the platform can't
 * preview) goes through the bundled FFmpeg; apps show their icon.
 */
class Thumbnailer(private val context: Context) {

    /** items: {uri|path, name, mime, cat}. Index-aligned result, null = no preview. */
    fun make(items: List<Map<String, Any?>>, max: Int = 60): Array<ByteArray?> {
        val out = arrayOfNulls<ByteArray>(items.size)
        val wanted = items.withIndex().filter { (_, it) -> previewable(it) }.take(max)
        if (wanted.isEmpty()) return out
        val pool = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors().coerceIn(2, 6))
        try {
            val jobs = wanted.map { (i, it) -> i to pool.submit(Callable { runCatching { one(it) }.getOrNull() }) }
            for ((i, f) in jobs) out[i] = runCatching { f.get(4, TimeUnit.SECONDS) }.getOrNull()
        } finally {
            pool.shutdownNow()
        }
        return out
    }

    private fun previewable(it: Map<String, Any?>): Boolean {
        val mime = (it["mime"] as String?) ?: ""
        val cat = (it["cat"] as Int?) ?: 0
        val name = ((it["name"] as String?) ?: "").lowercase()
        return mime.startsWith("image/") || mime.startsWith("video/") || cat == 1 || cat == 2 || cat == 4 ||
            name.endsWith(".apk") || mime.startsWith("audio/") || cat == 3
    }

    private fun one(it: Map<String, Any?>): ByteArray? {
        val uri = (it["uri"] as String?)?.let(Uri::parse)
        val path = it["path"] as String?
        val name = ((it["name"] as String?) ?: "").lowercase()
        val mime = (it["mime"] as String?) ?: ""
        if (name.endsWith(".apk") && path != null) return apkIcon(path)
        // 1) Android's cached thumbnail (gallery items, most documents).
        if (uri != null) runCatching { return jpeg(context.contentResolver.loadThumbnail(uri, Size(PX, PX), null)) }
        // 2) Still images on disk.
        if (mime.startsWith("image/") || it["cat"] == 1) {
            runCatching {
                val src = if (path != null) ImageDecoder.createSource(File(path)) else ImageDecoder.createSource(context.contentResolver, uri!!)
                return jpeg(ImageDecoder.decodeBitmap(src) { d, info, _ ->
                    val s = PX.toFloat() / maxOf(info.size.width, info.size.height)
                    if (s < 1) d.setTargetSize((info.size.width * s).toInt().coerceAtLeast(1), (info.size.height * s).toInt().coerceAtLeast(1))
                    d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                })
            }
        }
        // 3) FFmpeg: a frame ~10% into a video, or embedded album art.
        val pfd = if (path != null) ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        else context.contentResolver.openFileDescriptor(uri!!, "r") ?: return null
        pfd.use { f ->
            val raw = NativeEngine.nativeFrame(f.fd, PX) ?: return null
            val hdr = ByteBuffer.wrap(raw, 0, 8).order(ByteOrder.LITTLE_ENDIAN)
            val w = hdr.int
            val h = hdr.int
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.copyPixelsFromBuffer(ByteBuffer.wrap(raw, 8, w * h * 4))
            return jpeg(bmp)
        }
    }

    private fun apkIcon(path: String): ByteArray? {
        val pm = context.packageManager
        val info = pm.getPackageArchiveInfo(path, 0)?.applicationInfo ?: return null
        info.sourceDir = path
        info.publicSourceDir = path
        val d = info.loadIcon(pm)
        val bmp = if (d is BitmapDrawable && d.bitmap != null) d.bitmap else
            Bitmap.createBitmap(PX, PX, Bitmap.Config.ARGB_8888).also { b -> d.setBounds(0, 0, PX, PX); d.draw(Canvas(b)) }
        val out = ByteArrayOutputStream()
        Bitmap.createScaledBitmap(bmp, PX, PX, true).compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun jpeg(bmp: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 72, out)
        return out.toByteArray()
    }

    companion object {
        private const val PX = 192
    }
}
