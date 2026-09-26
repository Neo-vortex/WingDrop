package ir.neovortex.wingdrop

import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.util.Size
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen QR scanner: CameraX preview + ZXing decoding on a background
 * thread. Everything ships inside the APK. Returns the text in "value".
 */
class ScanActivity : ComponentActivity() {
    private val analysis = Executors.newSingleThreadExecutor()
    private val found = AtomicBoolean(false)
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            DecodeHintType.TRY_HARDER to true,
        ))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dark = intent.getBooleanExtra("dark", true)
        val bg = if (dark) Color.parseColor("#151A18") else Color.parseColor("#F6F2EA")
        val fg = if (dark) Color.parseColor("#E6E2DA") else Color.parseColor("#1D2320")
        window.statusBarColor = Color.TRANSPARENT

        val root = FrameLayout(this).apply { setBackgroundColor(bg) }
        val preview = PreviewView(this).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            implementationMode = PreviewView.ImplementationMode.PERFORMANCE
            alpha = 0f
        }
        root.addView(preview, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(Frame(this, bg), FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val hint = TextView(this).apply {
            text = intent.getStringExtra("hint") ?: ""
            setTextColor(fg)
            textSize = 17f
            gravity = Gravity.CENTER
            val font = if (intent.getBooleanExtra("fa", false)) "fonts/Vazirmatn-Regular.ttf" else "fonts/Nunito-Medium.ttf"
            runCatching {
                typeface = android.graphics.Typeface.createFromAsset(assets, "flutter_assets/assets/$font")
            }
        }
        root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            setMargins(48, 0, 48, (resources.displayMetrics.heightPixels * 0.14).toInt())
        })
        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setColorFilter(fg)
            background = null
            setOnClickListener { finish() }
        }
        root.addView(close, FrameLayout.LayoutParams(144, 144, Gravity.TOP or Gravity.END).apply { setMargins(0, 96, 24, 0) })
        setContentView(root)

        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val previewUse = Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
            val analyzer = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                        .build(),
                )
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analyzer.setAnalyzer(analysis) { decode(it) }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analyzer)
                // Fade the camera in instead of popping it on.
                preview.animate().alpha(1f).setDuration(500).start()
            }.onFailure { fail("camera: ${it.message}") }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun decode(image: ImageProxy) {
        image.use {
            if (found.get()) return
            val plane = it.planes[0]
            val buf = plane.buffer
            val rowStride = plane.rowStride
            val w = it.width
            val h = it.height
            val data = ByteArray(rowStride * h)
            buf.get(data, 0, minOf(data.size, buf.remaining()))
            val source = PlanarYUVLuminanceSource(data, rowStride, h, 0, 0, w, h, false)
            val text = try {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
            } catch (_: NotFoundException) {
                // QR codes shown on phone screens are sometimes light-on-dark.
                runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source.invert()))).text }.getOrNull()
            } catch (_: Exception) {
                null
            } finally {
                reader.reset()
            }
            if (text != null && found.compareAndSet(false, true)) {
                Diag.i("WingDropScan", "decoded ${text.length} chars: ${text.take(12)}…")
                runOnUiThread {
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    setResult(RESULT_OK, Intent().putExtra("value", text))
                    finish()
                    @Suppress("DEPRECATION")
                    overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out)
                }
            }
        }
    }

    /** Tell the app what went wrong instead of just disappearing. */
    private fun fail(why: String) {
        Diag.w("WingDropScan", why)
        setResult(RESULT_FIRST_USER, Intent().putExtra("error", why))
        finish()
    }

    override fun onDestroy() {
        analysis.shutdown()
        super.onDestroy()
    }

    /** Soft dimmed surround with a rounded window where the code goes. */
    private class Frame(context: android.content.Context, private val bg: Int) : View(context) {
        private val dim = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(150, Color.red(bg), Color.green(bg), Color.blue(bg)) }
        private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 6f
            color = Color.parseColor("#9DBBA6")
        }
        private val path = Path()

        override fun onDraw(canvas: Canvas) {
            val side = minOf(width, height) * 0.68f
            val left = (width - side) / 2
            val top = (height - side) / 2.3f
            val r = RectF(left, top, left + side, top + side)
            path.reset()
            path.fillType = Path.FillType.EVEN_ODD
            path.addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
            path.addRoundRect(r, 48f, 48f, Path.Direction.CW)
            canvas.drawPath(path, dim)
            canvas.drawRoundRect(r, 48f, 48f, stroke)
        }
    }
}
