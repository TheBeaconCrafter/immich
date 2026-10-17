package app.alextran.immich.hdr

import android.graphics.Bitmap
import android.graphics.Gainmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Android decodes HEIC base images but ignores their HDR gain maps. iPhones (iOS 18+) store an ISO 21496-1
 * gain map as a `tmap` derived item referencing the base image and a gain map image item. This reads that
 * metadata, decodes the gain map item (by pointing the file's primary item at it) and attaches it as a [Gainmap].
 *
 * Photos taken before iOS 18 (e.g. on an iPhone 13 or 15 Pro) only carry Apple's own HDR gain map: an auxiliary
 * `urn:com:apple:photo:2020:aux:hdrgainmap` image, with the headroom derived from two Apple maker note values.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
internal object HeifGainmap {
  private const val TAG = "HeifGainmap"

  fun attach(bytes: ByteArray, base: Bitmap): Boolean {
    val heif = try {
      Heif.parse(bytes)
    } catch (e: Exception) {
      Log.w(TAG, "Failed to parse HEIF", e)
      return false
    } ?: return false

    val tmap = heif.items.values.firstOrNull { it.type == "tmap" } ?: return attachApple(bytes, heif, base)
    val refs = heif.dimg[tmap.id]
    if (refs == null || refs.size < 2) {
      Log.w(TAG, "tmap item ${tmap.id} has no gain map reference: $refs")
      return false
    }
    val gainmapItem = refs[1]
    val metadata = IsoGainmapMetadata.parse(heif.itemData(tmap.id) ?: return false) ?: run {
      Log.w(TAG, "Unsupported tmap metadata")
      return false
    }

    Log.i(TAG, "Gain map item $gainmapItem: ${heif.describe(gainmapItem)}")
    // iPhone gain maps are monochrome HEVC (Range Extensions), which Android's decoders reject.
    val oriented = decodeMonochrome(heif, gainmapItem)
      ?: decodeItem(bytes, heif, gainmapItem)?.let { orient(it, heif.rotation(gainmapItem), heif.rotation(heif.primaryId)) }
      ?: return false
    base.gainmap = metadata.toGainmap(oriented)
    Log.i(
      TAG,
      "Attached gain map item $gainmapItem ${oriented.width}x${oriented.height} to ${base.width}x${base.height}: $metadata"
    )
    return true
  }

  /** Attaches Apple's pre-iOS 18 HDR gain map, if the file has one. */
  private fun attachApple(bytes: ByteArray, heif: Heif, base: Bitmap): Boolean {
    val item = heif.items.keys.firstOrNull { heif.auxType(it)?.contains("hdrgainmap") == true } ?: run {
      Log.i(TAG, "No tmap item or Apple HDR gain map")
      return false
    }
    val exif = heif.items.values.firstOrNull { it.type == "Exif" }?.let { heif.itemData(it.id) }
    val headroom = exif?.let(AppleHdr::headroom) ?: run {
      Log.w(TAG, "Apple HDR gain map $item without maker note headroom")
      return false
    }
    if (headroom <= 1.0) return false
    Log.i(TAG, "Apple gain map item $item: ${heif.describe(item)}, headroom $headroom")
    // The auxiliary image has no rotation of its own; it follows the primary image.
    val turns = heif.rotation(item).takeIf { it != 0 } ?: heif.rotation(heif.primaryId)
    val contents = decodeMonochrome(heif, item, turns, AppleHdr.lut(headroom))
      ?: decodeItem(bytes, heif, item)?.let { orient(it, 0, turns) }?.let { AppleHdr.remap(it, headroom) }
      ?: return false
    base.gainmap = AppleHdr.gainmap(contents, headroom)
    Log.i(TAG, "Attached Apple gain map ${contents.width}x${contents.height} to ${base.width}x${base.height}")
    return true
  }

  /**
   * Decodes a monochrome `hvc1` item or `grid` of them with libde265, rotated by [turns] (default: the item's own
   * rotation) and with each value mapped through [lut] if given.
   */
  private fun decodeMonochrome(
    heif: Heif,
    itemId: Int,
    turns: Int = heif.rotation(itemId),
    lut: ByteArray? = null,
  ): Bitmap? {
    val start = System.nanoTime()
    val (width, height, tiles, columns) = when (heif.items[itemId]?.type) {
      "hvc1" -> heif.size(itemId)?.let { (w, h) -> Grid(w, h, listOf(itemId), 1) }
      "grid" -> heif.grid(itemId)
      else -> null
    } ?: return null

    val luma = ByteArray(width * height)
    for ((index, tile) in tiles.withIndex()) {
      val hvcC = heif.property(tile, "hvcC") ?: return null
      val (tileWidth, tileHeight) = heif.size(tile) ?: return null
      val data = heif.itemData(tile) ?: return null
      val pixels = HdrNative.decodeLuma(hvcC, data, tileWidth, tileHeight) ?: run {
        Log.w(TAG, "Native decode failed for tile $tile")
        return null
      }
      val left = index % columns * tileWidth
      val top = index / columns * tileHeight
      for (y in 0 until tileHeight) {
        val dy = top + y
        if (dy >= height) break
        val count = minOf(tileWidth, width - left)
        if (count > 0) System.arraycopy(pixels, y * tileWidth, luma, dy * width + left, count)
      }
    }

    if (lut != null) for (i in luma.indices) luma[i] = lut[luma[i].toInt() and 0xFF]
    val (rotated, w, h) = rotate(luma, width, height, turns)
    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ALPHA_8)
    val packed = if (bitmap.rowBytes == w) rotated else ByteArray(bitmap.rowBytes * h).also { out ->
      for (y in 0 until h) System.arraycopy(rotated, y * w, out, y * bitmap.rowBytes, w)
    }
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(packed))
    Log.i(TAG, "Decoded ${tiles.size} monochrome tiles to ${w}x$h in ${(System.nanoTime() - start) / 1_000_000} ms")
    return bitmap
  }

  /** Rotates a single channel image by anti-clockwise quarter [turns]. */
  private fun rotate(src: ByteArray, width: Int, height: Int, turns: Int): Triple<ByteArray, Int, Int> {
    if (turns == 0) return Triple(src, width, height)
    val swap = turns % 2 == 1
    val w = if (swap) height else width
    val h = if (swap) width else height
    val dst = ByteArray(src.size)
    for (y in 0 until height) {
      for (x in 0 until width) {
        val (nx, ny) = when (turns) {
          1 -> y to width - 1 - x
          2 -> width - 1 - x to height - 1 - y
          else -> height - 1 - y to x
        }
        dst[ny * w + nx] = src[y * width + x]
      }
    }
    return Triple(dst, w, h)
  }

  /** Decodes [itemId] by making it the primary item of a copy of the file. */
  private fun decodeItem(bytes: ByteArray, heif: Heif, itemId: Int): Bitmap? {
    val patched = bytes.copyOf()
    if (!heif.setPrimary(patched, itemId)) {
      Log.w(TAG, "Cannot point primary item at $itemId")
      return null
    }
    heif.clearHidden(patched, itemId)
    return try {
      ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(patched))) { decoder, _, _ ->
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      }
    } catch (e: Exception) {
      Log.w(TAG, "Failed to decode gain map item $itemId", e)
      null
    }
  }

  /** ImageDecoder applied [own] rotation to the gain map; it needs [target], the base image's rotation. */
  private fun orient(bitmap: Bitmap, own: Int, target: Int): Bitmap {
    val degrees = ((target - own) % 4 + 4) % 4 * 90
    if (degrees == 0) return bitmap
    // irot angles are anti-clockwise, Matrix rotations clockwise.
    val matrix = Matrix().apply { setRotate(-degrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
  }
}

/**
 * Apple's pre-iOS 18 HDR gain maps, as documented by Apple ("Applying Apple HDR effect to your photos"): the HDR
 * rendition is `sdr * (1 + (headroom - 1) * g)`, with `g` the sRGB-decoded gain map value and the headroom derived
 * from maker note tags 33 and 48. Android's [Gainmap] interpolates gains logarithmically, so the values are remapped
 * to `log(1 + (headroom - 1) * g) / log(headroom)` to give exactly the same result.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
internal object AppleHdr {
  fun lut(headroom: Double): ByteArray = ByteArray(256) { i ->
    val v = i / 255.0
    val linear = if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
    val encoded = ln(1 + (headroom - 1) * linear) / ln(headroom)
    (encoded * 255).roundToInt().coerceIn(0, 255).toByte()
  }

  /** Remaps a gain map decoded by ImageDecoder into a single channel bitmap. */
  fun remap(bitmap: Bitmap, headroom: Double): Bitmap {
    val lut = lut(headroom)
    val pixels = IntArray(bitmap.width * bitmap.height)
    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    val out = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ALPHA_8)
    val row = out.rowBytes
    val data = ByteArray(row * bitmap.height)
    for (y in 0 until bitmap.height) {
      for (x in 0 until bitmap.width) data[y * row + x] = lut[pixels[y * bitmap.width + x] shr 8 and 0xFF]
    }
    out.copyPixelsFromBuffer(ByteBuffer.wrap(data))
    return out
  }

  fun gainmap(contents: Bitmap, headroom: Double): Gainmap = Gainmap(contents).apply {
    val max = headroom.toFloat()
    setRatioMin(1f, 1f, 1f)
    setRatioMax(max, max, max)
    setGamma(1f, 1f, 1f)
    setEpsilonSdr(0f, 0f, 0f)
    setEpsilonHdr(0f, 0f, 0f)
    minDisplayRatioForHdrTransition = 1f
    displayRatioForFullHdr = max
  }

  /** The headroom from the Apple maker note in a HEIF `Exif` item, or null if it has no HDR values. */
  fun headroom(exif: ByteArray): Double? {
    if (exif.size < 8) return null
    val tiff = 4 + ByteBuffer.wrap(exif).int
    val makerNote = Tiff.find(exif, tiff, 0x927C) ?: return null
    val (start, length) = makerNote
    val header = "Apple iOS\u0000"
    if (length < 16 || String(exif, start, header.length, Charsets.ISO_8859_1) != header) return null
    val order = if (String(exif, start + 12, 2, Charsets.ISO_8859_1) == "II") {
      java.nio.ByteOrder.LITTLE_ENDIAN
    } else {
      java.nio.ByteOrder.BIG_ENDIAN
    }
    val tags = Tiff.entries(exif, start + 14, start, order)
    val maker33 = tags[33] ?: return null
    val maker48 = tags[48] ?: return null
    val stops = if (maker33 < 1.0) {
      if (maker48 <= 0.01) -20.0 * maker48 + 1.8 else -0.101 * maker48 + 1.601
    } else {
      if (maker48 <= 0.01) -70.0 * maker48 + 3.0 else -0.303 * maker48 + 2.303
    }
    return 2.0.pow(max(stops, 0.0))
  }
}

