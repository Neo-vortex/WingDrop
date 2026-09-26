package ir.neovortex.wingdrop

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Fast discovery over Bluetooth Low Energy. The receiver beacons its
 * Wi-Fi Direct group name (buddy, Wi-Fi tech and flags are encoded in it and
 * the radar credentials derive from it); senders hear it within a second and
 * get a live signal strength. Wi-Fi Direct DNS-SD stays as the fallback.
 */
@SuppressLint("MissingPermission")
class BleBeacon(context: Context) {
    private val bt = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var advertising: AdvertiseCallback? = null
    private var scanning: ScanCallback? = null
    private val seen = ConcurrentHashMap<String, Pair<Int, Long>>() // ssid -> (rssi, time)

    // What the app wants right now, so both resume the moment Bluetooth is
    // switched on (the radar asks for it) without waiting for a new session.
    private var beaconName: String? = null
    private var scanWanted = false

    init {
        context.applicationContext.registerReceiver(object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0) != BluetoothAdapter.STATE_ON) return
                // The old callbacks died with the adapter.
                advertising = null
                scanning = null
                beaconName?.let { Diag.i(TAG, "Bluetooth on: beacon resumes"); advertise(it) }
                if (scanWanted) { Diag.i(TAG, "Bluetooth on: scan resumes"); scan() }
            }
        }, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    val usable: Boolean get() = Build.VERSION.SDK_INT >= 31 && bt?.isEnabled == true

    /** Receiver: announce the group name. */
    fun advertise(ssid: String) {
        if (ssid == beaconName && advertising != null) return
        stopAdvertising()
        beaconName = ssid
        if (!usable) return
        val adv = bt?.bluetoothLeAdvertiser ?: return
        // Legacy advertising leaves 24 bytes of manufacturer data after the
        // flags and header; the name minus "DIRECT-" fits (it is <= 25 bytes).
        val payload = ssid.removePrefix("DIRECT-").toByteArray().take(24).toByteArray()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(MANUFACTURER_ID, payload)
            .build()
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(s: AdvertiseSettings) {
                Diag.i(TAG, "beacon on: $ssid")
            }

            override fun onStartFailure(errorCode: Int) {
                Diag.w(TAG, "beacon failed: $errorCode")
                if (advertising === this) advertising = null
            }
        }
        advertising = cb
        runCatching { adv.startAdvertising(settings, data, cb) }.onFailure { Diag.w(TAG, "beacon: $it") }
    }

    fun stopAdvertising() {
        advertising?.let { cb -> runCatching { bt?.bluetoothLeAdvertiser?.stopAdvertising(cb) } }
        advertising = null
        beaconName = null
    }

    /** Sender: listen for receivers' beacons. */
    fun scan() {
        scanWanted = true
        if (scanning != null || !usable) return
        val scanner = bt?.bluetoothLeScanner ?: return
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val bytes = result.scanRecord?.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
                val ssid = "DIRECT-" + String(bytes)
                if (seen.put(ssid, result.rssi to System.currentTimeMillis()) == null) Diag.i(TAG, "heard $ssid (${result.rssi} dBm)")
            }

            override fun onScanFailed(errorCode: Int) {
                Diag.w(TAG, "BLE scan failed: $errorCode")
            }
        }
        val filter = ScanFilter.Builder().setManufacturerData(MANUFACTURER_ID, byteArrayOf()).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanning = cb
        runCatching { scanner.startScan(listOf(filter), settings, cb) }.onFailure {
            Diag.w(TAG, "BLE scan: $it")
            scanning = null
        }
    }

    fun stopScan() {
        scanWanted = false
        scanning?.let { cb -> runCatching { bt?.bluetoothLeScanner?.stopScan(cb) } }
        scanning = null
        seen.clear()
    }

    /** Receivers heard in the last 15 s: group name -> RSSI. */
    fun heard(): Map<String, Int> {
        val cutoff = System.currentTimeMillis() - 15_000
        return seen.filterValues { it.second > cutoff }.mapValues { it.value.first }
    }

    companion object {
        private const val TAG = "WingDropBle"
        // 0xFFFF is the Bluetooth SIG's company id reserved for testing / no company.
        private const val MANUFACTURER_ID = 0xFFFF
    }
}
