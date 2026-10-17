package app.alextran.immich.hdr

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Decoded HDR renditions by source, so neighbours can be preloaded and revisited photos show instantly.
 * SDR results are remembered as `null`. All callbacks run on the main thread.
 */
internal object HdrCache {
  private const val TAG = "HdrCache"

  class Source(val localId: String?, val url: String?, val maxSize: Int) {
    val key = localId?.let { "local:$it" } ?: "remote:$url"
  }

  private class Entry(val bitmap: Bitmap?, val bytes: Long)

  private val mainHandler = Handler(Looper.getMainLooper())
  private val entries = LinkedHashMap<String, Entry>(16, 0.75f, true)
  private val pending = HashMap<String, MutableList<(Result<Bitmap?>) -> Unit>>()
  private var budget = 256L * 1024 * 1024
  private var used = 0L

  fun initialize(context: Context) {
    val memory = ActivityManager.MemoryInfo()
    (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
    budget = minOf(512L * 1024 * 1024, memory.totalMem / 10)
  }

  /**
   * Calls [onResult] with the HDR rendition, `null` for SDR photos, or a failure, and whether it was already
   * cached (synchronously) rather than loaded.
   */
  fun get(source: Source, onResult: (Result<Bitmap?>, cached: Boolean) -> Unit) {
    entries[source.key]?.let { return onResult(Result.success(it.bitmap), true) }
    load(source, background = false) { onResult(it, false) }
  }

  fun preload(source: Source) {
    if (entries.containsKey(source.key) || pending.containsKey(source.key)) return
    load(source, background = true) {}
  }

  private fun load(source: Source, background: Boolean, onResult: (Result<Bitmap?>) -> Unit) {
    pending[source.key]?.let { it += onResult; return }
    pending[source.key] = mutableListOf(onResult)

    HdrImageLoader.load(source.localId, source.url, source.maxSize, CancellationSignal(), background) { result ->
      val hdr = result.map { bitmap -> if (isHdr(bitmap)) bitmap else null.also { bitmap.recycle() } }
      mainHandler.post {
        hdr.onSuccess {
          put(source.key, it)
          Log.i(TAG, "${if (background) "Preloaded" else "Loaded"} hdr=${it != null}, cached ${entries.size} (${used / 1048576} MB)")
        }
          .onFailure { Log.w(TAG, "Failed to load ${source.key}", it) }
        pending.remove(source.key)?.forEach { it(hdr) }
      }
    }
  }

  private fun put(key: String, bitmap: Bitmap?) {
    val bytes = bitmap?.let { b ->
      b.allocationByteCount.toLong() +
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) b.gainmap?.gainmapContents?.allocationByteCount ?: 0 else 0)
    } ?: 0L
    entries.put(key, Entry(bitmap, bytes))?.let { used -= it.bytes }
    used += bytes
    // Evicted bitmaps may still be on screen, so they are left to the garbage collector instead of recycled.
    val iterator = entries.entries.iterator()
    while (used > budget && iterator.hasNext()) {
      val eldest = iterator.next()
      if (eldest.key == key) continue
      used -= eldest.value.bytes
      iterator.remove()
    }
  }

  private fun isHdr(bitmap: Bitmap): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
    if (bitmap.hasGainmap()) return true
    // HLG / PQ stills without a gain map, e.g. HDR AVIF.
    val colorSpace = bitmap.colorSpace ?: return false
    return colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_HLG) ||
      colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_PQ)
  }
}
