package app.alextran.immich.hdr

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.lang.ref.WeakReference

class HdrImagePlugin : FlutterPlugin, ActivityAware {
  companion object {
    const val VIEW_TYPE = "immich/hdr_image_view"
    const val CHANNEL = "immich/hdr_image"
  }

  private var channel: MethodChannel? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    HdrImageLoader.initialize(binding.applicationContext)
    binding.platformViewRegistry.registerViewFactory(
      VIEW_TYPE,
      HdrImageViewFactory(binding.binaryMessenger)
    )
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
      setMethodCallHandler { call, result ->
        when (call.method) {
          "isSupported" -> result.success(HdrWindow.isSupported())
          else -> result.notImplemented()
        }
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) = HdrWindow.attach(binding.activity)
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    HdrWindow.attach(binding.activity)

  override fun onDetachedFromActivityForConfigChanges() = HdrWindow.detach()
  override fun onDetachedFromActivity() = HdrWindow.detach()
}

/** Keeps the window in HDR color mode while at least one HDR view is shown. */
internal object HdrWindow {
  private var activity: WeakReference<Activity>? = null
  private var users = 0

  fun isSupported(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
    val display = activity?.get()?.display ?: return false
    return display.isHdrSdrRatioAvailable || display.isHdr
  }

  fun attach(activity: Activity) {
    this.activity = WeakReference(activity)
    apply()
  }

  fun detach() {
    activity = null
  }

  fun acquire() {
    users++
    apply()
  }

  fun release() {
    users = (users - 1).coerceAtLeast(0)
    apply()
  }

  private fun apply() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
    val window = activity?.get()?.window ?: return
    val mode = if (users > 0) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
    if (window.colorMode != mode) {
      window.colorMode = mode
    }
  }
}

private class HdrImageViewFactory(
  private val messenger: io.flutter.plugin.common.BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    @Suppress("UNCHECKED_CAST")
    val params = args as? Map<String, Any?> ?: emptyMap()
    return HdrImageView(context, viewId, params, messenger)
  }
}
