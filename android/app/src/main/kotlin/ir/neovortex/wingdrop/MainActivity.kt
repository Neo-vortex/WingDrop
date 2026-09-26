package ir.neovortex.wingdrop

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val bg = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private var discoverUsers = 0
    private lateinit var wifi: WifiLink
    private lateinit var media: MediaRepo
    private lateinit var store: ReceiveStore
    private lateinit var heic: HeicConverter
    private lateinit var shrinker: MediaShrinker
    private lateinit var trust: Trust
    private lateinit var thumbnailer: Thumbnailer
    private var channel: MethodChannel? = null
    private val shared = mutableListOf<Map<String, Any>>()
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingPick: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Ask for the panel's highest refresh rate (90/120/144 Hz) for fluid animation.
        @Suppress("DEPRECATION")
        val display = if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay
        display?.supportedModes
            ?.filter { it.physicalWidth == display.mode.physicalWidth && it.physicalHeight == display.mode.physicalHeight }
            ?.maxByOrNull { it.refreshRate }
            ?.let { best -> window.attributes = window.attributes.also { it.preferredDisplayModeId = best.modeId } }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wifi = WifiLink(this)
        media = MediaRepo(this)
        heic = HeicConverter(this)
        shrinker = MediaShrinker(this)
        trust = Trust(applicationContext)
        thumbnailer = Thumbnailer(applicationContext)
        NativeEngine.nativeSetIdentity(trust.deviceId)
        trust.push()
        store = ReceiveStore(applicationContext, trust).also { NativeEngine.store = it }
        prefs().getString("tree", null)?.let { store.treeUri = Uri.parse(it) }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wingdrop/core")
        this.channel = channel
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        // A sender found us over the air: ask the person in the Flutter UI, wait for the answer.
        NativeEngine.approver = { buddy, nick, peerId, files, bytes ->
            val latch = java.util.concurrent.CountDownLatch(1)
            var answer = 0
            main.post {
                channel.invokeMethod(
                    "approve",
                    mapOf("buddy" to buddy, "nick" to nick, "peer" to peerId, "files" to files, "bytes" to bytes),
                    object : MethodChannel.Result {
                        override fun success(r: Any?) { answer = (r as? Int) ?: 0; latch.countDown() }
                        override fun error(c: String, m: String?, d: Any?) = latch.countDown()
                        override fun notImplemented() = latch.countDown()
                    },
                )
            }
            latch.await(90, java.util.concurrent.TimeUnit.SECONDS)
            answer
        }
        intake(intent)
    }

    private fun prefs() = getSharedPreferences("wingdrop", MODE_PRIVATE)

    /** Runs [work] off the main thread and replies on it. */
    private fun async(result: MethodChannel.Result, work: () -> Any?) {
        bg.execute {
            val r = runCatching(work)
            main.post {
                r.fold({ result.success(it) }, { result.error("error", it.message ?: it.toString(), null) })
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "caps" -> result.success(wifi.capabilities() + mapOf("cores" to Runtime.getRuntime().availableProcessors()))
            "permissions" -> requestPerms(call.argument<List<String>>("kinds")!!, result)
            "hasPermissions" -> result.success(call.argument<List<String>>("kinds")!!.all(::kindGranted))
            "openSettings" -> {
                startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                result.success(null)
            }
            "wifiSettings" -> {
                startActivity(Intent(android.provider.Settings.Panel.ACTION_WIFI))
                result.success(null)
            }
            "brightness" -> {
                // Full-screen QR: max brightness makes it easy to scan; -1 restores the user's setting.
                val v = (call.argument<Number>("value") ?: -1).toFloat()
                window.attributes = window.attributes.also { it.screenBrightness = v }
                result.success(null)
            }
            "vpn" -> result.success(wifi.vpnActive())
            "btOn" -> result.success(
                getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter?.isEnabled == true,
            )
            "btSettings" -> {
                // Android's own "WingDrop wants to turn on Bluetooth" popup: one tap and it's on.
                val canAsk = Build.VERSION.SDK_INT < 31 ||
                    checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                val ok = canAsk && runCatching {
                    @Suppress("DEPRECATION")
                    startActivityForResult(Intent(android.bluetooth.BluetoothAdapter.ACTION_REQUEST_ENABLE), REQ_BT)
                }.isSuccess
                if (!ok) runCatching { startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)) }
                result.success(ok)
            }
            "wifiOn" -> result.success(
                applicationContext.getSystemService(android.net.wifi.WifiManager::class.java).isWifiEnabled,
            )
            "prefsGet" -> result.success(prefs().getString(call.argument<String>("key")!!, null))
            "prefsSet" -> {
                prefs().edit().putString(call.argument<String>("key")!!, call.argument<String>("value")).apply()
                result.success(null)
            }

            "apps" -> async(result) { media.apps() }
            "media" -> async(result) { media.media(call.argument<String>("kind")!!) }
            "thumb" -> async(result) { media.thumbnail(call.argument<String>("uri")!!, call.argument<Int>("px") ?: 192) }
            "appIcon" -> async(result) { media.appIcon(call.argument<String>("pkg")!!, call.argument<Int>("px") ?: 128) }
            "pickFiles" -> pick(result, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }, REQ_FILES)
            "pickTree" -> pick(result, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_TREE)
            "clearTree" -> {
                store.treeUri = null
                prefs().edit().remove("tree").apply()
                result.success(null)
            }
            "tree" -> result.success(store.treeUri?.toString())

            "heicConvert" -> async(result) {
                heic.convert(call.argument<List<String>>("uris")!!, call.argument<Int>("quality") ?: 92)
                    .map { p -> p?.let { mapOf("path" to it, "size" to File(it).length()) } }
            }
            "heicProgress" -> result.success(listOf(heic.progress.get(), heic.total.get()))
            "shrink" -> async(result) {
                shrinker.shrink(call.argument<List<Map<String, Any?>>>("items")!!, call.argument<Int>("preset") ?: 0)
            }
            "shrinkProgress" -> result.success(shrinker.progress())
            "shrinkCancel" -> {
                shrinker.cancel()
                result.success(null)
            }
            "scanQr" -> {
                pendingPick?.success(null)
                pendingPick = result
                @Suppress("DEPRECATION")
                startActivityForResult(
                    Intent(this, ScanActivity::class.java)
                        .putExtra("hint", call.argument<String>("hint"))
                        .putExtra("fa", call.argument<Boolean>("fa") == true)
                        .putExtra("dark", call.argument<Boolean>("dark") == true),
                    REQ_SCAN,
                )
            }
            "pickFolder" -> pick(result, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_FOLDER)

            "host" -> host(call, result)
            "stopHost" -> {
                NativeEngine.nativeStopListening()
                wifi.stop()
                TransferService.stop(this)
                result.success(null)
            }
            "join" -> {
                TransferService.start(this, "Connecting…")
                try {
                    wifi.join(call.argument<Map<String, Any?>>("qr")!!) { r ->
                        r.fold({ result.success(it) }, { result.error("join", it.message, null) })
                    }
                } catch (e: Exception) {
                    // Never leave the UI waiting: every failure becomes an answer.
                    Diag.w("WingDropWifi", "join crashed: $e")
                    result.error("join", "join_error: ${e.message}", null)
                }
            }
            "leave" -> {
                wifi.leave()
                TransferService.stop(this)
                result.success(null)
            }
            "send" -> send(call, result)
            "nearby" -> async(result) { wifi.nearby() }
            "discoverStart" -> {
                // The picker warms the search up and the radar joins it; the
                // search stops when the last of them lets go.
                discoverUsers++
                wifi.startDiscovery()
                result.success(null)
            }
            "discovered" -> async(result) { wifi.discovered() }
            "discoverStop" -> {
                discoverUsers = (discoverUsers - 1).coerceAtLeast(0)
                if (discoverUsers == 0) wifi.stopDiscovery()
                result.success(null)
            }
            "signal" -> result.success(wifi.signal())
            "cancel" -> {
                NativeEngine.nativeCancel((call.argument<Number>("id") ?: 0).toLong())
                result.success(null)
            }
            "status" -> result.success(NativeEngine.nativeStatus())
            "stage" -> result.success(Diag.stage)
            "chat" -> result.success(NativeEngine.nativeChat((call.argument<Number>("session") ?: 0).toLong(), call.argument<String>("text") ?: ""))
            "chatLog" -> result.success(NativeEngine.nativeChatLog((call.argument<Number>("since") ?: 0).toLong()))
            "diag" -> {
                // One timeline: app-side events and the native engine's log, merged by time.
                val lines = (Diag.dump().lines() + NativeEngine.nativeLog().lines()).filter { it.isNotBlank() }
                result.success(lines.sortedBy { it.take(12) }.joinToString("\n"))
            }
            "diagClear" -> {
                Diag.clear()
                NativeEngine.nativeLogClear()
                result.success(null)
            }
            "diagNote" -> {
                Diag.i("WingDropUi", call.argument<String>("text") ?: "")
                result.success(null)
            }
            "files" -> result.success(NativeEngine.nativeFiles(call.argument<Int>("limit") ?: 120))
            "preview" -> result.success(
                NativeEngine.nativePreview((call.argument<Number>("id") ?: 0).toLong(), call.argument<Int>("index") ?: 0),
            )
            "deleteReceived" -> async(result) { store.delete(call.argument<String>("uri")!!) }
            "deviceId" -> result.success(trust.deviceId)
            "bonds" -> result.success(trust.list())
            "saveBond" -> {
                val hex = call.argument<String>("key")!!
                val key = ByteArray(hex.length / 2) { hex.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
                trust.save(call.argument<String>("id")!!, key, call.argument<Int>("buddy") ?: 0, call.argument<String>("nick") ?: "")
                result.success(null)
            }
            "removeBond" -> {
                trust.remove(call.argument<String>("id")!!)
                result.success(null)
            }
            "takeShared" -> {
                result.success(synchronized(shared) { shared.toList().also { shared.clear() } })
            }
            "received" -> result.success(store.snapshot())
            "clearReceived" -> {
                store.clear()
                result.success(null)
            }
            "open" -> {
                runCatching {
                    startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(Uri.parse(call.argument<String>("uri")), call.argument<String>("mime"))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                }.fold({ result.success(null) }, { result.error("open", "No app can open this file", null) })
            }
            "benchmark" -> async(result) { NativeEngine.nativeBenchmark() }
            "install" -> async(result) { Installer.install(this, call.argument<List<String>>("uris")!!) }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ transfer

    private fun host(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "p2p"
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        // Wi-Fi Direct: the group name is chosen here so the radar key can be
        // derived from it (senders compute the same key from a Wi-Fi scan).
        val ssid = WifiLink.newGroupName(call.argument<String>("tag") ?: "WingDrop")
        val radarKey = if (mode == "p2p") WifiLink.radarKey(ssid) else ByteArray(32).also { SecureRandom().nextBytes(it) }
        trust.push()
        val port = NativeEngine.nativeListen(call.argument<Int>("port") ?: WifiLink.DEFAULT_PORT, key, radarKey)
        if (port < 0) return result.error("host", NativeEngine.nativeLastError(), null)
        Diag.i("WingDropHost", "listening on $port as $ssid (mode=$mode)")
        TransferService.start(this, "Waiting for sender…")
        wifi.host(
            mode,
            call.argument<String>("band") ?: "auto",
            call.argument<String>("security") ?: "wpa2",
            ssid,
            (call.argument<Map<String, String>>("txt") ?: emptyMap()) + mapOf(
                "v" to "1", "o" to port.toString(),
                "k" to android.util.Base64.encodeToString(radarKey, android.util.Base64.NO_WRAP),
            ),
        ) { r ->
            r.fold(
                { result.success(it + mapOf("port" to port, "key" to key)) },
                {
                    NativeEngine.nativeStopListening()
                    result.error("host", it.message, null)
                },
            )
        }
    }

    private fun send(call: MethodCall, result: MethodChannel.Result) {
        val items = call.argument<List<Map<String, Any?>>>("items")!!
        val hosts = call.argument<List<String>>("hosts")!!.toTypedArray()
        val port = call.argument<Int>("port")!!
        val peerId = call.argument<String>("peerId") ?: ""
        // A remembered buddy: use our shared bond key instead of the advertised one.
        val key = (if (call.argument<Boolean>("useBond") == true) trust.keyFor(peerId) else null)
            ?: call.argument<ByteArray>("key")!!
        val net = (call.argument<Number>("netHandle") ?: 0).toLong()
        val opts = call.argument<List<Int>>("opts")!!.toIntArray()
        TransferService.start(this, "Sending ${items.size} files…")
        async(result) {
            val fds = IntArray(items.size)
            items.forEachIndexed { i, it ->
                val path = it["path"] as String?
                fds[i] = if (path != null) {
                    ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).detachFd()
                } else {
                    contentResolver.openFileDescriptor(Uri.parse(it["uri"] as String), "r")?.detachFd() ?: -1
                }
            }
            // Previews first: the receiver shows them before the first byte arrives.
            val thumbs = thumbnailer.make(items)
            val id = NativeEngine.nativeSend(
                hosts, port, net, key,
                items.map { it["name"] as String }.toTypedArray(),
                items.map { (it["rel"] as String?) ?: "" }.toTypedArray(),
                items.map { (it["cat"] as Int?) ?: 0 }.toIntArray(),
                fds, opts, call.argument<String>("nick") ?: "", peerId, thumbs,
            )
            if (id == 0L) throw IllegalStateException(NativeEngine.nativeLastError())
            id
        }
    }

    // ------------------------------------------------------------------ permissions

    private fun permsFor(kind: String): List<String> {
        val sdk = Build.VERSION.SDK_INT
        return when (kind) {
            // One "Nearby devices" prompt on Android 12+: Wi-Fi Direct plus the BLE beacon radar.
            "nearby" -> when {
                sdk >= 33 -> listOf(Manifest.permission.NEARBY_WIFI_DEVICES, Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
                sdk >= 31 -> listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
                else -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            "media" -> when {
                sdk >= 34 -> listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                sdk >= 33 -> listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_AUDIO)
                else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            "notif" -> if (sdk >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()
            "camera" -> listOf(Manifest.permission.CAMERA)
            else -> emptyList()
        }
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** A kind is usable when its key permission is granted (partial photo access counts). */
    private fun kindGranted(kind: String): Boolean {
        val perms = permsFor(kind)
        if (perms.isEmpty()) return true
        return if (kind == "media") perms.any(::granted) else perms.all(::granted)
    }

    private var pendingKinds: List<String> = emptyList()

    /** Replies "granted" | "denied" | "blocked" (denied with "don't ask again"). */
    private fun requestPerms(kinds: List<String>, result: MethodChannel.Result) {
        if (kinds.all(::kindGranted)) return result.success("granted")
        val missing = kinds.flatMap(::permsFor).filterNot(::granted)
        pendingPermission?.success("denied")
        pendingPermission = result
        pendingKinds = kinds
        requestPermissions(missing.toTypedArray(), REQ_PERMS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMS) return
        val result = pendingPermission ?: return
        pendingPermission = null
        val failing = pendingKinds.filterNot(::kindGranted)
        val status = when {
            failing.isEmpty() -> "granted"
            // Denied and the system will no longer show a dialog: only Settings can fix it.
            failing.flatMap(::permsFor).filterNot(::granted).none { shouldShowRequestPermissionRationale(it) } -> "blocked"
            else -> "denied"
        }
        result.success(status)
    }

    // ------------------------------------------------------------------ pickers

    private fun pick(result: MethodChannel.Result, intent: Intent, code: Int) {
        pendingPick?.success(null)
        pendingPick = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, code)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val result = pendingPick ?: return
        pendingPick = null
        if (requestCode == REQ_SCAN && resultCode == RESULT_FIRST_USER) {
            return result.error("scan", data?.getStringExtra("error") ?: "camera", null)
        }
        if (resultCode != RESULT_OK || data == null) return result.success(null)
        when (requestCode) {
            REQ_FILES -> {
                val uris = data.clipData?.let { c -> (0 until c.itemCount).map { c.getItemAt(it).uri } }
                    ?: listOfNotNull(data.data)
                async(result) { uris.map(::describe) }
            }
            REQ_SCAN -> result.success(data.getStringExtra("value"))
            REQ_FOLDER -> {
                val tree = data.data!!
                async(result) { walkTree(tree) }
            }
            REQ_TREE -> {
                val tree = data.data!!
                contentResolver.takePersistableUriPermission(
                    tree, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                store.treeUri = tree
                prefs().edit().putString("tree", tree.toString()).apply()
                result.success(tree.toString())
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intake(intent)
        if (synchronized(shared) { shared.isNotEmpty() }) channel?.invokeMethod("shared", null)
    }

    /** "Share to WingDrop" from any app: remember what came in for the Flutter side. */
    private fun intake(intent: Intent?) {
        if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE)) return
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris += it }
        } else {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris += it }
        }
        intent.clipData?.let { c -> for (i in 0 until c.itemCount) c.getItemAt(i).uri?.let { if (it !in uris) uris += it } }
        val found = uris.mapNotNull { runCatching { describe(it) }.getOrNull() }.toMutableList()
        // Plain text (a link, a note) becomes a small .txt file.
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (found.isEmpty() && !text.isNullOrEmpty()) {
            val f = File(cacheDir, "shared-${System.currentTimeMillis()}.txt").apply { writeText(text) }
            found += mapOf("path" to f.absolutePath, "name" to "Shared text.txt", "size" to f.length(),
                "mime" to "text/plain", "heic" to false, "cat" to 0)
        }
        synchronized(shared) { shared += found }
        intent.action = null  // handled; don't re-import on rotation
    }

    /** Every file under a picked folder, keeping the folder structure in "rel". */
    private fun walkTree(tree: Uri): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val rootId = android.provider.DocumentsContract.getTreeDocumentId(tree)
        val rootName = rootId.substringAfterLast(':').substringAfterLast('/').ifEmpty { "Folder" }
        fun walk(docId: String, rel: String) {
            val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val cols = arrayOf(
                android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                android.provider.DocumentsContract.Document.COLUMN_SIZE,
            )
            contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                        walk(id, "$rel/$name")
                    } else {
                        out += mapOf(
                            "uri" to android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "name" to name, "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                            "mime" to mime, "rel" to rel, "heic" to HeicConverter.isHeic(name, mime),
                        )
                    }
                }
            }
        }
        walk(rootId, rootName)
        return out
    }

    private fun describe(uri: Uri): Map<String, Any> {
        var name = uri.lastPathSegment ?: "file"
        var size = 0L
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) {
                name = it.getString(0) ?: name
                size = if (it.isNull(1)) 0 else it.getLong(1)
            }
        }
        val mime = contentResolver.getType(uri) ?: ReceiveStore.mimeOf(name)
        if (size <= 0) size = runCatching { contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L }.getOrDefault(0L)
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size, "mime" to mime,
            "heic" to HeicConverter.isHeic(name, mime), "cat" to ReceiveStore.categoryOf(mime, name))
    }

    override fun onDestroy() {
        if (isFinishing) {
            NativeEngine.nativeCancel(0)
            NativeEngine.nativeStopListening()
            wifi.stop()
            TransferService.stop(this)
        }
        super.onDestroy()
    }

    companion object {
        private const val REQ_PERMS = 7001
        private const val REQ_FILES = 7002
        private const val REQ_TREE = 7003
        private const val REQ_FOLDER = 7004
        private const val REQ_SCAN = 7005
        private const val REQ_BT = 7006
    }
}
