package ir.neovortex.wingdrop

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom

/**
 * Trusted buddies: a shared 32-byte bond key per device, created after a QR
 * pairing (or an approval with "remember them"). Either side can then connect
 * with it: no QR, no approval.
 */
class Trust(context: Context) {
    private val prefs = context.getSharedPreferences("wingdrop-trust", Context.MODE_PRIVATE)

    /** This phone's stable, random id (not tied to any hardware identifier). */
    val deviceId: String = prefs.getString("deviceId", null) ?: ByteArray(8).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it) }.also { prefs.edit().putString("deviceId", it).apply() }

    private fun all(): JSONObject = JSONObject(prefs.getString("bonds", "{}")!!)

    @Synchronized
    fun save(peerId: String, key: ByteArray, buddy: Int, nick: String) {
        val j = all()
        j.put(peerId, JSONObject().apply {
            put("k", Base64.encodeToString(key, Base64.NO_WRAP))
            put("a", buddy)
            put("n", nick)
            put("t", System.currentTimeMillis())
        })
        prefs.edit().putString("bonds", j.toString()).apply()
        push()
    }

    @Synchronized
    fun remove(peerId: String) {
        val j = all()
        j.remove(peerId)
        prefs.edit().putString("bonds", j.toString()).apply()
        push()
    }

    fun keyFor(peerId: String): ByteArray? =
        all().optJSONObject(peerId)?.optString("k")?.takeIf { it.isNotEmpty() }?.let { Base64.decode(it, Base64.NO_WRAP) }

    fun list(): List<Map<String, Any>> {
        val j = all()
        return j.keys().asSequence().map { id ->
            val b = j.getJSONObject(id)
            mapOf("id" to id, "buddy" to b.optInt("a"), "nick" to b.optString("n"), "time" to b.optLong("t"))
        }.sortedByDescending { it["time"] as Long }.toList()
    }

    /** Hands every bond key to the engine so bonded senders are let straight in. */
    fun push() {
        val j = all()
        val keys = j.keys().asSequence().mapNotNull { keyFor(it) }.toList()
        NativeEngine.nativeSetBonds(keys.toTypedArray())
    }
}
