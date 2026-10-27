#include "src/webp/mux.h"
#include "src/webp/encode.h"
#include "src/webp/demux.h"
#include "src/webp/decode.h"

// Keep versioned libwebp structs inside C; Swift sees only opaque handles/bytes.
WebPAnimEncoder* YuzuWebPAnimationNew(int width, int height) {
  return WebPAnimEncoderNew(width, height, NULL);
}
int YuzuWebPAnimationAdd(WebPAnimEncoder* encoder, const uint8_t* rgba,
                        int width, int height, int timestamp, float quality) {
  WebPPicture picture;
  WebPConfig config;
  if (!WebPPictureInit(&picture) || !WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality)) return 0;
  picture.use_argb = 1;
  picture.width = width;
  picture.height = height;
  if (!WebPPictureImportRGBA(&picture, rgba, width * 4)) { WebPPictureFree(&picture); return 0; }
  int result = WebPAnimEncoderAdd(encoder, &picture, timestamp, &config);
  WebPPictureFree(&picture);
  return result;
}
size_t YuzuWebPAnimationFinish(WebPAnimEncoder* encoder, int timestamp, uint8_t** bytes) {
  WebPData data;
  WebPDataInit(&data);
  if (!WebPAnimEncoderAdd(encoder, NULL, timestamp, NULL) || !WebPAnimEncoderAssemble(encoder, &data)) return 0;
  *bytes = (uint8_t*)data.bytes;
  return data.size;
}
void YuzuWebPAnimationDelete(WebPAnimEncoder* encoder) { WebPAnimEncoderDelete(encoder); }
int YuzuWebPValidate(const uint8_t* bytes, size_t size, int (*cancelled)(void)) {
  WebPData data = {bytes, size};
  WebPAnimDecoder* decoder = WebPAnimDecoderNew(&data, NULL);
  if (!decoder) return 0;
  WebPAnimInfo info;
  int valid = WebPAnimDecoderGetInfo(decoder, &info) && info.canvas_width <= 4096 &&
              info.canvas_height <= 4096 && info.frame_count <= 5000;
  uint8_t* rgba;
  int timestamp;
  while (valid && WebPAnimDecoderHasMoreFrames(decoder)) {
    if (cancelled && cancelled()) { valid = 0; break; }
    valid = WebPAnimDecoderGetNext(decoder, &rgba, &timestamp);
  }
  WebPAnimDecoderDelete(decoder);
  return valid;
}
