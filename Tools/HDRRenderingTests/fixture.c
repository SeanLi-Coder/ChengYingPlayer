// Generate redistributable synthetic SDR/PQ/HLG video without an FFmpeg executable.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { WIDTH = 128, HEIGHT = 64 };
static void require(int condition, const char *message) {
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void checked(int code, const char *message) {
  if (code < 0) {
    char error[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, error, sizeof(error));
    fprintf(stderr, "FFmpeg: %s: %s\n", message, error);
  }
  require(code >= 0, message);
}
static double transfer(double nits, enum AVColorTransferCharacteristic gamma) {
  if (gamma == AVCOL_TRC_SMPTE2084) {
    double powered = pow(nits / 10000.0, 2610.0 / 16384.0);
    return pow((3424.0 / 4096.0 + 2413.0 / 128.0 * powered) /
               (1.0 + 2392.0 / 128.0 * powered), 2523.0 / 32.0);
  }
  if (gamma == AVCOL_TRC_ARIB_STD_B67) {
    double scene = pow(nits / 1000.0, 1.0 / 1.2);
    return scene <= 1.0 / 12.0 ? sqrt(3.0 * scene) :
      0.17883277 * log(12.0 * scene - 0.28466892) + 0.55991073;
  }
  double linear = fmin(nits / 203.0, 1.0);
  return linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}
int main(int argc, char **argv) {
  require(argc == 3, "Usage: GenerateHDRFixture srgb|pq|hlg NEW_MKV");
  enum AVColorTransferCharacteristic gamma =
    !strcmp(argv[1], "srgb") ? AVCOL_TRC_IEC61966_2_1 :
    !strcmp(argv[1], "pq") ? AVCOL_TRC_SMPTE2084 :
    !strcmp(argv[1], "hlg") ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_UNSPECIFIED;
  require(gamma != AVCOL_TRC_UNSPECIFIED, "Known fixture transfer function");
  FILE *guard = fopen(argv[2], "wbx");
  require(guard != NULL, "Only create a new fixture path");
  fclose(guard);
  AVFormatContext *muxer = NULL;
  checked(avformat_alloc_output_context2(&muxer, NULL, "matroska", argv[2]), "Create Matroska muxer");
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_FFV1);
  require(codec != NULL, "Pinned playback stack includes lossless FFV1 encoder");
  AVCodecContext *encoder = avcodec_alloc_context3(codec);
  require(encoder != NULL, "Create encoder");
  encoder->width = WIDTH;
  encoder->height = HEIGHT;
  encoder->pix_fmt = AV_PIX_FMT_YUV444P10LE;
  encoder->time_base = (AVRational){1, 1};
  encoder->framerate = (AVRational){1, 1};
  encoder->color_range = AVCOL_RANGE_MPEG;
  encoder->color_primaries = gamma == AVCOL_TRC_IEC61966_2_1 ? AVCOL_PRI_BT709 : AVCOL_PRI_BT2020;
  encoder->color_trc = gamma;
  encoder->colorspace = gamma == AVCOL_TRC_IEC61966_2_1 ? AVCOL_SPC_BT709 : AVCOL_SPC_BT2020_NCL;
  encoder->bits_per_raw_sample = 10;
  encoder->thread_count = 1;
  if (muxer->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  checked(avcodec_open2(encoder, codec, NULL), "Open lossless fixture encoder");
  AVStream *stream = avformat_new_stream(muxer, NULL);
  require(stream != NULL, "Create fixture stream");
  stream->time_base = encoder->time_base;
  checked(avcodec_parameters_from_context(stream->codecpar, encoder), "Copy fixture color metadata");
  checked(avio_open(&muxer->pb, argv[2], AVIO_FLAG_WRITE), "Open private fixture output");
  checked(avformat_write_header(muxer, NULL), "Write container metadata");
  AVFrame *frame = av_frame_alloc();
  require(frame != NULL, "Create synthetic frame");
  frame->format = encoder->pix_fmt;
  frame->width = WIDTH;
  frame->height = HEIGHT;
  frame->color_range = encoder->color_range;
  frame->color_primaries = encoder->color_primaries;
  frame->color_trc = encoder->color_trc;
  frame->colorspace = encoder->colorspace;
  frame->pts = 0;
  checked(av_frame_get_buffer(frame, 32), "Allocate synthetic frame");
  const double luminance[8] = {0, 1, 10, 50, 100, 203, 400, 1000};
  for (unsigned row = 0; row < HEIGHT; row++) {
    uint16_t *y = (uint16_t *)(frame->data[0] + row * frame->linesize[0]);
    uint16_t *u = (uint16_t *)(frame->data[1] + row * frame->linesize[1]);
    uint16_t *v = (uint16_t *)(frame->data[2] + row * frame->linesize[2]);
    for (unsigned column = 0; column < WIDTH; column++) {
      double signal = transfer(luminance[column / 16], gamma);
      y[column] = (uint16_t)lround(64 + 876 * signal);
      u[column] = v[column] = 512;
    }
  }
  checked(avcodec_send_frame(encoder, frame), "Encode synthetic frame");
  checked(avcodec_send_frame(encoder, NULL), "Flush fixture encoder");
  AVPacket *packet = av_packet_alloc();
  require(packet != NULL, "Create fixture packet");
  while (1) {
    int result = avcodec_receive_packet(encoder, packet);
    if (result == AVERROR_EOF) break;
    checked(result, "Receive synthetic packet");
    av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
    packet->stream_index = stream->index;
    checked(av_interleaved_write_frame(muxer, packet), "Write synthetic packet");
    av_packet_unref(packet);
  }
  checked(av_write_trailer(muxer), "Finish lossless fixture");
  av_packet_free(&packet);
  av_frame_free(&frame);
  avcodec_free_context(&encoder);
  avio_closep(&muxer->pb);
  avformat_free_context(muxer);
  printf("PASS: Generated isolated 10-bit %s neutral luminance fixture\n", argv[1]);
  return 0;
}
