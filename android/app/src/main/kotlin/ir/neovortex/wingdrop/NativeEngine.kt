package ir.neovortex.wingdrop

/** JNI surface of the C++ Vortex transfer engine (src/main/cpp). */
object NativeEngine {
    init {
        System.loadLibrary("vortexengine")
    }

    @JvmStatic external fun nativeSetIdentity(deviceId: String)
    @JvmStatic external fun nativeSetBonds(keys: Array<ByteArray>)

    /** key comes from the QR code; radarKey is advertised nearby and needs approval per sender. */
    @JvmStatic external fun nativeListen(port: Int, key: ByteArray, radarKey: ByteArray?): Int
    @JvmStatic external fun nativeStopListening()

    /**
     * opts = [flags, streams, chunkSize, sockBuf, tos, depth, buddy]. Takes ownership of [fds].
     * Returns the session id (0 on failure). [peerId] makes retries resumable.
     */
    @JvmStatic external fun nativeSend(
        hosts: Array<String>, port: Int, netHandle: Long, key: ByteArray,
        names: Array<String>, rels: Array<String>, cats: IntArray, fds: IntArray, opts: IntArray,
        nick: String, peerId: String, thumbs: Array<ByteArray?>?,
    ): Long

    /** The engine's own log lines ("HH:MM:SS.mmm L tag: msg"). */
    @JvmStatic external fun nativeLog(): String
    @JvmStatic external fun nativeLogClear()

    /** Chat during a transfer. session 0 = every active one; returns how many got it. */
    @JvmStatic external fun nativeChat(session: Long, text: String): Int
    @JvmStatic external fun nativeChatLog(since: Long): String

    /** Per-file overview of the current sessions (JSON, see Engine::files). */
    @JvmStatic external fun nativeFiles(limit: Int): String
    @JvmStatic external fun nativePreview(session: Long, file: Int): ByteArray?

    /** RGBA video/cover frame with an 8-byte (w, h) header, via FFmpeg; null on failure. */
    @JvmStatic external fun nativeFrame(fd: Int, maxSide: Int): ByteArray?

    /** 0 cancels everything. */
    @JvmStatic external fun nativeCancel(id: Long)
    @JvmStatic external fun nativeHoldGroup(on: Boolean)

    /** Aggregate + per-session progress as JSON (see Engine::status). */
    @JvmStatic external fun nativeStatus(): String
    @JvmStatic external fun nativeLastError(): String

    /** kind 0 video / 1 audio, preset 0 light / 1 small. 0 ok, 1 keep original, <0 error. */
    @JvmStatic external fun nativeTranscode(job: Int, inFd: Int, outFd: Int, kind: Int, preset: Int): Int
    @JvmStatic external fun nativeTranscodeProgress(job: Int): Double
    @JvmStatic external fun nativeTranscodeCancel(job: Int)

    /** See bench.h for the layout. Blocks for ~5 s. */
    @JvmStatic external fun nativeBenchmark(): DoubleArray

    // ---- callbacks from native receiver threads

    @Volatile var store: ReceiveStore? = null

    /**
     * Asks the user whether a sender found over the air may send.
     * 0 = no, 1 = yes, 2 = yes and remember them. Blocks the calling native thread.
     */
    @Volatile var approver: ((buddy: Int, nick: String, peerId: String, files: Int, bytes: Long) -> Int)? = null

    @JvmStatic
    fun openOutputs(
        batch: Long, transferId: String, chunk: Int,
        names: Array<String>, rels: Array<String>, sizes: LongArray, cats: IntArray,
    ): IntArray = store?.openOutputs(batch, transferId, chunk, names, rels, sizes, cats) ?: IntArray(names.size) { -1 }

    @JvmStatic
    fun resumeBitmap(batch: Long): ByteArray? = store?.resumeBitmap(batch)

    @JvmStatic
    fun onFileDone(batch: Long, index: Int) {
        store?.fileDone(batch, index)
    }

    @JvmStatic
    fun onSessionDone(batch: Long, ok: Boolean, bitmap: ByteArray, peerId: String, buddy: Int, nick: String, bond: ByteArray?) {
        store?.sessionDone(batch, ok, bitmap)
        if (bond != null && peerId.isNotEmpty()) store?.trust?.save(peerId, bond, buddy, nick)
    }

    @JvmStatic
    fun approve(buddy: Int, nick: String, peerId: String, files: Int, bytes: Long): Int =
        approver?.invoke(buddy, nick, peerId, files, bytes) ?: 0
}
