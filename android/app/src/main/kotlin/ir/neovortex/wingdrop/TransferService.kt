package ir.neovortex.wingdrop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process, CPU and radio at full power while a link is up: foreground
 * service + partial wake lock + Wi-Fi locks that disable power-save (PSM adds
 * latency and throttles throughput on many chipsets).
 */
class TransferService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifiPerf: WifiManager.WifiLock? = null
    private var wifiLowLatency: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Transfers", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("WingDrop")
            .setContentText(intent?.getStringExtra("text") ?: "Transfer link active")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(1, n)
        }
        acquire()
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun acquire() {
        if (wake == null) {
            wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wingdrop:transfer")
                .apply { setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L) }
        }
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        if (wifiPerf == null) {
            wifiPerf = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "wingdrop:perf")
                .apply { setReferenceCounted(false); acquire() }
        }
        if (wifiLowLatency == null) {
            wifiLowLatency = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "wingdrop:ll")
                .apply { setReferenceCounted(false); acquire() }
        }
    }

    override fun onDestroy() {
        wake?.release()
        wifiPerf?.release()
        wifiLowLatency?.release()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "transfer"

        fun start(context: Context, text: String) {
            context.startForegroundService(Intent(context, TransferService::class.java).putExtra("text", text))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TransferService::class.java))
        }
    }
}
