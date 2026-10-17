// Decodes one monochrome (4:0:0) HEVC image, as used by iPhone HEIC gain map tiles, to its luma plane.
#include <algorithm>
#include <cstring>
#include <vector>

#include "libde265/de265.h"

#ifdef HDR_NATIVE_NO_JNI
#include <cstdio>
#define LOG_WARN(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#else
#include <jni.h>
#include <android/log.h>
#define LOG_WARN(...) __android_log_print(ANDROID_LOG_WARN, "HdrNative", __VA_ARGS__)
#endif

namespace {

// hvcC: NAL unit arrays (VPS/SPS/PPS) after a 22 byte header. Returns the NAL length field size.
int push_hvcc(de265_decoder_context* ctx, const uint8_t* hvcc, size_t size) {
  if (size < 23) return -1;
  int length_size = (hvcc[21] & 0x03) + 1;
  size_t pos = 23;
  for (int array = 0; array < hvcc[22]; array++) {
    if (pos + 3 > size) return -1;
    int count = (hvcc[pos + 1] << 8) | hvcc[pos + 2];
    pos += 3;
    for (int i = 0; i < count; i++) {
      if (pos + 2 > size) return -1;
      int length = (hvcc[pos] << 8) | hvcc[pos + 1];
      pos += 2;
      if (pos + length > size) return -1;
      de265_push_NAL(ctx, hvcc + pos, length, 0, nullptr);
      pos += length;
    }
  }
  return length_size;
}

bool push_samples(de265_decoder_context* ctx, const uint8_t* data, size_t size, int length_size) {
  size_t pos = 0;
  while (pos + length_size <= size) {
    size_t length = 0;
    for (int i = 0; i < length_size; i++) length = (length << 8) | data[pos + i];
    pos += length_size;
    if (pos + length > size) return false;
    de265_push_NAL(ctx, data + pos, static_cast<int>(length), 0, nullptr);
    pos += length;
  }
  return true;
}

// Returns the luma plane cropped/padded to width x height, or an empty vector on failure.
std::vector<uint8_t> decode_luma(const uint8_t* hvcc, size_t hvcc_size, const uint8_t* data, size_t data_size,
                                 int width, int height) {
  std::vector<uint8_t> luma;
  de265_decoder_context* ctx = de265_new_decoder();
  int length_size = push_hvcc(ctx, hvcc, hvcc_size);
  if (length_size > 0 && push_samples(ctx, data, data_size, length_size)) {
    de265_flush_data(ctx);
    // After flushing, decode until the decoder has nothing left. "Waiting for input" means it is done too;
    // the iteration cap guards against malformed streams.
    int more = 1;
    de265_error error = DE265_OK;
    for (int i = 0; more && i < 100000; i++) {
      error = de265_decode(ctx, &more);
      if (error != DE265_OK) break;
    }

    const de265_image* image = de265_get_next_picture(ctx);
    if (image == nullptr) {
      LOG_WARN("No picture decoded: %s", de265_get_error_text(error));
    } else if (de265_get_bits_per_pixel(image, 0) != 8) {
      LOG_WARN("Unsupported bit depth %d", de265_get_bits_per_pixel(image, 0));
    } else {
      int stride = 0;
      const uint8_t* plane = de265_get_image_plane(image, 0, &stride);
      int w = de265_get_image_width(image, 0);
      int h = de265_get_image_height(image, 0);
      // The coded size can differ from the tile's nominal size; copy the overlapping area.
      luma.assign(static_cast<size_t>(width) * height, 0);
      for (int y = 0; y < height && y < h; y++) {
        std::memcpy(luma.data() + static_cast<size_t>(y) * width, plane + static_cast<size_t>(y) * stride,
                    std::min(width, w));
      }
    }
  }
  de265_free_decoder(ctx);
  return luma;
}

}  // namespace

#ifndef HDR_NATIVE_NO_JNI
extern "C" JNIEXPORT jbyteArray JNICALL
Java_app_alextran_immich_hdr_HdrNative_nativeDecodeLuma(JNIEnv* env, jclass, jbyteArray hvcc_array, jbyteArray data_array,
                                                        jint width, jint height) {
  std::vector<uint8_t> hvcc(env->GetArrayLength(hvcc_array));
  env->GetByteArrayRegion(hvcc_array, 0, hvcc.size(), reinterpret_cast<jbyte*>(hvcc.data()));
  std::vector<uint8_t> data(env->GetArrayLength(data_array));
  env->GetByteArrayRegion(data_array, 0, data.size(), reinterpret_cast<jbyte*>(data.data()));

  std::vector<uint8_t> luma = decode_luma(hvcc.data(), hvcc.size(), data.data(), data.size(), width, height);
  if (luma.empty()) return nullptr;
  jbyteArray result = env->NewByteArray(static_cast<jsize>(luma.size()));
  env->SetByteArrayRegion(result, 0, static_cast<jsize>(luma.size()), reinterpret_cast<jbyte*>(luma.data()));
  return result;
}
#endif
