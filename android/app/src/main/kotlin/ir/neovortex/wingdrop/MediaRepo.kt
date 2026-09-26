package ir.neovortex.wingdrop

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File

/** Lists apps and media for the picker and renders small thumbnails. */
class MediaRepo(private val context: Context) {

    fun apps(): List<Map<String, Any>> {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launcher, 0)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .filter { it.packageName != context.packageName }
            .map { ai ->
                val apks = listOf(ai.sourceDir) + (ai.splitSourceDirs?.toList() ?: emptyList())
                val info = pm.getPackageInfo(ai.packageName, 0)
                mapOf(
                    "pkg" to ai.packageName,
                    "label" to ai.loadLabel(pm).toString(),
                    "version" to (info.versionName ?: ""),
                    "apks" to apks,
                    "apkSizes" to apks.map { File(it).length() },
                    "size" to apks.sumOf { File(it).length() },
                    "system" to ((ai.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    /** kind: image | video | audio */
    fun media(kind: String): List<Map<String, Any>> {
        val collection = when (kind) {
            "image" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        }
        val cols = mutableListOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
        )
        if (kind != "image") cols += MediaStore.MediaColumns.DURATION
        if (kind == "audio") cols += MediaStore.Audio.AudioColumns.ARTIST
        val out = ArrayList<Map<String, Any>>()
        context.contentResolver.query(
            collection, cols.toTypedArray(), "${MediaStore.MediaColumns.SIZE} > 0", null,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val name = c.getString(1) ?: "file"
                val mime = c.getString(3) ?: ReceiveStore.mimeOf(name)
                out += mapOf(
                    "uri" to ContentUris.withAppendedId(collection, id).toString(),
                    "name" to name,
                    "size" to c.getLong(2),
                    "mime" to mime,
                    "date" to c.getLong(4),
                    "album" to (c.getString(5) ?: ""),
                    "duration" to (if (kind != "image") c.getLong(6) else 0L),
                    "artist" to (if (kind == "audio") c.getString(7) ?: "" else ""),
                    "heic" to HeicConverter.isHeic(name, mime),
                )
            }
        }
        return out
    }

    fun thumbnail(uri: String, px: Int): ByteArray? = runCatching {
        val bmp = context.contentResolver.loadThumbnail(Uri.parse(uri), Size(px, px), null)
        encode(bmp)
    }.getOrNull()

    fun appIcon(pkg: String, px: Int): ByteArray? = runCatching {
        encode(toBitmap(context.packageManager.getApplicationIcon(pkg), px))
    }.getOrNull()

    private fun toBitmap(d: Drawable, px: Int): Bitmap {
        if (d is BitmapDrawable && d.bitmap != null) return Bitmap.createScaledBitmap(d.bitmap, px, px, true)
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, px, px)
        d.draw(Canvas(bmp))
        return bmp
    }

    private fun encode(bmp: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bmp.compress(if (bmp.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 80, out)
        return out.toByteArray()
    }
}