/** Minimal TIFF/EXIF reading for [AppleHdr]. */
private object Tiff {
  /** Offset and length of the value of [tag] in IFD0 or the EXIF IFD of the TIFF structure at [tiff]. */
  fun find(data: ByteArray, tiff: Int, tag: Int): Pair<Int, Int>? {
    if (tiff + 8 > data.size) return null
    val order = if (data[tiff] == 'I'.code.toByte()) java.nio.ByteOrder.LITTLE_ENDIAN else java.nio.ByteOrder.BIG_ENDIAN
    val b = ByteBuffer.wrap(data).order(order)
    var ifd = tiff + b.getInt(tiff + 4)
    repeat(2) {
      var exifIfd = -1
      if (ifd < 0 || ifd + 2 > data.size) return null
      val count = b.getShort(ifd).toInt() and 0xFFFF
      for (i in 0 until count) {
        val entry = ifd + 2 + i * 12
        if (entry + 12 > data.size) return null
        val entryTag = b.getShort(entry).toInt() and 0xFFFF
        val length = b.getInt(entry + 4)
        val value = b.getInt(entry + 8)
        if (entryTag == tag) return (if (length > 4) tiff + value else entry + 8) to length
        if (entryTag == 0x8769) exifIfd = tiff + value
      }
      if (exifIfd < 0) return null
      ifd = exifIfd
    }
    return null
  }

