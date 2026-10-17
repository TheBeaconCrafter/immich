package app.alextran.immich.hdr

import android.util.Log

/** libde265 (LGPL, `android/hdr-native`) for HEVC images Android's decoders reject, like monochrome tiles. */
internal object HdrNative {
  private val loaded: Boolean by lazy {
    try {
      System.loadLibrary("hdr_native")
      true
    } catch (e: Throwable) {
      Log.w("HdrNative", "Native decoder unavailable", e)
      false
    }
  }

  /** Luma plane of the HEVC image described by [hvcC] and its length-prefixed [data], cropped to the given size. */
  fun decodeLuma(hvcC: ByteArray, data: ByteArray, width: Int, height: Int): ByteArray? =
    if (loaded) nativeDecodeLuma(hvcC, data, width, height) else null

  @JvmStatic
  private external fun nativeDecodeLuma(hvcC: ByteArray, data: ByteArray, width: Int, height: Int): ByteArray?
}
