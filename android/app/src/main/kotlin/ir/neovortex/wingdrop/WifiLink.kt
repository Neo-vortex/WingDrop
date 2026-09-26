package ir.neovortex.wingdrop

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.ScanResult
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.SparseIntArray
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom

/**
 * Brings up the fastest link the hardware offers.
 *
 * Link modes:
 *  - "p2p":  Wi-Fi Direct group. Band can be forced (2.4 / 5 / 6 GHz on API 36),
 *            and WPA3 (Wi-Fi Direct R2) is used when both ends support it.
 *  - "lohs": Local-only hotspot. Band selectable on API 36, security is chosen
 *            by the system (WPA2 or WPA3-SAE transition).
 *  - "lan":  Both phones already share a network (router, tethering, even an
 *            open hotspot). Nothing to set up; fastest when the router is Wi-Fi 6/7.
 *
 * Android does not let normal apps create an open (password-less) hotspot;
 * for that use "lan" with a hotspot created from system settings.
 */
@SuppressLint("MissingPermission")
class WifiLink(private val context: Context) {
    private val ble = BleBeacon(context)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val p2p: WifiP2pManager? = context.getSystemService(WifiP2pManager::class.java)
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var channel: WifiP2pManager.Channel? = null
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var p2pReceiver: BroadcastReceiver? = null
    private var hostMode: String? = null
    private var joinedNetwork: Network? = null
    private var joinedSsid: String? = null
    private var hostTxt: Map<String, String> = emptyMap()
    private var localService: WifiP2pDnsSdServiceInfo? = null
    private var serviceRequest: WifiP2pDnsSdServiceRequest? = null
    private val discovered = java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()

    fun capabilities(): Map<String, Any> {
        val sdk = Build.VERSION.SDK_INT
        return mapOf(
            "sdk" to sdk,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "p2p" to (p2p != null && wifi.isP2pSupported),
            "band5" to wifi.is5GHzBandSupported,
            "band6" to (sdk >= 30 && wifi.is6GHzBandSupported),
            "wifi6" to (sdk >= 30 && wifi.isWifiStandardSupported(ScanResult.WIFI_STANDARD_11AX)),
            "wifi7" to (sdk >= 33 && wifi.isWifiStandardSupported(ScanResult.WIFI_STANDARD_11BE)),
            "wpa3" to wifi.isWpa3SaeSupported,
            "p2pR2" to (sdk >= 36 && p2p?.isPccModeSupported == true),
            "p2p6" to (sdk >= 36),
            "lohsBand" to (sdk >= 36),
            "wifiOn" to wifi.isWifiEnabled,
            "vpn" to vpnActive(),
            "bt" to ble.usable,
        )
    }

    /** A VPN can swallow traffic meant for the other phone; the UI says so when a link fails. */
    fun vpnActive(): Boolean = runCatching {
        cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
    }.getOrDefault(false)

    private fun p2pChannel(): WifiP2pManager.Channel {
        channel?.let { return it }
        val mgr = p2p ?: throw IllegalStateException("Wi-Fi Direct is not supported on this device")
        return mgr.initialize(context, Looper.getMainLooper(), null).also { channel = it }
    }

    // ------------------------------------------------------------------ host

    /**
     * band: "auto" | "2" | "5" | "6"; security: "wpa2" | "wpa3".
     * tag: device info appended to the Wi-Fi Direct name (see lib/core/ssid.dart).
     */
    fun host(
        mode: String, band: String, security: String, ssid: String, txt: Map<String, String>,
        cb: (Result<Map<String, Any>>) -> Unit,
    ) {
        stop()
        hostMode = mode
        hostTxt = txt
        when (mode) {
            "p2p" -> hostP2p(ssid, band, security, cb)
            "lohs" -> hostLohs(band, cb)
            else -> cb(Result.success(mapOf("mode" to "lan", "hosts" to localAddresses(preferP2p = false))))
        }
    }

    private fun p2pBand(band: String): Int = when (band) {
        "2" -> WifiP2pConfig.GROUP_OWNER_BAND_2GHZ
        "5" -> WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
        "6" -> if (Build.VERSION.SDK_INT >= 36) WifiP2pConfig.GROUP_OWNER_BAND_6GHZ else WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
        else -> WifiP2pConfig.GROUP_OWNER_BAND_AUTO
    }

