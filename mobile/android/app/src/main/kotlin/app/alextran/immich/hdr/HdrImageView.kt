package app.alextran.immich.hdr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

/** Creation params: `localId` (MediaStore id) or `url` (remote original), optional `maxSize`. */
internal class HdrImageView(
  context: Context,
  viewId: Int,
  params: Map<String, Any?>,
  messenger: BinaryMessenger,
) : PlatformView {
  private val imageView = ImageView(context).apply {
    scaleType = ImageView.ScaleType.FIT_CENTER
    setBackgroundColor(Color.TRANSPARENT)
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
  }
  private val channel = MethodChannel(messenger, "${HdrImagePlugin.VIEW_TYPE}_$viewId")
  private val mainHandler = Handler(Looper.getMainLooper())
  private val signal = CancellationSignal()
  private var disposed = false
  private var holdsHdrWindow = false
  private var lastResult: Map<String, Any?>? = null

  init {
    channel.setMethodCallHandler { call, result ->
      if (call.method == "getResult") result.success(lastResult) else result.notImplemented()
    }

    val localId = params["localId"] as? String
    val url = params["url"] as? String
    val maxSize = (params["maxSize"] as? Number)?.toInt() ?: HdrImageLoader.DEFAULT_MAX_SIZE

    HdrImageLoader.load(localId, url, maxSize, signal) { result ->
      mainHandler.post { onLoaded(result) }
    }
  }

  private fun onLoaded(result: Result<Bitmap>) {
    if (disposed) {
      result.getOrNull()?.recycle()
      return
    }

    val bitmap = result.getOrElse {
      Log.w(TAG, "Failed to load HDR image", it)
      return report(mapOf("hdr" to false, "error" to it.message))
    }

    if (!isHdr(bitmap)) {
      bitmap.recycle()
      return report(mapOf("hdr" to false))
    }

    imageView.setImageBitmap(bitmap)
    HdrWindow.acquire()
    holdsHdrWindow = true
    report(mapOf("hdr" to true))
  }

  private fun report(result: Map<String, Any?>) {
    lastResult = result
    channel.invokeMethod("onResult", result)
  }

  override fun getView(): View = imageView

  override fun dispose() {
    disposed = true
    signal.cancel()
    channel.setMethodCallHandler(null)
    if (holdsHdrWindow) {
      holdsHdrWindow = false
      HdrWindow.release()
    }
    imageView.setImageDrawable(null)
  }

  private companion object {
    const val TAG = "HdrImageView"

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
