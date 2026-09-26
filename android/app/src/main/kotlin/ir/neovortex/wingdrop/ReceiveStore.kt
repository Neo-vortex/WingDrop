package ir.neovortex.wingdrop

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Creates destination files for incoming transfers and hands raw fds to the
 * native engine, which pwrite()s / splice()s straight into them. Targets either
 * MediaStore (Pictures, Movies, Music, Download under "WingDrop") or a folder
 * the user picked through SAF.
 *
 * Interrupted transfers keep their partial files plus a chunk bitmap (persisted
 * for 24 h), so the same sender picks up where it stopped.
 */
class ReceiveStore(private val context: Context, val trust: Trust) {
    data class Item(
        val name: String, val rel: String, val category: Int, val size: Long,
        val mime: String, val uri: Uri, var done: Boolean = false, val batch: Long, val index: Int = 0,
    )

    private class Batch(val transferId: String, val chunk: Int, val items: List<Item>, val bitmap: ByteArray?)

    @Volatile var treeUri: Uri? = null
    private val items = mutableListOf<Item>()
    private val batches = mutableMapOf<Long, Batch>()
    private val io = Executors.newSingleThreadExecutor()
    private val prefs = context.getSharedPreferences("wingdrop-resume", Context.MODE_PRIVATE)

    init {
        io.execute(::expireResumeRecords)
    }

    fun snapshot(): List<Map<String, Any>> = synchronized(items) {
        items.map {
            mapOf(
                "name" to it.name, "rel" to it.rel, "cat" to it.category, "size" to it.size,
                "mime" to it.mime, "uri" to it.uri.toString(), "done" to it.done, "batch" to it.batch, "index" to it.index,
            )
        }
    }

    fun clear() = synchronized(items) { items.removeAll { it.done } }

    /** Deletes a received file for good and drops it from the list. */
    fun delete(uri: String): Boolean {
        val u = Uri.parse(uri)
        val ok = runCatching {
            if (DocumentsContract.isDocumentUri(context, u)) DocumentsContract.deleteDocument(context.contentResolver, u)
            else context.contentResolver.delete(u, null, null) > 0
        }.getOrDefault(false)
        synchronized(items) { items.removeAll { it.uri == u } }
        return ok
    }

    @Synchronized
    fun openOutputs(
        batch: Long, transferId: String, chunk: Int,
        names: Array<String>, rels: Array<String>, sizes: LongArray, cats: IntArray,
    ): IntArray {
        resumeFrom(batch, transferId, chunk, names, sizes)?.let { return it }

        val created = ArrayList<Item>(names.size)
        val fds = IntArray(names.size) { -1 }
        val tree = treeUri
        for (i in names.indices) {
            val name = sanitize(names[i])
            // Empty parts first, then sanitize: sanitize("") would become "file".
            val rel = rels[i].split('/').filter { it.isNotBlank() }.map(::sanitize).joinToString("/")
            val mime = mimeOf(name)
            try {
                val uri = if (tree != null) createInTree(tree, rel, name, mime) else createInMediaStore(name, rel, cats[i], mime)
                val pfd = context.contentResolver.openFileDescriptor(uri!!, "rw")!!
                fds[i] = pfd.detachFd()
                created += Item(name, rel, cats[i], sizes[i], mime, uri, batch = batch, index = i)
            } catch (e: Exception) {
                Log.e(TAG, "cannot create $name", e)
                created.forEach { delete(it.uri) }
                fds.forEach { if (it >= 0) android.os.ParcelFileDescriptor.adoptFd(it).close() }
                return IntArray(names.size) { -1 }
            }
        }
        batches[batch] = Batch(transferId, chunk, created, null)
        synchronized(items) { items.addAll(0, created.reversed()) }
        return fds
    }

    /** Reopens the partial files of an interrupted transfer, if they are still around. */
    private fun resumeFrom(batch: Long, transferId: String, chunk: Int, names: Array<String>, sizes: LongArray): IntArray? {
        val rec = prefs.getString(transferId, null)?.let { JSONObject(it) } ?: return null
        val files = rec.getJSONArray("files")
        if (rec.getInt("chunk") != chunk || files.length() != names.size) return null
        val fds = IntArray(names.size) { -1 }
        val reopened = ArrayList<Item>(names.size)
        try {
            for (i in 0 until files.length()) {
                val f = files.getJSONObject(i)
                if (f.getLong("size") != sizes[i]) throw IllegalStateException("size changed")
                val uri = Uri.parse(f.getString("uri"))
                // "rw" keeps the existing bytes: only the missing chunks get written.
                fds[i] = context.contentResolver.openFileDescriptor(uri, "rw")!!.detachFd()
                reopened += Item(f.getString("name"), f.optString("rel"), f.getInt("cat"), sizes[i],
                    mimeOf(f.getString("name")), uri, batch = batch, index = i)
            }
        } catch (e: Exception) {
            Log.w(TAG, "cannot resume $transferId, starting over", e)
            fds.forEach { if (it >= 0) android.os.ParcelFileDescriptor.adoptFd(it).close() }
            prefs.edit().remove(transferId).apply()
            return null
        }
        val bitmap = Base64.decode(rec.getString("bitmap"), Base64.NO_WRAP)
        batches[batch] = Batch(transferId, chunk, reopened, bitmap)
        synchronized(items) { items.addAll(0, reopened.reversed()) }
        return fds
    }