  /** Numeric values of the entries of the IFD at [ifd], with offsets relative to [base]. */
  fun entries(data: ByteArray, ifd: Int, base: Int, order: java.nio.ByteOrder): Map<Int, Double> {
    val b = ByteBuffer.wrap(data).order(order)
    if (ifd + 2 > data.size) return emptyMap()
    val result = mutableMapOf<Int, Double>()
    val count = b.getShort(ifd).toInt() and 0xFFFF
    for (i in 0 until count) {
      val entry = ifd + 2 + i * 12
      if (entry + 12 > data.size) break
      val tag = b.getShort(entry).toInt() and 0xFFFF
      val type = b.getShort(entry + 2).toInt() and 0xFFFF
      val pointer = base + b.getInt(entry + 8)
      fun rational(signed: Boolean): Double? {
        if (pointer < 0 || pointer + 8 > data.size) return null
        val n = b.getInt(pointer)
        val d = b.getInt(pointer + 4)
        val num = if (signed) n.toDouble() else n.toUInt().toDouble()
        val den = if (signed) d.toDouble() else d.toUInt().toDouble()
        return if (den == 0.0) null else num / den
      }
      val value = when (type) {
        3 -> (b.getShort(entry + 8).toInt() and 0xFFFF).toDouble()
        4 -> b.getInt(entry + 8).toUInt().toDouble()
        8 -> b.getShort(entry + 8).toDouble()
        9 -> b.getInt(entry + 8).toDouble()
        11 -> b.getFloat(entry + 8).toDouble()
        5 -> rational(false)
        10 -> rational(true)
        else -> null
      }
      if (value != null) result[tag] = value
    }
    return result
  }
}

