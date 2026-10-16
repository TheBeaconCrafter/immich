package app.alextran.immich.hdr

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.MediaStore
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
  private const val CACHE_SIZE_BYTES = 512L * 1024 * 1024

  private val executor = Executors.newFixedThreadPool(2)
  private lateinit var resolver: ContentResolver
  private lateinit var cache: Cache
  private var client: OkHttpClient? = null

  fun initialize(context: Context) {
    synchronized(this) {
      if (::resolver.isInitialized) return
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
    onResult: (Result<Bitmap>) -> Unit,
  ) {
    executor.execute {
      if (signal.isCanceled) return@execute onResult(Result.failure(OperationCanceledException()))
      onResult(runCatching {
        val source = when {
          localId != null -> ImageDecoder.createSource(
            resolver,
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, localId.toLong())
          )

          url != null -> ImageDecoder.createSource(ByteBuffer.wrap(fetch(url, signal)))
          else -> throw IllegalArgumentException("Either localId or url is required")
        }
        signal.throwIfCanceled()
        decode(source, maxSize)
      })
    }
  }

  private fun decode(source: ImageDecoder.Source, maxSize: Int): Bitmap =
    ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
      // Keeps the gain map and avoids holding large originals on the Java heap.
      decoder.allocator = ImageDecoder.ALLOCATOR_HARDWARE
      val longEdge = max(info.size.width, info.size.height)
      if (maxSize in 1 until longEdge) {
        val scale = maxSize.toDouble() / longEdge
        decoder.setTargetSize(
          (info.size.width * scale).roundToInt().coerceAtLeast(1),
          (info.size.height * scale).roundToInt().coerceAtLeast(1),
        )
      }
    }

  private fun fetch(url: String, signal: CancellationSignal): ByteArray {
    val call = httpClient().newCall(Request.Builder().url(url).build())
    signal.setOnCancelListener { call.cancel() }
    call.execute().use { response ->
      if (!response.isSuccessful) throw IOException("HTTP ${response.code} for original")
      val body = response.body ?: throw IOException("Empty response body")
      return body.bytes()
    }
  }

  private fun httpClient(): OkHttpClient = synchronized(this) {
    client ?: HttpClientManager.getClient().newBuilder()
      .cache(cache)
      .build()
      .also { client = it }
  }
}
