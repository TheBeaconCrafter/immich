package app.alextran.immich.hdr

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter composites into an 8-bit SDR surface, and platform views either inherit that or slow the whole app
 * down. HDR photos are therefore drawn by an ImageView in the window itself, below a transparent Flutter surface.
 * The Dart viewer clears the photo area while an HDR photo is shown and streams the photo's on-screen rect.
 */
class HdrImagePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  companion object {
    const val CHANNEL = "immich/hdr_image"
  }

  private var channel: MethodChannel? = null
  private var host: HdrHost? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    HdrImageLoader.initialize(binding.applicationContext)
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply { setMethodCallHandler(this@HdrImagePlugin) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding.activity)
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding.activity)
  override fun onDetachedFromActivityForConfigChanges() = detach()
  override fun onDetachedFromActivity() = detach()

  private fun attach(activity: Activity) {
    detach()
    if (HdrMode.isActive(activity)) {
      host = HdrHost(activity)
    }
  }

  private fun detach() {
    host?.destroy()
    host = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isSupported" -> result.success(host != null)
      "setEnabled" -> {
        HdrMode.setEnabled(HdrImageLoader.context, call.arguments as? Boolean ?: true)
        result.success(null)
      }
      "show" -> {
        val host = host ?: return result.success(mapOf("hdr" to false))
        host.show(
          token = call.argument<Number>("token")!!.toLong(),
          localId = call.argument<String>("localId"),
          url = call.argument<String>("url"),
          maxSize = call.argument<Number>("maxSize")?.toInt() ?: HdrImageLoader.DEFAULT_MAX_SIZE,
          onResult = result::success,
        )
      }
      "update" -> {
        host?.update(
          token = call.argument<Number>("token")!!.toLong(),
          left = call.argument<Number>("left")!!.toFloat(),
          top = call.argument<Number>("top")!!.toFloat(),
          width = call.argument<Number>("width")!!.toFloat(),
          height = call.argument<Number>("height")!!.toFloat(),
        )
        result.success(null)
      }
      "hide" -> {
        host?.hide(call.argument<Number>("token")!!.toLong())
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }
}

/**
 * Decides once per activity whether Flutter renders transparently on top of the HDR layer. Only HDR-capable
 * displays pay for the transparent surface; toggling the setting takes effect on the next app start.
 */
object HdrMode {
  private const val PREFS = "immich.hdr"
  private const val KEY_ENABLED = "enabled"
  private val active = java.util.WeakHashMap<Activity, Boolean>()

  fun backgroundMode(activity: Activity): BackgroundMode {
    val enabled = active.getOrPut(activity) {
      isDisplayCapable(activity) &&
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, true)
    }
    return if (enabled) BackgroundMode.transparent else BackgroundMode.opaque
  }

  /** Call after `super.onCreate`: Flutter clears the window background in transparent mode. */
  fun onCreate(activity: Activity) {
    if (!isActive(activity)) return
    val attrs = activity.theme.obtainStyledAttributes(intArrayOf(android.R.attr.windowBackground))
    activity.window.setBackgroundDrawable(attrs.getDrawable(0))
    attrs.recycle()
  }

  fun isActive(activity: Activity) = active[activity] == true

  fun setEnabled(context: Context, enabled: Boolean) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
  }

  private fun isDisplayCapable(activity: Activity): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
    val display = activity.display ?: return false
    return display.isHdrSdrRatioAvailable
  }
}

/** The native layer below Flutter. Only one photo is shown at a time, owned by the latest `show` token. */
private class HdrHost(private val activity: Activity) {
  private val mainHandler = Handler(Looper.getMainLooper())
  private val imageView = ImageView(activity).apply {
    scaleType = ImageView.ScaleType.MATRIX
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
  }
  private val container = FrameLayout(activity).apply {
    setBackgroundColor(Color.BLACK)
    visibility = View.GONE
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    addView(imageView, FrameLayout.LayoutParams(MATCH, MATCH))
  }
  private val content: ViewGroup? = activity.findViewById(android.R.id.content)
  private val matrix = Matrix()

  private var token = -1L
  private var signal: CancellationSignal? = null
  private var bitmap: Bitmap? = null
  private var rect: FloatArray? = null

  init {
    content?.addView(container, 0, ViewGroup.LayoutParams(MATCH, MATCH))
  }

  fun show(token: Long, localId: String?, url: String?, maxSize: Int, onResult: (Map<String, Any?>) -> Unit) {
    clear()
    this.token = token
    val signal = CancellationSignal().also { this.signal = it }

    HdrImageLoader.load(localId, url, maxSize, signal) { result ->
      mainHandler.post {
        if (this.token != token || signal.isCanceled) {
          result.getOrNull()?.recycle()
          return@post onResult(mapOf("hdr" to false))
        }
        val bitmap = result.getOrElse {
          Log.w(TAG, "Failed to load HDR image", it)
          return@post onResult(mapOf("hdr" to false, "error" to it.message))
        }
        Log.i(TAG, "Decoded ${bitmap.width}x${bitmap.height} config=${bitmap.config} gainmap=${hasGainmap(bitmap)}")
        if (!isHdr(bitmap)) {
          bitmap.recycle()
          return@post onResult(mapOf("hdr" to false))
        }

        this.bitmap = bitmap
        imageView.setImageBitmap(bitmap)
        applyMatrix()
        container.visibility = View.VISIBLE
        setWindowHdr(true)
        // Reply once the photo has been drawn, so Flutter never reveals an empty layer.
        container.postOnAnimation { container.post { if (this.token == token) onResult(mapOf("hdr" to true)) } }
      }
    }
  }

  fun update(token: Long, left: Float, top: Float, width: Float, height: Float) {
    if (token != this.token) return
    rect = floatArrayOf(left, top, width, height)
    applyMatrix()
  }

  fun hide(token: Long) {
    if (token == this.token) clear()
  }

  fun destroy() {
    clear()
    content?.removeView(container)
  }

  private fun clear() {
    token = -1L
    signal?.cancel()
    signal = null
    rect = null
    container.visibility = View.GONE
    imageView.setImageDrawable(null)
    bitmap = null
    setWindowHdr(false)
  }

  private fun applyMatrix() {
    val bitmap = bitmap ?: return
    val (left, top, width, height) = rect ?: return
    // Flutter reports coordinates relative to the FlutterView, which shares the content root's origin.
    matrix.setScale(width / bitmap.width, height / bitmap.height)
    matrix.postTranslate(left, top)
    imageView.imageMatrix = matrix
  }

  private fun setWindowHdr(enabled: Boolean) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
    val mode = if (enabled) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
    val window = activity.window
    if (window.colorMode != mode) {
      window.colorMode = mode
      Log.i(TAG, "Window colorMode=${window.colorMode} (requested $mode), hdrSdrRatio=${activity.display?.hdrSdrRatio}")
    }
  }

  private companion object {
    const val TAG = "HdrHost"
    const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT

    fun hasGainmap(bitmap: Bitmap) =
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && bitmap.hasGainmap()

    fun isHdr(bitmap: Bitmap): Boolean {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
      if (bitmap.hasGainmap()) return true
      // HLG / PQ stills without a gain map, e.g. HDR AVIF.
      val colorSpace = bitmap.colorSpace ?: return false
      return colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_HLG) ||
        colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_PQ)
    }
  }
}