/** ISO 21496-1 gain map metadata as stored in a HEIF `tmap` item. */
internal class IsoGainmapMetadata(
  private val baseHeadroom: Double,
  private val alternateHeadroom: Double,
  private val gainMin: DoubleArray,
  private val gainMax: DoubleArray,
  private val gainGamma: DoubleArray,
  private val baseOffset: DoubleArray,
  private val alternateOffset: DoubleArray,
) {
  @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
  fun toGainmap(contents: Bitmap): Gainmap = Gainmap(contents).apply {
    fun ch(values: DoubleArray, i: Int) = values[if (values.size == 3) i else 0]
    fun rgb(values: DoubleArray, transform: (Double) -> Double) =
      Triple(transform(ch(values, 0)).toFloat(), transform(ch(values, 1)).toFloat(), transform(ch(values, 2)).toFloat())

    rgb(gainMin) { 2.0.pow(it) }.let { (r, g, b) -> setRatioMin(r, g, b) }
    rgb(gainMax) { 2.0.pow(it) }.let { (r, g, b) -> setRatioMax(r, g, b) }
    rgb(gainGamma) { it }.let { (r, g, b) -> setGamma(r, g, b) }
    rgb(baseOffset) { it }.let { (r, g, b) -> setEpsilonSdr(r, g, b) }
    rgb(alternateOffset) { it }.let { (r, g, b) -> setEpsilonHdr(r, g, b) }
    minDisplayRatioForHdrTransition = 2.0.pow(baseHeadroom).toFloat()
    displayRatioForFullHdr = 2.0.pow(alternateHeadroom).toFloat()
  }

  override fun toString() =
    "headroom=$baseHeadroom->$alternateHeadroom min=${gainMin.toList()} max=${gainMax.toList()} gamma=${gainGamma.toList()} " +
      "offsets=${baseOffset.toList()}/${alternateOffset.toList()}"

  companion object {
    /**
     * Layout: version u8, minimum_version u16, writer_version u16, flags u8, then the headrooms and per-channel
     * values, either as fractions with a common denominator or as numerator/denominator pairs. Which variant and
     * how many channels follows unambiguously from the payload length.
     */
    fun parse(data: ByteArray): IsoGainmapMetadata? {
      val b = ByteBuffer.wrap(data)
      if (data.size < 6 || b.get().toInt() != 0) return null
      b.short; b.short; b.get()
      val (channels, common) = when (data.size - 6) {
        4 + 8 + 20 -> 1 to true
        4 + 8 + 60 -> 3 to true
        16 + 40 -> 1 to false
        16 + 120 -> 3 to false
        else -> return null
      }
      val denominator = if (common) b.int.toUInt().toDouble() else 0.0
      fun unsigned(): Double {
        val n = b.int.toUInt().toDouble()
        val d = if (common) denominator else b.int.toUInt().toDouble()
        return if (d == 0.0) 0.0 else n / d
      }
      fun signed(): Double {
        val n = b.int.toDouble()
        val d = if (common) denominator else b.int.toUInt().toDouble()
        return if (d == 0.0) 0.0 else n / d
      }

      val baseHeadroom = unsigned()
      val alternateHeadroom = unsigned()
      val min = DoubleArray(channels)
      val max = DoubleArray(channels)
      val gamma = DoubleArray(channels)
      val baseOffset = DoubleArray(channels)
      val alternateOffset = DoubleArray(channels)
      for (c in 0 until channels) {
        min[c] = signed()
        max[c] = signed()
        gamma[c] = unsigned()
        baseOffset[c] = signed()
        alternateOffset[c] = signed()
      }
      return IsoGainmapMetadata(baseHeadroom, alternateHeadroom, min, max, gamma, baseOffset, alternateOffset)
    }
  }
}

