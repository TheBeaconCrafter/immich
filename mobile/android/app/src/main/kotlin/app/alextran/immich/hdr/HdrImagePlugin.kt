package app.alextran.immich.hdr

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.os.Build
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
    HdrCache.initialize(binding.applicationContext)
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

  private fun source(call: MethodCall) = HdrCache.Source(
    localId = call.argument<String>("localId"),
    url = call.argument<String>("url"),
    maxSize = call.argument<Number>("maxSize")?.toInt() ?: HdrImageLoader.DEFAULT_MAX_SIZE,
  )

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isSupported" -> result.success(host != null)
      "setEnabled" -> {
        HdrMode.setEnabled(HdrImageLoader.context, call.arguments as? Boolean ?: true)
        result.success(null)
      }
      "show" -> {
        val host = host ?: return result.success(mapOf("hdr" to false))
        host.show(call.argument<Number>("token")!!.toLong(), source(call), result::success)
      }
      "preload" -> {
        if (host != null) HdrCache.preload(source(call))
        result.success(null)
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

/**
 * The native layer below Flutter: a black backdrop with one ImageView per page currently showing an HDR photo,
 * so neighbouring photos stay HDR while swiping. Each page is identified by a `show` token.
 */
private class HdrHost(private val activity: Activity) {
  private class Slot(val view: ImageView) {
    var bitmap: Bitmap? = null
    var rect: FloatArray? = null
    val matrix = Matrix()
  }

  private val container = FrameLayout(activity).apply {
    setBackgroundColor(Color.BLACK)
    visibility = View.GONE
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
  }
  private val content: ViewGroup? = activity.findViewById(android.R.id.content)
  private val slots = HashMap<Long, Slot>()

  init {
    content?.addView(container, 0, ViewGroup.LayoutParams(MATCH, MATCH))
  }

  fun show(token: Long, source: HdrCache.Source, onResult: (Map<String, Any?>) -> Unit) {
    hide(token)
    val slot = Slot(ImageView(activity).apply {
      scaleType = ImageView.ScaleType.MATRIX
      importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    })
    slots[token] = slot

    HdrCache.get(source) { result, cached ->
      if (slots[token] !== slot) return@get onResult(mapOf("hdr" to false))
      val bitmap = result.getOrElse {
        hide(token)
        return@get onResult(mapOf("hdr" to false, "error" to it.message))
      }
      if (bitmap == null) {
        hide(token)
        return@get onResult(mapOf("hdr" to false))
      }

      slot.bitmap = bitmap
      slot.view.setImageBitmap(bitmap)
      applyMatrix(slot)
      container.addView(slot.view, FrameLayout.LayoutParams(MATCH, MATCH))
      container.visibility = View.VISIBLE
      setWindowHdr(true)
      // Reply once the photo has been drawn, so Flutter never reveals an empty layer.
      container.postOnAnimation {
        container.post { if (slots[token] === slot) onResult(mapOf("hdr" to true, "cached" to cached)) }
      }
    }
  }

  fun update(token: Long, left: Float, top: Float, width: Float, height: Float) {
    val slot = slots[token] ?: return
    slot.rect = floatArrayOf(left, top, width, height)
    applyMatrix(slot)
  }

  fun hide(token: Long) {
    val slot = slots.remove(token) ?: return
    container.removeView(slot.view)
    slot.view.setImageDrawable(null)
    if (slots.isEmpty()) {
      container.visibility = View.GONE
      setWindowHdr(false)
    }
  }

  fun destroy() {
    slots.keys.toList().forEach(::hide)
    content?.removeView(container)
  }

  private fun applyMatrix(slot: Slot) {
    val bitmap = slot.bitmap ?: return
    val (left, top, width, height) = slot.rect ?: return
    // Flutter reports coordinates relative to the FlutterView, which shares the content root's origin.
    slot.matrix.setScale(width / bitmap.width, height / bitmap.height)
    slot.matrix.postTranslate(left, top)
    slot.view.imageMatrix = slot.matrix
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
  }
}