    @Synchronized
    fun resumeBitmap(batch: Long): ByteArray? = batches[batch]?.bitmap

    fun fileDone(batch: Long, index: Int) {
        val item = synchronized(this) { batches[batch]?.items?.getOrNull(index) } ?: return
        item.done = true
        if (treeUri == null) io.execute {
            // Publish to the gallery / music apps.
            runCatching {
                context.contentResolver.update(item.uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
            }
        }
    }

    @Synchronized
    fun sessionDone(batch: Long, ok: Boolean, bitmap: ByteArray) {
        val b = batches.remove(batch) ?: return
        if (ok) {
            prefs.edit().remove(b.transferId).apply()
            return
        }
        // Keep the partial files and remember what we have, for a resume.
        val files = JSONArray()
        b.items.forEach {
            files.put(JSONObject().apply {
                put("uri", it.uri.toString()); put("name", it.name); put("rel", it.rel)
                put("cat", it.category); put("size", it.size)
            })
        }
        prefs.edit().putString(b.transferId, JSONObject().apply {
            put("chunk", b.chunk)
            put("created", System.currentTimeMillis())
            put("files", files)
            put("bitmap", Base64.encodeToString(bitmap, Base64.NO_WRAP))
        }.toString()).apply()
        val unfinished = b.items.filter { !it.done }.toSet()
        synchronized(items) { items.removeAll(unfinished) }
    }

    /** Partial files nobody came back for within a day are cleaned up. */
    private fun expireResumeRecords() {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        val edit = prefs.edit()
        for ((tid, v) in prefs.all) {
            val rec = runCatching { JSONObject(v as String) }.getOrNull() ?: continue
            if (rec.optLong("created") > cutoff) continue
            val files = rec.optJSONArray("files") ?: JSONArray()
            for (i in 0 until files.length()) delete(Uri.parse(files.getJSONObject(i).getString("uri")))
            edit.remove(tid)
        }
        edit.apply()
    }

    private fun delete(uri: Uri) {
        runCatching {
            if (DocumentsContract.isDocumentUri(context, uri)) DocumentsContract.deleteDocument(context.contentResolver, uri)
            else context.contentResolver.delete(uri, null, null)
        }
    }

    private fun createInMediaStore(name: String, rel: String, category: Int, mime: String): Uri? {
        val sub = if (rel.isEmpty()) "" else "/$rel"
        val (collection, base) = when {
            category == CAT_PHOTO && mime.startsWith("image/") ->
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_PICTURES
            category == CAT_VIDEO && mime.startsWith("video/") ->
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_MOVIES
            category == CAT_MUSIC && mime.startsWith("audio/") ->
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_MUSIC
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_DOWNLOADS
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$base/WingDrop$sub")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        return context.contentResolver.insert(collection, values)
    }

    private fun createInTree(tree: Uri, rel: String, name: String, mime: String): Uri? {
        val cr = context.contentResolver
        var parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        for (dir in listOf("WingDrop") + rel.split('/').filter { it.isNotEmpty() }) {
            parent = findChild(tree, parent, dir)
                ?: DocumentsContract.createDocument(cr, parent, DocumentsContract.Document.MIME_TYPE_DIR, dir)
                ?: return null
        }
        return DocumentsContract.createDocument(cr, parent, mime, name)
    }

    private fun findChild(tree: Uri, parent: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        context.contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
            }
        }
        return null
    }

    companion object {
        private const val TAG = "ReceiveStore"
        const val CAT_FILE = 0
        const val CAT_PHOTO = 1
        const val CAT_VIDEO = 2
        const val CAT_MUSIC = 3
        const val CAT_APP = 4

        fun mimeOf(name: String): String {
            val ext = name.substringAfterLast('.', "").lowercase()
            if (ext == "apk") return "application/vnd.android.package-archive"
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }

        fun categoryOf(mime: String, name: String): Int = when {
            mime.startsWith("image/") -> CAT_PHOTO
            mime.startsWith("video/") -> CAT_VIDEO
            mime.startsWith("audio/") -> CAT_MUSIC
            name.lowercase().endsWith(".apk") -> CAT_APP
            else -> CAT_FILE
        }

        /** Never let a peer escape the target folder or smuggle control chars. */
        fun sanitize(s: String): String =
            s.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").trim().trimStart('.').take(200).ifEmpty { "file" }
    }
}