private data class Grid(val width: Int, val height: Int, val tiles: List<Int>, val columns: Int)

/** Just enough of an ISO BMFF / HEIF `meta` box reader to locate items, their data and properties. */
private class Heif(
  private val bytes: ByteArray,
  val primaryId: Int,
  private val pitmIdOffset: Int,
  private val pitmIdSize: Int,
  val items: Map<Int, Item>,
  val dimg: Map<Int, List<Int>>,
  private val locations: Map<Int, Location>,
  private val idatOffset: Int,
  private val properties: List<Pair<String, IntRange>>,
  private val associations: Map<Int, List<Int>>,
) {
  class Item(val id: Int, val type: String, val flagsOffset: Int)

  fun property(id: Int, type: String): ByteArray? {
    for (index in associations[id].orEmpty()) {
      val (propertyType, range) = properties.getOrNull(index - 1) ?: continue
      if (propertyType == type) return bytes.copyOfRange(range.first, range.last + 1)
    }
    return null
  }

  /** The `auxC` type URN of an auxiliary image item, e.g. Apple's HDR gain map. */
  fun auxType(id: Int): String? {
    val auxC = property(id, "auxC") ?: return null
    if (auxC.size <= 4) return null
    val end = (4 until auxC.size).firstOrNull { auxC[it] == 0.toByte() } ?: auxC.size
    return String(auxC, 4, end - 4, Charsets.ISO_8859_1)
  }

  fun size(id: Int): Pair<Int, Int>? {
    val ispe = property(id, "ispe") ?: return null
    val b = ByteBuffer.wrap(ispe)
    b.int
    return b.int to b.int
  }

  /** ImageGrid: version, flags, rows - 1, columns - 1, output width and height (16 or 32 bit). */
  fun grid(id: Int): Grid? {
    val data = itemData(id) ?: return null
    val b = ByteBuffer.wrap(data)
    b.get()
    val large = b.get().toInt() and 1 == 1
    val rows = (b.get().toInt() and 0xFF) + 1
    val columns = (b.get().toInt() and 0xFF) + 1
    val width = if (large) b.int else b.short.toInt() and 0xFFFF
    val height = if (large) b.int else b.short.toInt() and 0xFFFF
    val tiles = dimg[id] ?: return null
    if (tiles.size != rows * columns) return null
    return Grid(width, height, tiles, columns)
  }
  class Location(val constructionMethod: Int, val extents: List<Pair<Long, Long>>)

  fun itemData(id: Int): ByteArray? {
    val location = locations[id] ?: return null
    val out = java.io.ByteArrayOutputStream()
    for ((offset, length) in location.extents) {
      val start = (if (location.constructionMethod == 1) idatOffset + offset else offset).toInt()
      if (start < 0 || start + length > bytes.size) return null
      out.write(bytes, start, length.toInt())
    }
    return out.toByteArray()
  }

  fun setPrimary(target: ByteArray, id: Int): Boolean {
    if (pitmIdSize == 2 && id > 0xFFFF) return false
    val b = ByteBuffer.wrap(target)
    if (pitmIdSize == 2) b.putShort(pitmIdOffset, id.toShort()) else b.putInt(pitmIdOffset, id)
    return true
  }

  /** Clears the infe "hidden" flag, which gain map items usually carry. */
  fun clearHidden(target: ByteArray, id: Int) {
    val offset = items[id]?.flagsOffset ?: return
    target[offset + 3] = (target[offset + 3].toInt() and 0xFE).toByte()
  }

  /** Item type and its key properties, e.g. HEVC profile and chroma format, for diagnostics. */
  fun describe(id: Int): String {
    val parts = mutableListOf("type=${items[id]?.type}")
    for (index in associations[id].orEmpty()) {
      val (type, range) = properties.getOrNull(index - 1) ?: continue
      val b = ByteBuffer.wrap(bytes, range.first, range.last - range.first + 1)
      when (type) {
        "ispe" -> { b.int; parts += "ispe=${b.int}x${b.int}" }
        "hvcC" -> {
          b.get()
          val profile = b.get().toInt() and 0x1F
          b.position(b.position() + 14)
          val chroma = b.get().toInt() and 0x03
          val luma = (b.get().toInt() and 0x07) + 8
          parts += "hvcC(profile=$profile chroma=$chroma bitDepth=$luma)"
        }
        "pixi" -> { b.int; parts += "pixi(channels=${b.get()})" }
        else -> parts += type
      }
    }
    dimg[id]?.let { tiles -> parts += "tiles=${tiles.size} first=${tiles.firstOrNull()?.let { describe(it) }}" }
    return parts.joinToString(" ")
  }

  /** Anti-clockwise quarter turns from the item's `irot` property. */
  fun rotation(id: Int): Int {
    for (index in associations[id].orEmpty()) {
      val (type, range) = properties.getOrNull(index - 1) ?: continue
      if (type == "irot") return bytes[range.first].toInt() and 0x03
    }
    return 0
  }

  companion object {
    fun parse(bytes: ByteArray): Heif? {
      val meta = boxes(bytes, 0, bytes.size).firstOrNull { it.type == "meta" } ?: return null
      val children = boxes(bytes, meta.payload + 4, meta.end)

      var primaryId = -1
      var pitmIdOffset = -1
      var pitmIdSize = 2
      val items = mutableMapOf<Int, Item>()
      val dimg = mutableMapOf<Int, List<Int>>()
      val locations = mutableMapOf<Int, Location>()
      var idatOffset = 0
      val properties = mutableListOf<Pair<String, IntRange>>()
      val associations = mutableMapOf<Int, List<Int>>()

      for (box in children) {
        val b = ByteBuffer.wrap(bytes, box.payload, box.end - box.payload)
        when (box.type) {
          "pitm" -> {
            val version = b.get().toInt(); b.position(b.position() + 3)
            pitmIdOffset = b.position()
            pitmIdSize = if (version == 0) 2 else 4
            primaryId = if (version == 0) b.short.toInt() and 0xFFFF else b.int
          }

          "iinf" -> {
            val version = b.get().toInt(); b.position(b.position() + 3)
            if (version == 0) b.short else b.int
            for (infe in boxes(bytes, b.position(), box.end)) {
              if (infe.type != "infe") continue
              val e = ByteBuffer.wrap(bytes, infe.payload, infe.end - infe.payload)
              val infeVersion = e.get().toInt(); e.position(e.position() + 3)
              if (infeVersion < 2) continue
              val id = if (infeVersion == 2) e.short.toInt() and 0xFFFF else e.int
              e.short
              val type = String(bytes, e.position(), 4, Charsets.ISO_8859_1)
              items[id] = Item(id, type, infe.payload)
            }
          }

          "iloc" -> {
            val version = b.get().toInt(); b.position(b.position() + 3)
            val sizes = b.short.toInt()
            val offsetSize = sizes shr 12 and 0xF
            val lengthSize = sizes shr 8 and 0xF
            val baseOffsetSize = sizes shr 4 and 0xF
            val indexSize = if (version >= 1) sizes and 0xF else 0
            val count = if (version < 2) b.short.toInt() and 0xFFFF else b.int
            repeat(count) {
              val id = if (version < 2) b.short.toInt() and 0xFFFF else b.int
              val method = if (version >= 1) b.short.toInt() and 0xF else 0
              b.short
              val baseOffset = read(b, baseOffsetSize)
              val extents = (0 until (b.short.toInt() and 0xFFFF)).map {
                read(b, indexSize)
                (baseOffset + read(b, offsetSize)) to read(b, lengthSize)
              }
              locations[id] = Location(method, extents)
            }
          }

          "iref" -> {
            val version = b.get().toInt(); b.position(b.position() + 3)
            for (ref in boxes(bytes, b.position(), box.end)) {
              val r = ByteBuffer.wrap(bytes, ref.payload, ref.end - ref.payload)
              fun id() = if (version == 0) r.short.toInt() and 0xFFFF else r.int
              val from = id()
              val to = (0 until (r.short.toInt() and 0xFFFF)).map { id() }
              if (ref.type == "dimg") dimg[from] = to
            }
          }

          "idat" -> idatOffset = box.payload

          "iprp" -> for (child in boxes(bytes, box.payload, box.end)) {
            when (child.type) {
              "ipco" -> boxes(bytes, child.payload, child.end).forEach {
                // Payload of full boxes like irot starts right away; irot is a plain box with one byte.
                properties += it.type to (it.payload until it.end)
              }

              "ipma" -> {
                val p = ByteBuffer.wrap(bytes, child.payload, child.end - child.payload)
                val version = p.get().toInt()
                val flags = (p.get().toInt() and 0xFF shl 16) or (p.short.toInt() and 0xFFFF)
                repeat(p.int) {
                  val id = if (version < 1) p.short.toInt() and 0xFFFF else p.int
                  associations[id] = (0 until (p.get().toInt() and 0xFF)).map {
                    if (flags and 1 == 1) p.short.toInt() and 0x7FFF else p.get().toInt() and 0x7F
                  }
                }
              }
            }
          }
        }
      }

      if (primaryId < 0) return null
      return Heif(
        bytes, primaryId, pitmIdOffset, pitmIdSize, items, dimg, locations, idatOffset, properties, associations
      )
    }

    private class Box(val type: String, val payload: Int, val end: Int)

    private fun boxes(bytes: ByteArray, start: Int, end: Int): List<Box> {
      val result = mutableListOf<Box>()
      var pos = start
      while (pos + 8 <= end) {
        val b = ByteBuffer.wrap(bytes, pos, end - pos)
        var size = b.int.toLong() and 0xFFFFFFFFL
        val type = String(bytes, pos + 4, 4, Charsets.ISO_8859_1)
        var header = 8
        if (size == 1L) {
          size = b.getLong(pos + 8)
          header = 16
        } else if (size == 0L) {
          size = (end - pos).toLong()
        }
        if (size < header || pos + size > end) break
        result += Box(type, pos + header, (pos + size).toInt())
        pos += size.toInt()
      }
      return result
    }

    private fun read(b: ByteBuffer, size: Int): Long = when (size) {
      0 -> 0
      4 -> b.int.toLong() and 0xFFFFFFFFL
      8 -> b.long
      else -> throw IllegalArgumentException("Unsupported field size $size")
    }
  }
}