    private fun hostP2p(ssid: String, band: String, security: String, cb: (Result<Map<String, Any>>) -> Unit) {
        val mgr = p2p ?: return cb(Result.failure(IllegalStateException("Wi-Fi Direct not supported")))
        val ch = p2pChannel()
        // Derived from the name so the radar can join from a plain Wi-Fi scan.
        val pass = radarPass(ssid)
        val builder = WifiP2pConfig.Builder()
            .setNetworkName(ssid)
            .setPassphrase(pass)
            .enablePersistentMode(false)
            .setGroupOperatingBand(p2pBand(band))
        val wpa3 = security == "wpa3" && Build.VERSION.SDK_INT >= 36 && mgr.isPccModeSupported
        if (Build.VERSION.SDK_INT >= 36 && mgr.isPccModeSupported) {
            builder.setPccModeConnectionType(
                if (wpa3) WifiP2pConfig.PCC_MODE_CONNECTION_TYPE_LEGACY_OR_R2 else WifiP2pConfig.PCC_MODE_CONNECTION_TYPE_LEGACY_ONLY,
            )
        }
        val config = builder.build()

        // A stale group blocks createGroup; remove it first and ignore failures.
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = create()
            override fun onFailure(reason: Int) = create()
            fun create() {
                mgr.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = awaitGroup(0)
                    override fun onFailure(reason: Int) {
                        // Some chips refuse a forced band (e.g. 5 GHz while roaming on a DFS channel).
                        if (band != "auto") hostP2p(ssid, "auto", security, cb)
                        else cb(Result.failure(IllegalStateException("Wi-Fi Direct group failed (${p2pReason(reason)})")))
                    }
                })
            }

            fun awaitGroup(tries: Int) {
                mgr.requestGroupInfo(ch) { g: WifiP2pGroup? ->
                    if (g == null && tries < 20) {
                        main.postDelayed({ awaitGroup(tries + 1) }, 250)
                        return@requestGroupInfo
                    }
                    advertise(g?.networkName ?: ssid, g?.passphrase ?: pass, if (wpa3) "wpa3" else "wpa2", band, g?.frequency ?: 0)
                    ble.advertise(g?.networkName ?: ssid)
                    Diag.i(TAG, "group up: ${g?.networkName} on ${g?.frequency} MHz, beacon=${ble.usable}")
                    cb(Result.success(mapOf(
                        "mode" to "p2p",
                        "ssid" to (g?.networkName ?: ssid),
                        "pass" to (g?.passphrase ?: pass),
                        "freq" to (g?.frequency ?: 0),
                        "band" to band,
                        "security" to if (wpa3) "wpa3" else "wpa2",
                        "hosts" to (listOf("192.168.49.1") + localAddresses(preferP2p = true)).distinct(),
                        "ble" to ble.usable,
                    )))
                }
            }
        })
    }

    /**
     * Wi-Fi Direct DNS-SD advertisement: lets nearby senders find us and see
     * our buddy, Wi-Fi tech and requirements, then connect with one tap.
     */
    private fun advertise(ssid: String, pass: String, security: String, band: String, freq: Int) {
        val mgr = p2p ?: return
        val ch = p2pChannel()
        // The instance name is the group name: it carries buddy, Wi-Fi tech and
        // flags, and the radar credentials derive from it, so the short PTR
        // answer alone is enough to connect. Large TXT records often don't make
        // it through Wi-Fi Direct discovery, so the TXT only adds extras.
        val txt = hashMapOf("o" to (hostTxt["o"] ?: DEFAULT_PORT.toString()), "i" to (hostTxt["i"] ?: ""))
        val info = WifiP2pDnsSdServiceInfo.newInstance(ssid, SERVICE_TYPE, txt)
        localService = info
        mgr.addLocalService(ch, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Diag.i(TAG, "advertising $ssid (${txt.keys})")
                keepDiscoverable()
            }
            override fun onFailure(reason: Int) {
            Diag.w(TAG, "addLocalService failed: ${p2pReason(reason)}")
        }
        })
    }

    // Peer discovery lapses after ~2 minutes; while hosting, renew it so
    // service queries keep getting answered.
    private val discoverable = object : Runnable {
        override fun run() {
            val mgr = p2p ?: return
            val ch = channel ?: return
            if (localService == null) return
            mgr.discoverPeers(ch, null)
            main.postDelayed(this, 60_000)
        }
    }

    private fun keepDiscoverable() {
        main.removeCallbacks(discoverable)
        discoverable.run()
    }

    private fun logListener(what: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {
            Diag.i(TAG, "$what ok")
        }
        override fun onFailure(reason: Int) {
            Diag.w(TAG, "$what failed: ${p2pReason(reason)}")
        }
    }

    private var lastDiscover = 0L

    /** Sender side: start looking for receivers advertising the service. */
    fun startDiscovery() {
        ble.scan()
        lastDiscover = System.currentTimeMillis()
        val mgr = p2p ?: return
        val ch = p2pChannel()
        mgr.setDnsSdResponseListeners(ch, { instance, type, device ->
            Diag.i(TAG, "service: $instance $type from ${device.deviceAddress}")
            if (type.contains("_wingdrop", ignoreCase = true) && TAG_RE.matches(instance)) {
                val prev = discovered[device.deviceAddress] ?: emptyMap()
                discovered[device.deviceAddress] = prev + mapOf("s" to instance, "seen" to System.currentTimeMillis().toString())
            }
        }, { fullDomain, record, device ->
            Diag.i(TAG, "txt: $fullDomain from ${device.deviceAddress} keys=${record.keys}")
            if (fullDomain.contains("_wingdrop", ignoreCase = true)) {
                val prev = discovered[device.deviceAddress] ?: emptyMap()
                discovered[device.deviceAddress] = prev + record + ("seen" to System.currentTimeMillis().toString())
            }
        })
        // Query every Bonjour record, not just our service type: a type-only
        // request is a PTR query, and TXT records (with the connection
        // details) are then never delivered.
        val req = WifiP2pDnsSdServiceRequest.newInstance()
        serviceRequest?.let { mgr.removeServiceRequest(ch, it, null) }
        serviceRequest = req
        mgr.addServiceRequest(ch, req, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = mgr.discoverServices(ch, logListener("discoverServices"))
            override fun onFailure(reason: Int) {
            Diag.w(TAG, "addServiceRequest failed: ${p2pReason(reason)}")
        }
        })
    }

    /** Receivers found so far, merged with their live scan RSSI when we have it. */
    /**
     * Receivers around us. The Wi-Fi scan is the reliable source: a WingDrop
     * group's name carries the buddy, Wi-Fi tech and flags, and its radar
     * credentials are derived from that name. DNS-SD records, when a phone
     * answers them, add the device id (for trusted buddies) and exact port.
     */
    fun discovered(): List<Map<String, Any>> {
        // Service discovery lapses after a while; renew it, but not so often
        // that each renewal cuts the previous search cycle short.
        val now = System.currentTimeMillis()
        if (now - lastDiscover > 8_000) {
            lastDiscover = now
            p2p?.let { mgr -> channel?.let { ch -> mgr.discoverServices(ch, logListener("discoverServices")) } }
        }
        val cutoff = System.currentTimeMillis() - 60_000
        // Bluetooth may have been switched on since the radar opened.
        ble.scan()
        val scan = nearby()
        val scanBySsid = scan.associateBy { it["ssid"] as String }
        val bySsid = LinkedHashMap<String, Map<String, Any>>()
        fun entry(ssid: String, extra: Map<String, String>) {
            val m = TAG_RE.matchEntire(ssid) ?: return
            val flags = m.groupValues[3].toInt(16)
            val seen = scanBySsid[ssid]
            val freq = (seen?.get("freq") as Int?) ?: 0
            bySsid[ssid] = mapOf(
                "v" to "1", "s" to ssid, "p" to radarPass(ssid), "o" to (extra["o"] ?: DEFAULT_PORT.toString()),
                "k" to android.util.Base64.encodeToString(radarKey(ssid), android.util.Base64.NO_WRAP),
                "a" to m.groupValues[1].toInt(36).toString(), "w" to (if (m.groupValues[2] == "E") "6E" else m.groupValues[2]),
                "f" to (flags and 3).toString(), "sec" to (if (flags and 4 != 0) "wpa3" else "wpa2"),
                "n" to m.groupValues[4], "fq" to freq.toString(), "i" to (extra["i"] ?: ""),
                "bars" to ((seen?.get("bars") as Int?) ?: -1), "freq" to freq,
            )
        }
        for (r in scan) entry(r["ssid"] as String, emptyMap())
        val heard = ble.heard()
        for ((ssid, rssi) in heard) {
            entry(ssid, emptyMap())
            // BLE gives a live signal strength even when Wi-Fi scans are off-limits.
            bySsid[ssid]?.let { bySsid[ssid] = it + ("bars" to bars(rssi + BLE_TO_WIFI_DB)) }
        }
        for (d in discovered.values) {
            if ((d["seen"]?.toLongOrNull() ?: 0) < cutoff) continue
            entry(d["s"] ?: continue, d)
        }
        Diag.i(TAG, "radar: ${heard.size} via BLE, ${discovered.size} via DNS-SD, ${scan.size} in scan, ${bySsid.size} receiver(s)")
        return bySsid.values.toList()
    }

    fun stopDiscovery() {
        ble.stopScan()
        val mgr = p2p ?: return
        val ch = channel ?: return
        serviceRequest?.let { mgr.removeServiceRequest(ch, it, null) }
        serviceRequest = null
        mgr.stopPeerDiscovery(ch, null)
        discovered.clear()
    }

    private fun hostLohs(band: String, cb: (Result<Map<String, Any>>) -> Unit) {
        val callback = object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                reservation = r
                val conf = r.softApConfiguration
                val ssid = if (Build.VERSION.SDK_INT >= 33) conf.wifiSsid?.toString()?.trim('"') else @Suppress("DEPRECATION") conf.ssid
                val sec = when (conf.securityType) {
                    SoftApConfiguration.SECURITY_TYPE_OPEN -> "open"
                    SoftApConfiguration.SECURITY_TYPE_WPA3_SAE -> "wpa3"
                    SoftApConfiguration.SECURITY_TYPE_WPA3_SAE_TRANSITION -> "wpa3t"
                    else -> "wpa2"
                }
                // The AP interface needs a moment to get its address.
                main.postDelayed({
                    cb(Result.success(mapOf(
                        "mode" to "lohs", "ssid" to (ssid ?: ""), "pass" to (conf.passphrase ?: ""),
                        "security" to sec, "band" to band, "freq" to 0,
                        "hosts" to localAddresses(preferP2p = false),
                    )))
                }, 600)
            }

            override fun onFailed(reason: Int) {
                cb(Result.failure(IllegalStateException("Local hotspot failed ($reason). Turn off the regular hotspot and retry.")))
            }
        }
        if (Build.VERSION.SDK_INT >= 36 && band != "auto") {
            val b = when (band) {
                "2" -> SoftApConfiguration.BAND_2GHZ
                "6" -> SoftApConfiguration.BAND_6GHZ
                else -> SoftApConfiguration.BAND_5GHZ
            }
            try {
                // Channel 0 = let the driver pick the best channel in that band.
                val conf = SoftApConfiguration.Builder().setChannels(SparseIntArray().apply { put(b, 0) }).build()
                wifi.startLocalOnlyHotspotWithConfiguration(conf, context.mainExecutor, callback)
                return
            } catch (_: Exception) {
                // Fall through to the system-chosen configuration.
            }
        }
        wifi.startLocalOnlyHotspot(callback, main)
    }

    // ------------------------------------------------------------------ join

    /** Returns {netHandle, hosts}. */
    fun join(qr: Map<String, Any?>, done: (Result<Map<String, Any>>) -> Unit) {
        // Exactly one answer per join, logged either way.
        var answered = false
        val cb: (Result<Map<String, Any>>) -> Unit = { r ->
            if (!answered) {
                answered = true
                r.onSuccess { Diag.stage(TAG, "joined", "hosts=${it["hosts"]}") }
                    .onFailure { Diag.stage(TAG, "join_failed", it.message ?: "") }
                done(r)
            }
        }
        Diag.stage(TAG, "joining", "mode=${qr["m"]} ssid=${qr["s"]} freq=${qr["fq"]} sec=${qr["sec"]}")
        // Wi-Fi Direct and hotspot joins need Wi-Fi on; apps can't switch it on
        // themselves (Android 10+), so the UI asks the person to.
        if (qr["m"] != "lan" && !wifi.isWifiEnabled) {
            return cb(Result.failure(IllegalStateException("wifi_off")))
        }
        if (qr["m"] != "lan" && (qr["s"] as String?).isNullOrEmpty()) {
            return cb(Result.failure(IllegalStateException("bad_code")))
        }
        // Hard ceiling for the whole join, whatever the platform does.
        main.postDelayed({ cb(Result.failure(IllegalStateException("join_timeout"))) }, 75_000)
        stopDiscovery()
        leave()
        joinedSsid = qr["s"] as String?
        when (qr["m"]) {
            // Compact QR codes leave the Wi-Fi Direct passphrase out: it derives from the name.
            "p2p" -> joinP2p(if ((qr["p"] as String?).isNullOrEmpty()) qr + ("p" to radarPass(qr["s"] as String)) else qr, cb)
            "lohs" -> joinWifi(qr, cb)
            else -> cb(Result.success(mapOf("netHandle" to 0L)))
        }
    }

    private fun joinP2p(qr: Map<String, Any?>, cb: (Result<Map<String, Any>>) -> Unit) {
        val mgr = p2p ?: return joinWifi(qr + ("sec" to "wpa2"), cb)
        val ch = p2pChannel()
        val freq = (qr["fq"] as? Number)?.toInt() ?: 0
        val builder = WifiP2pConfig.Builder()
            .setNetworkName(qr["s"] as String)
            .setPassphrase(qr["p"] as String)
            .enablePersistentMode(false)
        // Knowing the exact channel skips a full scan. Never force a band we
        // may not support: the network name + passphrase are what matter.
        if (freq > 0) builder.setGroupOperatingFrequency(freq)
        else builder.setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
        if (Build.VERSION.SDK_INT >= 36 && mgr.isPccModeSupported) {
            builder.setPccModeConnectionType(
                if (qr["sec"] == "wpa3") WifiP2pConfig.PCC_MODE_CONNECTION_TYPE_LEGACY_OR_R2
                else WifiP2pConfig.PCC_MODE_CONNECTION_TYPE_LEGACY_ONLY,
            )
        }
        var done = false
        val timeout = Runnable { fallback("timed out") }
        fun finish(r: Result<Map<String, Any>>) {
            if (done) return
            done = true
            main.removeCallbacks(timeout)
            p2pReceiver?.let { runCatching { context.unregisterReceiver(it) } }
            p2pReceiver = null
            cb(r)
        }
        // Every Wi-Fi Direct group is also a plain WPA2 access point: if the
        // P2P join doesn't work out, join it like any Wi-Fi network instead.
        fallbackJoin = { why ->
            if (!done) {
                done = true
                Diag.stage(TAG, "fallback", why)
                Diag.w(TAG, "Wi-Fi Direct join failed ($why), joining as a regular Wi-Fi client")
                p2pReceiver?.let { runCatching { context.unregisterReceiver(it) } }
                p2pReceiver = null
                mgr.cancelConnect(ch, null)
                joinWifi(qr + ("sec" to "wpa2"), cb)
            }
        }
        p2pReceiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                mgr.requestConnectionInfo(ch) { info ->
                    if (info?.groupFormed == true && !info.isGroupOwner) {
                        mgr.requestGroupInfo(ch) { g ->
                            Diag.i(TAG, "joined Wi-Fi Direct group ${g?.networkName} on ${g?.frequency} MHz")
                            finish(Result.success(mapOf(
                                "netHandle" to 0L,
                                "freq" to (g?.frequency ?: 0),
                                "hosts" to listOfNotNull(info.groupOwnerAddress?.hostAddress),
                            )))
                        }
                    }
                }
            }
        }
        val filter = IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(p2pReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(p2pReceiver, filter)
        Diag.i(TAG, "joining Wi-Fi Direct group ${qr["s"]} (freq=$freq, sec=${qr["sec"]})")
        mgr.connect(ch, builder.build(), object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                main.postDelayed(timeout, 20_000)
            }

            override fun onFailure(reason: Int) = fallback(p2pReason(reason))
        })
    }

    private var fallbackJoin: ((String) -> Unit)? = null
    private fun fallback(why: String) {
        fallbackJoin?.invoke(why)
    }

    private fun joinWifi(qr: Map<String, Any?>, cb: (Result<Map<String, Any>>) -> Unit) {
        Diag.i(TAG, "joining ${qr["s"]} as a Wi-Fi client (sec=${qr["sec"]})")
        // Android shows its own "connect to this network?" popup for this.
        Diag.stage(TAG, "system_prompt")
        val spec = WifiNetworkSpecifier.Builder().setSsid(qr["s"] as String).apply {
            val pass = qr["p"] as? String
            when (qr["sec"]) {
                "open" -> {}
                "wpa3" -> setWpa3Passphrase(pass!!)
                else -> setWpa2Passphrase(pass!!)
            }
        }.build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec)
            .build()
        var done = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (done) return
                done = true
                joinedNetwork = network
                // The group owner isn't always 192.168.49.1: ask the network itself
                // for its gateway / DHCP server and try those too.
                val lp = cm.getLinkProperties(network)
                val hosts = buildList {
                    lp?.routes?.forEach { r -> r.gateway?.takeIf { it is Inet4Address && !it.isAnyLocalAddress }?.hostAddress?.let(::add) }
                    if (Build.VERSION.SDK_INT >= 30) lp?.dhcpServerAddress?.hostAddress?.let(::add)
                }.distinct()
                Diag.i(TAG, "joined as Wi-Fi client, gateway candidates=$hosts")
                main.post { cb(Result.success(mapOf("netHandle" to network.networkHandle, "hosts" to hosts))) }
            }

            override fun onUnavailable() {
                if (done) return
                done = true
                main.post { cb(Result.failure(IllegalStateException("join_unavailable"))) }
            }
        }
        netCallback = callback
        runCatching { cm.requestNetwork(request, callback, 45_000) }
            .onFailure { main.post { cb(Result.failure(IllegalStateException("join_unavailable: ${it.message}"))) } }
    }

    // ------------------------------------------------------------------ teardown

    /** Receivers around us, read from ordinary Wi-Fi scan results (Wi-Fi Direct groups beacon too). */
    fun nearby(): List<Map<String, Any>> {
        @Suppress("DEPRECATION")
        runCatching { wifi.startScan() } // throttled by the OS; cached results are fine
        return runCatching { wifi.scanResults }.onFailure { Diag.w(TAG, "scan results unavailable: $it") }
            .getOrDefault(emptyList())
            .mapNotNull { r ->
                val ssid = if (Build.VERSION.SDK_INT >= 33) r.wifiSsid?.toString()?.trim('"') else @Suppress("DEPRECATION") r.SSID
                if (ssid == null || !ssid.startsWith("DIRECT-") || !ssid.contains("-WD")) return@mapNotNull null
                mapOf("ssid" to ssid, "level" to r.level, "freq" to r.frequency, "bars" to bars(r.level))
            }
            .groupBy { it["ssid"] }.map { (_, v) -> v.maxBy { it["level"] as Int } }
    }

    /** Signal to the receiver we joined: live RSSI for hotspot links, scan RSSI for Wi-Fi Direct. */
    fun signal(): Map<String, Any>? {
        joinedNetwork?.let { n ->
            val info = cm.getNetworkCapabilities(n)?.transportInfo as? android.net.wifi.WifiInfo
            if (info != null && info.rssi > -127) {
                return mapOf("rssi" to info.rssi, "bars" to bars(info.rssi), "mbps" to info.txLinkSpeedMbps)
            }
        }
        val ssid = joinedSsid ?: return null
        val hit = runCatching { wifi.scanResults }.getOrDefault(emptyList()).firstOrNull {
            val s = if (Build.VERSION.SDK_INT >= 33) it.wifiSsid?.toString()?.trim('"') else @Suppress("DEPRECATION") it.SSID
            s == ssid
        } ?: return null
        return mapOf("rssi" to hit.level, "bars" to bars(hit.level), "mbps" to 0)
    }

    private fun bars(rssi: Int): Int =
        if (Build.VERSION.SDK_INT >= 30) wifi.calculateSignalLevel(rssi) * 4 / maxOf(1, wifi.maxSignalLevel)
        else @Suppress("DEPRECATION") WifiManager.calculateSignalLevel(rssi, 5)

    fun leave() {
        joinedNetwork = null
        netCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        netCallback = null
        p2pReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        p2pReceiver = null
        channel?.let { ch -> p2p?.removeGroup(ch, null) }
    }

    fun stop() {
        ble.stopAdvertising()
        localService?.let { svc -> channel?.let { ch -> p2p?.removeLocalService(ch, svc, null) } }
        localService = null
        main.removeCallbacks(discoverable)
        reservation?.close()
        reservation = null
        if (hostMode == "p2p") channel?.let { ch -> p2p?.removeGroup(ch, null) }
        hostMode = null
        leave()
    }

    /** IPv4 addresses of Wi-Fi / AP / P2P interfaces. Cellular and VPN are skipped. */
    fun localAddresses(preferP2p: Boolean): List<String> {
        val out = mutableListOf<Pair<Int, String>>()
        for (nif in NetworkInterface.getNetworkInterfaces() ?: return emptyList()) {
            if (!nif.isUp || nif.isLoopback) continue
            val n = nif.name
            if (n.startsWith("rmnet") || n.startsWith("ccmni") || n.startsWith("tun") || n.startsWith("dummy") || n.startsWith("ipsec")) continue
            val rank = when {
                n.startsWith("p2p") -> if (preferP2p) 0 else 2
                n.startsWith("ap") || n.startsWith("swlan") || n.startsWith("wlan1") -> 1
                n.startsWith("wlan") -> if (preferP2p) 3 else 2
                else -> 4
            }
            for (a in nif.inetAddresses) if (a is Inet4Address) out += rank to a.hostAddress!!
        }
        return out.sortedBy { it.first }.map { it.second }
    }

    companion object {
        private const val TAG = "WingDropWifi"
        private const val SERVICE_TYPE = "_wingdrop._tcp"
        const val DEFAULT_PORT = 42420
        // BLE advertises at lower power than Wi-Fi transmits; nudge it so bars read alike.
        private const val BLE_TO_WIFI_DB = 15
        private val TAG_RE = Regex("^DIRECT-..-WD([0-9a-z])([4567E])([0-9a-f])(?:-(.*))?$")

        // Radar credentials are public by design (any WingDrop phone may knock,
        // exactly like the advertised DNS-SD record); the receiver still has to
        // accept each sender. QR codes and trusted bonds use secret keys.
        private val APP_KEY = "WingDrop radar v1 - public by design".toByteArray()

        private fun derive(label: String, ssid: String): ByteArray =
            javax.crypto.Mac.getInstance("HmacSHA256").run {
                init(javax.crypto.spec.SecretKeySpec(APP_KEY, "HmacSHA256"))
                doFinal("$label:$ssid".toByteArray())
            }

        fun radarKey(ssid: String): ByteArray = derive("radar-key", ssid)

        fun radarPass(ssid: String): String {
            val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
            return derive("wifi-pass", ssid).take(20).joinToString("") { alphabet[(it.toInt() and 0xff) % alphabet.length].toString() }
        }

        /** A fresh Wi-Fi Direct group name: Android's "DIRECT-xy-" + our device tag (32-byte SSID limit). */
        fun newGroupName(tag: String): String {
            val rnd = SecureRandom()
            val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
            var ssid = "DIRECT-" + (1..2).map { alphabet[rnd.nextInt(alphabet.length)] }.joinToString("") + "-" + tag
            while (ssid.toByteArray().size > 32) ssid = ssid.dropLast(1)
            return ssid
        }
    }

    private fun p2pReason(r: Int) = when (r) {
        WifiP2pManager.P2P_UNSUPPORTED -> "unsupported"
        WifiP2pManager.BUSY -> "busy, is Wi-Fi on?"
        else -> "error $r"
    }
}
