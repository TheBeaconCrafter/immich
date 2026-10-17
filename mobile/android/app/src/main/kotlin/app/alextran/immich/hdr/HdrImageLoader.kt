package app.alextran.immich.hdr

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.MediaStore
import android.util.Log
import app.alextran.immich.core.HttpClientManager
import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

internal object HdrImageLoader {
  const val DEFAULT_MAX_SIZE = 4096
  private const val TAG = "HdrImageLoader"
  private val MARKERS = mapOf(
    "ultrahdr-xmp" to "http://ns.adobe.com/hdr-gain-map/1.0/",
    "iso21496" to "urn:iso:std:iso:ts:21496",
    "apple-gainmap" to "urn:com:apple:photo:2020:aux:hdrgainmap",
    "apple-hdr-xmp" to "http://ns.apple.com/HDRGainMap/1.0/",
    "heif-tmap" to "tmap",
    "mpf" to "MPF\u0000",
  )
  private const val CACHE_SIZE_BYTES = 512L * 1024 * 1024

  private val executor = Executors.newFixedThreadPool(2)
  // Preloads queue separately so they never delay the photo on screen.
  private val backgroundExecutor = Executors.newSingleThreadExecutor { Thread(it).apply { priority = Thread.MIN_PRIORITY } }
  lateinit var context: Context
    private set
  private lateinit var resolver: ContentResolver
  private lateinit var cache: Cache
  private var client: OkHttpClient? = null

  fun initialize(context: Context) {
    synchronized(this) {
      if (::resolver.isInitialized) return
      this.context = context
      resolver = context.contentResolver
      cache = Cache(File(File(context.cacheDir, "okhttp"), "hdr_originals"), CACHE_SIZE_BYTES)
      HttpClientManager.addClientChangedListener { synchronized(this) { client = null } }
    }
  }

  fun load(
    localId: String?,
    url: String?,
    maxSize: Int,
    signal: CancellationSignal,
    background: Boolean,
    onResult: (Result<Bitmap>) -> Unit,
  ) {
    (if (background) backgroundExecutor else executor).execute {
      if (signal.isCanceled) return@execute onResult(Result.failure(OperationCanceledException()))
      onResult(runCatching {
        val (bytes, contentType) = when {
          localId != null -> {
            val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, localId.toLong())
            val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: throw IOException("Cannot open $uri")
            bytes to resolver.getType(uri)
          }

          url != null -> fetch(url, signal)
          else -> throw IllegalArgumentException("Either localId or url is required")
        }
        Log.i(TAG, "Source ${if (localId != null) "local" else "remote"}: ${describe(bytes, contentType)}")
        signal.throwIfCanceled()
        val heif = isHeif(bytes)
        val bitmap = decode(ImageDecoder.createSource(ByteBuffer.wrap(bytes)), maxSize, mutable = heif)
        if (heif && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && !bitmap.hasGainmap()) {
          HeifGainmap.attach(bytes, bitmap)
        }
        bitmap
      })
    }
  }

  private fun isHeif(bytes: ByteArray) =
    bytes.size > 12 && String(bytes, 4, 4, Charsets.ISO_8859_1) == "ftyp" &&
      String(bytes, 8, 4, Charsets.ISO_8859_1) in setOf("heic", "heix", "mif1", "msf1", "heim", "heis")

  /** [mutable] HEIC decodes stay in software memory so a gain map read by [HeifGainmap] can be attached. */
  private fun decode(source: ImageDecoder.Source, maxSize: Int, mutable: Boolean): Bitmap =
    ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
      if (mutable) {
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        decoder.isMutableRequired = true
      } else {
        // Keeps the gain map and avoids holding large originals on the Java heap.
        decoder.allocator = ImageDecoder.ALLOCATOR_HARDWARE
      }
      val longEdge = max(info.size.width, info.size.height)
      if (maxSize in 1 until longEdge) {
        val scale = maxSize.toDouble() / longEdge
        decoder.setTargetSize(
          (info.size.width * scale).roundToInt().coerceAtLeast(1),
          (info.size.height * scale).roundToInt().coerceAtLeast(1),
        )
      }
    }

  /** Container type and the gain map flavours whose markers appear in the file. */
  private fun describe(bytes: ByteArray, contentType: String?): String {
    val head = String(bytes, 0, minOf(bytes.size, 32), Charsets.ISO_8859_1)
    val container = when {
      bytes.size > 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() -> "jpeg"
      head.length >= 12 && head.substring(4, 8) == "ftyp" -> "isobmff:${head.substring(8, 12)}"
      else -> "unknown"
    }
    // Gain map signalling lives in the header (XMP, MPF, HEIF meta box), so the first part of the file suffices.
    val text = String(bytes, 0, minOf(bytes.size, 256 * 1024), Charsets.ISO_8859_1)
    val markers = MARKERS.filter { (_, needle) -> text.contains(needle) }.keys
    return "type=$contentType container=$container size=${bytes.size} markers=$markers"
  }

  private fun fetch(url: String, signal: CancellationSignal): Pair<ByteArray, String?> {
    val call = httpClient().newCall(Request.Builder().url(url).build())
    signal.setOnCancelListener { call.cancel() }
    call.execute().use { response ->
      if (!response.isSuccessful) throw IOException("HTTP ${response.code} for original")
      val body = response.body ?: throw IOException("Empty response body")
      return body.bytes() to response.header("Content-Type")
    }
  }

  private fun httpClient(): OkHttpClient = synchronized(this) {
    client ?: HttpClientManager.getClient().newBuilder()
      .cache(cache)
      .build()
      .also { client = it }
  }
}
