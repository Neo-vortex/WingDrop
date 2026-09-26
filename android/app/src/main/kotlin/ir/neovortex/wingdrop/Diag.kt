package ir.neovortex.wingdrop

import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A small in-app connection log. Every step of finding, joining and
 * connecting is recorded here (and in logcat) so an error screen can show
 * exactly what happened: no more "scanned the code and nothing happened".
 */
object Diag {
    private const val MAX = 400
    private val lines = ArrayDeque<String>()
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    /** What the connection is doing right now, polled by the UI. */
    @Volatile var stage: String = ""

    fun i(tag: String, msg: String) = add("I", tag, msg).also { Log.i(tag, msg) }
    fun w(tag: String, msg: String) = add("W", tag, msg).also { Log.w(tag, msg) }

    fun stage(tag: String, s: String, detail: String = "") {
        stage = s
        i(tag, "stage: $s${if (detail.isEmpty()) "" else " ($detail)"}")
    }

    @Synchronized
    private fun add(level: String, tag: String, msg: String) {
        lines.addLast("${fmt.format(Date())} $level $tag: $msg")
        while (lines.size > MAX) lines.removeFirst()
    }

    @Synchronized
    fun dump(): String = lines.joinToString("\n")

    @Synchronized
    fun clear() = lines.clear()
}
