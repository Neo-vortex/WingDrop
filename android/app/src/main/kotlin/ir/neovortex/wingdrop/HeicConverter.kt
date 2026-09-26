package ir.neovortex.wingdrop

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * HEIC/HEIF -> JPEG, one decoder per core. The hardware HEVC decoder does most
 * of the work through ImageDecoder; EXIF (date, GPS, camera) is copied over and
 * orientation is baked into the pixels.
 */
class HeicConverter(private val context: Context) {
    val progress = AtomicInteger(0)
    val total = AtomicInteger(0)

    /** Returns the cache file path for each input, in order (null = failed, send original). */
    fun convert(uris: List<String>, quality: Int): List<String?> {
        val dir = File(context.cacheDir, "heic").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        progress.set(0)
        total.set(uris.size)
        val pool = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors().coerceIn(2, 8))
        try {
            val jobs = uris.mapIndexed { i, u ->
                pool.submit(Callable {
                    val out = File(dir, "$i.jpg")
                    val ok = runCatching { convertOne(Uri.parse(u), out, quality) }.isSuccess
                    progress.incrementAndGet()
                    if (ok) out.absolutePath else null
                })
            }
            return jobs.map { it.get() }
        } finally {
            pool.shutdown()
        }
    }

    private fun convertOne(uri: Uri, out: File, quality: Int) {
        val src = ImageDecoder.createSource(context.contentResolver, uri)
        val bmp = ImageDecoder.decodeBitmap(src) { d, _, _ ->
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            d.isMutableRequired = false
        }
        out.outputStream().buffered(1 shl 20).use { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        bmp.recycle()
        runCatching {
            val from = context.contentResolver.openInputStream(uri)!!.use { ExifInterface(it) }
            val to = ExifInterface(out.absolutePath)
            for (tag in EXIF_TAGS) from.getAttribute(tag)?.let { to.setAttribute(tag, it) }
            to.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
            to.saveAttributes()
        }
    }

    companion object {
        fun isHeic(name: String, mime: String?): Boolean {
            val m = mime?.lowercase() ?: ""
            val n = name.lowercase()
            return m == "image/heic" || m == "image/heif" || m == "image/heic-sequence" ||
                n.endsWith(".heic") || n.endsWith(".heif")
        }

        fun jpegName(name: String) = name.substringBeforeLast('.') + ".jpg"

        val EXIF_TAGS = listOf(
            ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
            ExifInterface.TAG_OFFSET_TIME, ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
            ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_F_NUMBER,
            ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, ExifInterface.TAG_FOCAL_LENGTH,
            ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, ExifInterface.TAG_FLASH, ExifInterface.TAG_WHITE_BALANCE,
            ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE,
            ExifInterface.TAG_GPS_LONGITUDE_REF, ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
            ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
        )
    }
}
