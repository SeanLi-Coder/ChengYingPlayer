#import <Foundation/Foundation.h>
#include <assert.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Explicit external boundaries for mechanically extracted FFmpeg/CYN functions.
// No decoded frame or hardware session is fabricated by this test.
#define AVERROR(e) (-(e))
#define AVERROR_EXIT (-1414092869)
#define AV_CODEC_ID_AV1 1
#define AV_CODEC_ID_H264 2
#define AV_PIX_FMT_FLAG_HWACCEL 1
#define AV_CODEC_HW_CONFIG_METHOD_HW_FRAMES_CTX 1
#define AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX 2
#define AV_CODEC_HW_CONFIG_METHOD_INTERNAL 4
#define AV_CODEC_HW_CONFIG_METHOD_AD_HOC 8
#define AV_LOG_ERROR 1
#define AV_LOG_DEBUG 2
#define av_assert0 assert
enum AVPixelFormat { AV_PIX_FMT_NONE = -1, AV_PIX_FMT_YUV420P, AV_PIX_FMT_VIDEOTOOLBOX };
typedef struct { int flags; const char *name; } AVPixFmtDescriptor;
typedef struct { void *data; } AVBufferRef;
typedef struct { enum AVPixelFormat format; } AVHWFramesContext;
typedef struct { int type; } AVHWDeviceContext;
typedef struct { struct { const char *name; } p; } FFHWAccel;
typedef struct { enum AVPixelFormat pix_fmt; int methods, device_type; } AVCodecHWConfig;
typedef struct { AVCodecHWConfig public; const FFHWAccel *hwaccel; } AVCodecHWConfigInternal;
typedef struct { const AVCodecHWConfigInternal **hw_configs; } AVCodec;
typedef struct { void *hwaccel_priv_data; } AVCodecInternal;
typedef struct AVCodecContext {
    int codec_id; void *opaque, *priv_data;
    AVCodecInternal *internal;
    AVBufferRef *hw_frames_ctx, *hw_device_ctx;
    enum AVPixelFormat sw_pix_fmt;
    const AVCodec *codec;
    enum AVPixelFormat (*get_format)(struct AVCodecContext *, const enum AVPixelFormat *);
} AVCodecContext;
static const AVPixFmtDescriptor *av_pix_fmt_desc_get(enum AVPixelFormat format) {
    static const AVPixFmtDescriptor hw = {AV_PIX_FMT_FLAG_HWACCEL, "videotoolbox"}, sw = {0, "yuv420p"};
    return format == AV_PIX_FMT_VIDEOTOOLBOX ? &hw : format == AV_PIX_FMT_YUV420P ? &sw : NULL;
}
static void *av_memdup(const void *source, size_t count) { void *p = malloc(count); if (p) memcpy(p, source, count); return p; }
static void av_freep(void *p) { free(*(void **)p); *(void **)p = NULL; }
#define ffcodec(codec) (codec)
#define av_log(...) ((void)0)
static int initResult, formatCalls, initCalls, uninitCalls;
static void ff_hwaccel_uninit(AVCodecContext *ctx) { (void)ctx; uninitCalls++; }
static int hwaccel_init(AVCodecContext *ctx, const FFHWAccel *accel) { (void)ctx; (void)accel; initCalls++; return initResult; }
typedef struct { int sentinel; } AVFrame;
typedef struct { uint8_t *data; int data_size; } TestOBU;
typedef struct { struct { AVFrame *f; } cur_frame; int start_unit, nb_unit; struct { TestOBU *units; } current_obu; } AV1DecContext;
typedef struct { int bitstream_size; uint8_t bytes[8]; } VTContext;
static int appendCalls, appendFailAt, commonCalls;
static AVFrame *submittedFrame;
static int ff_videotoolbox_buffer_append(VTContext *ctx, uint8_t *data, int size) {
    appendCalls++;
    if (appendCalls == appendFailAt) return AVERROR(ENOMEM);
    assert(size == 1 && ctx->bitstream_size < 8);
    ctx->bytes[ctx->bitstream_size++] = *data;
    return 0;
}
static int ff_videotoolbox_common_end_frame(AVCodecContext *ctx, AVFrame *frame) {
    (void)ctx; commonCalls++; submittedFrame = frame; return 23;
}
typedef struct { atomic_bool cancelled; } CYNInput;
static int CYNInterrupt(void *opaque) { return atomic_load(&((CYNInput *)opaque)->cancelled); }
