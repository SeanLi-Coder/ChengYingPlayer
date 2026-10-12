#import "CYNMediaDecoder.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

NSErrorDomain const CYNMediaDecoderErrorDomain = @"CYNMediaDecoder";
static const int64_t CYNMaxPixels = 8192LL * 8192;

@interface CYNMediaInfo ()
@property(nonatomic) double duration;
@property(nonatomic) NSInteger width, height;
@property(nonatomic) double frameRate;
@property(nonatomic) BOOL hasVideo, hasAudio;
@property(nonatomic) NSInteger rotationDegrees, audioSampleRate, audioChannels;
@property(nonatomic, copy) NSString *videoCodec, *audioCodec;
@end
@implementation CYNMediaInfo
@end

@interface CYNMediaSample ()
- (instancetype)initWithBuffer:(CMSampleBufferRef)buffer video:(BOOL)video hardware:(BOOL)hardware videoToolbox:(BOOL)videoToolbox;
@end
@implementation CYNMediaSample
- (instancetype)initWithBuffer:(CMSampleBufferRef)buffer video:(BOOL)video hardware:(BOOL)hardware videoToolbox:(BOOL)videoToolbox {
  self = [super init];
  if (self) {
    _sampleBuffer = (CMSampleBufferRef)CFRetain(buffer);
    _video = video;
    _hardwareDecoded = hardware;
    _videoToolboxDecoded = videoToolbox;
  }
  return self;
}
- (void)dealloc { if (_sampleBuffer) CFRelease(_sampleBuffer); }
@end

typedef struct {
  atomic_bool cancelled;
  int fd;
  int64_t size;
} CYNInput;

static int CYNInterrupt(void *opaque) {
  return atomic_load_explicit(&((CYNInput *)opaque)->cancelled, memory_order_relaxed);
}
static int CYNRead(void *opaque, uint8_t *buffer, int size) {
  CYNInput *input = opaque;
  if (CYNInterrupt(input)) return AVERROR_EXIT;
  ssize_t count;
  do { count = read(input->fd, buffer, (size_t)size); } while (count < 0 && errno == EINTR && !CYNInterrupt(input));
  if (CYNInterrupt(input)) return AVERROR_EXIT;
  return count > 0 ? (int)count : count == 0 ? AVERROR_EOF : AVERROR(errno);
}
static int64_t CYNSeek(void *opaque, int64_t offset, int whence) {
  CYNInput *input = opaque;
  if (CYNInterrupt(input)) return AVERROR_EXIT;
  whence &= ~AVSEEK_FORCE;
  if (whence == AVSEEK_SIZE) return input->size;
  if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return AVERROR(EINVAL);
  off_t result = lseek(input->fd, offset, whence);
  return result < 0 ? AVERROR(errno) : result;
}
static int CYNRejectNestedIO(AVFormatContext *context, AVIOContext **io, const char *url,
                             int flags, AVDictionary **options) {
  // A local playlist must never turn this decoder into a network/file browser.
  return AVERROR(EPERM);
}
static enum AVPixelFormat CYNVideoFormat(AVCodecContext *context, const enum AVPixelFormat *formats) {
  if (context->hw_device_ctx) {
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p)
      if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
  }
  for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
    const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*p);
    if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
  }
  return AV_PIX_FMT_NONE;
}
static BOOL CYNPacketHasDynamicHDR(const AVPacketSideData *data, int count) {
  for (int i = 0; i < count; ++i) {
    if (data[i].type == AV_PKT_DATA_DOVI_CONF || data[i].type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS)
      return YES;
  }
  return NO;
}
static BOOL CYNFrameHasDynamicHDR(AVFrame *frame) {
  return av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS) ||
         av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_VIVID) ||
         av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) ||
         av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER);
}
static int CYNSupportedVideoDepth(enum AVPixelFormat format) {
  const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(format);
  if (!description || description->nb_components != 3 || description->log2_chroma_w != 1 ||
      description->log2_chroma_h != 1 ||
      (description->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_ALPHA | AV_PIX_FMT_FLAG_HWACCEL))) return 0;
  int depth = description->comp[0].depth;
  if (depth != 8 && depth != 10) return 0;
  for (int component = 1; component < 3; ++component)
    if (description->comp[component].depth != depth) return 0;
  return depth;
}
static BOOL CYNEncodeHDRRational(AVRational value, uint32_t scale, uint32_t maximum, uint32_t *encoded) {
  // Validate before rescaling: malformed rationals must never reach FFmpeg's
  // assertions or a narrowing cast. All products fit uint64_t for int32 inputs.
  if (value.den <= 0 || value.num < 0) return NO;
  uint64_t scaled = (uint64_t)value.num * scale;
  if (scaled > (uint64_t)maximum * (uint32_t)value.den) return NO;
  uint64_t rounded = (scaled + (uint32_t)value.den / 2) / (uint32_t)value.den;
  if (rounded > maximum) return NO;
  *encoded = (uint32_t)rounded;
  return YES;
}
static AudioChannelLabel CYNChannelLabel(enum AVChannel channel) {
  switch (channel) {
    case AV_CHAN_FRONT_LEFT: return kAudioChannelLabel_Left;
    case AV_CHAN_FRONT_RIGHT: return kAudioChannelLabel_Right;
    case AV_CHAN_FRONT_CENTER: return kAudioChannelLabel_Center;
    case AV_CHAN_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen;
    case AV_CHAN_BACK_LEFT: return kAudioChannelLabel_RearSurroundLeft;
    case AV_CHAN_BACK_RIGHT: return kAudioChannelLabel_RearSurroundRight;
    case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurround;
    case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurround;
    case AV_CHAN_BACK_CENTER: return kAudioChannelLabel_CenterSurround;
    case AV_CHAN_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter;
    case AV_CHAN_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter;
    default: return kAudioChannelLabel_Unknown;
  }
}

@interface CYNMediaDecoder () {
  CYNInput _input;
  AVFormatContext *_format;
  AVIOContext *_io;
  AVCodecContext *_video, *_audio;
  AVBufferRef *_hardware;
  AVPacket *_packet;
  AVFrame *_frame;
  struct SwsContext *_scale;
  SwrContext *_resample;
  AVChannelLayout _audioLayout;
  enum AVSampleFormat _audioFormat;
  CMAudioFormatDescriptionRef _audioDescription;
  CMVideoFormatDescriptionRef _videoDescription;
  CYNMediaInfo *_info;
  NSError *_failure;
  int _videoIndex, _audioIndex;
  BOOL _hasPacket, _demuxEOF, _videoFlushed, _audioFlushed, _videoEOF, _audioEOF, _resamplerEOF;
  int64_t _originUS, _nextAudioSample;
  CMTime _nextVideoTime;
}
@end

@implementation CYNMediaDecoder
- (instancetype)init {
  self = [super init];
  if (self) {
    atomic_init(&_input.cancelled, false);
    _input.fd = -1;
    _videoIndex = _audioIndex = -1;
  }
  return self;
}
- (void)dealloc { [self close]; }
- (void)cancel { atomic_store_explicit(&_input.cancelled, true, memory_order_relaxed); }
- (BOOL)fail:(CYNMediaDecoderError)code message:(NSString *)message error:(NSError **)error {
  _failure = [NSError errorWithDomain:CYNMediaDecoderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
  if (error) *error = _failure;
  return NO;
}
- (BOOL)checkCancelled:(NSError **)error {
  if (!CYNInterrupt(&_input)) return NO;
  [self fail:CYNMediaDecoderErrorCancelled message:@"Native decoding was cancelled." error:error];
  return YES;
}
- (void)close {
  av_packet_free(&_packet);
  av_frame_free(&_frame);
  avcodec_free_context(&_video);
  avcodec_free_context(&_audio);
  av_buffer_unref(&_hardware);
  sws_freeContext(_scale); _scale = NULL;
  swr_free(&_resample);
  av_channel_layout_uninit(&_audioLayout);
  if (_audioDescription) CFRelease(_audioDescription);
  _audioDescription = NULL;
  if (_videoDescription) CFRelease(_videoDescription);
  _videoDescription = NULL;
  avformat_close_input(&_format);
  if (_io) { av_freep(&_io->buffer); avio_context_free(&_io); }
  if (_input.fd >= 0) close(_input.fd);
  _input.fd = -1;
  _info = nil;
  _videoIndex = _audioIndex = -1;
  _hasPacket = _demuxEOF = _videoFlushed = _audioFlushed = _videoEOF = _audioEOF = _resamplerEOF = NO;
  _failure = nil;
}
- (AVCodecContext *)openStream:(int)index video:(BOOL)video error:(NSError **)error {
  const AVCodec *codec = avcodec_find_decoder(_format->streams[index]->codecpar->codec_id);
  AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : NULL;
  if (!context) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"No native decoder is available for this codec." error:error];
    return NULL;
  }
  context->max_pixels = CYNMaxPixels;
  context->thread_count = 4;
  context->pkt_timebase = _format->streams[index]->time_base;
  if (avcodec_parameters_to_context(context, _format->streams[index]->codecpar) < 0) {
    avcodec_free_context(&context);
    [self fail:CYNMediaDecoderErrorDecode message:@"The codec parameters are invalid." error:error];
    return NULL;
  }
  if (video) {
    for (int i = 0; ; ++i) {
      const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
      if (!config) break;
      if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
          (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
        if (av_hwdevice_ctx_create(&_hardware, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0)
          context->hw_device_ctx = av_buffer_ref(_hardware);
        break;
      }
    }
    context->get_format = CYNVideoFormat;
  }
  if (avcodec_open2(context, codec, NULL) < 0) {
    avcodec_free_context(&context);
    [self fail:CYNMediaDecoderErrorDecode message:@"The native codec could not be opened." error:error];
  }
  return context;
}
- (CYNMediaInfo *)openURL:(NSURL *)url error:(NSError **)error {
  NSError *openError = nil;
  CYNMediaInfo *result = [self openLocalURL:url error:&openError];
  if (!result) {
    [self close];
    _failure = openError;
  }
  if (error) *error = openError;
  return result;
}
- (CYNMediaInfo *)openLocalURL:(NSURL *)url error:(NSError **)error {
  if (error) *error = nil;
  [self close];
  if ([self checkCancelled:error]) return nil;
  if (!url.isFileURL || !url.fileSystemRepresentation) {
    [self fail:CYNMediaDecoderErrorInvalidInput message:@"Native playback currently accepts local regular files only." error:error];
    return nil;
  }
  _input.fd = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  struct stat status;
  if (_input.fd < 0 || fstat(_input.fd, &status) != 0 || !S_ISREG(status.st_mode)) {
    [self close];
    [self fail:CYNMediaDecoderErrorInvalidInput message:@"The media file could not be opened as a regular file." error:error];
    return nil;
  }
  _input.size = status.st_size;
  _format = avformat_alloc_context();
  uint8_t *buffer = av_malloc(64 * 1024);
  _io = buffer ? avio_alloc_context(buffer, 64 * 1024, 0, &_input, CYNRead, NULL, CYNSeek) : NULL;
  if (!_format || !_io) {
    if (!_io) av_free(buffer);
    [self close];
    [self fail:CYNMediaDecoderErrorResourceLimit message:@"The input buffer could not be allocated." error:error];
    return nil;
  }
  _format->pb = _io;
  _format->flags |= AVFMT_FLAG_CUSTOM_IO;
  _format->interrupt_callback = (AVIOInterruptCB){ CYNInterrupt, &_input };
  _format->io_open = CYNRejectNestedIO;
  _format->max_streams = 64;
  AVDictionary *options = NULL;
  av_dict_set(&options, "protocol_whitelist", "file", 0);
  // Exclude playlist/image-sequence demuxers before their header readers run.
  av_dict_set(&options, "format_whitelist",
              "mov,matroska,webm,avi,mpegts,mpeg,mpegvideo,h264,hevc,m4v,ivf,ogg,flac,wav,aiff,mp3,aac,ac3,eac3,dts,ape,asf,flv,nut,rm,mjpeg", 0);
  av_dict_set(&options, "probesize", "16777216", 0);
  av_dict_set(&options, "analyzeduration", "10000000", 0);
  int result = avformat_open_input(&_format, "native-local-media", NULL, &options);
  av_dict_free(&options);
  if (result >= 0) result = avformat_find_stream_info(_format, NULL);
  if (result < 0) {
    BOOL cancelled = CYNInterrupt(&_input);
    [self close];
    [self fail:cancelled ? CYNMediaDecoderErrorCancelled : CYNMediaDecoderErrorDecode
        message:cancelled ? @"Native decoding was cancelled." : @"The local media container could not be read." error:error];
    return nil;
  }
  _videoIndex = av_find_best_stream(_format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  _audioIndex = av_find_best_stream(_format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (_videoIndex >= 0 && (_format->streams[_videoIndex]->disposition & AV_DISPOSITION_ATTACHED_PIC)) _videoIndex = -1;
  _info = [CYNMediaInfo new];
  _info.videoCodec = _info.audioCodec = @"";
  _originUS = _format->start_time == AV_NOPTS_VALUE ? 0 : _format->start_time;
  _info.duration = _format->duration > 0 ? (double)_format->duration / AV_TIME_BASE : 0;
  if (_videoIndex >= 0) {
    AVStream *stream = _format->streams[_videoIndex];
    AVCodecParameters *parameters = stream->codecpar;
    if (parameters->width <= 0 || parameters->height <= 0 ||
        (int64_t)parameters->width * parameters->height > CYNMaxPixels) {
      [self fail:CYNMediaDecoderErrorResourceLimit message:@"The video dimensions exceed the native decoder limit." error:error];
      return nil;
    }
    if (CYNPacketHasDynamicHDR(parameters->coded_side_data, parameters->nb_coded_side_data)) {
      [self fail:CYNMediaDecoderErrorUnsupported message:@"Dynamic HDR requires the compatibility playback engine; it will not be silently discarded." error:error];
      return nil;
    }
    const AVPacketSideData *matrixData = av_packet_side_data_get(parameters->coded_side_data,
                                      parameters->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (matrixData) {
      if (matrixData->size < 9 * sizeof(int32_t)) {
        [self fail:CYNMediaDecoderErrorUnsupported message:@"The display transform is invalid." error:error];
        return nil;
      }
      const int32_t *m = (const int32_t *)matrixData->data;
      double angle = av_display_rotation_get(m);
      double quarter = round(angle / 90.0);
      double determinant = (double)m[0] * m[4] - (double)m[1] * m[3];
      double xLength = hypot(m[0], m[1]), yLength = hypot(m[3], m[4]);
      if (!isfinite(angle) || fabs(angle - quarter * 90) > 0.01 || determinant <= 0 ||
          fabs(xLength - 65536) > 2 || fabs(yLength - 65536) > 2 ||
          m[2] || m[5] || m[6] || m[7] || m[8] != (1 << 30)) {
        [self fail:CYNMediaDecoderErrorUnsupported message:@"This display transform needs the compatibility playback engine." error:error];
        return nil;
      }
      _info.rotationDegrees = ((-(NSInteger)quarter * 90) % 360 + 360) % 360;
    }
    _video = [self openStream:_videoIndex video:YES error:error];
    if (!_video) return nil;
    _info.hasVideo = YES;
    _info.width = parameters->width; _info.height = parameters->height;
    AVRational rate = av_guess_frame_rate(_format, stream, NULL);
    _info.frameRate = rate.den > 0 ? av_q2d(rate) : 0;
    _info.videoCodec = @(avcodec_get_name(parameters->codec_id));
  }
  if (_audioIndex >= 0) {
    _audio = [self openStream:_audioIndex video:NO error:error];
    if (!_audio) return nil;
    if (_audio->sample_rate <= 0 || _audio->sample_rate > 384000 ||
        _audio->ch_layout.nb_channels <= 0 || _audio->ch_layout.nb_channels > 8) {
      [self fail:CYNMediaDecoderErrorUnsupported message:@"This audio format needs the compatibility playback engine." error:error];
      return nil;
    }
    _info.hasAudio = YES;
    _info.audioSampleRate = _audio->sample_rate;
    _info.audioChannels = _audio->ch_layout.nb_channels;
    _info.audioCodec = @(avcodec_get_name(_audio->codec_id));
  }
  if (!_video && !_audio) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"No playable audio or video stream was found." error:error];
    return nil;
  }
  _packet = av_packet_alloc(); _frame = av_frame_alloc();
  if (!_packet || !_frame) {
    [self fail:CYNMediaDecoderErrorResourceLimit message:@"The decoder buffers could not be allocated." error:error];
    return nil;
  }
  _videoEOF = !_video; _audioEOF = !_audio; _resamplerEOF = !_audio;
  _nextVideoTime = kCMTimeZero; _nextAudioSample = 0;
  if ([self checkCancelled:error]) return nil;
  return _info;
}

- (CMTime)timeForFrame:(AVFrame *)frame stream:(int)index fallback:(CMTime)fallback {
  int64_t timestamp = frame->best_effort_timestamp;
  if (timestamp == AV_NOPTS_VALUE) timestamp = frame->pts;
  if (timestamp == AV_NOPTS_VALUE) return fallback;
  int64_t microseconds = av_rescale_q(timestamp, _format->streams[index]->time_base, AV_TIME_BASE_Q);
  int64_t normalized;
  if (microseconds == INT64_MIN || __builtin_sub_overflow(microseconds, _originUS, &normalized)) return kCMTimeInvalid;
  return CMTimeMake(normalized, AV_TIME_BASE);
}
- (OSType)nativePixelFormatForSource:(enum AVPixelFormat)source range:(enum AVColorRange)range error:(NSError **)error {
  int depth = CYNSupportedVideoDepth(source);
  if (!depth || (range != AVCOL_RANGE_UNSPECIFIED && range != AVCOL_RANGE_MPEG && range != AVCOL_RANGE_JPEG) ||
      (source == AV_PIX_FMT_YUVJ420P && range == AVCOL_RANGE_MPEG)) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"This pixel format requires the compatibility playback engine to avoid losing precision, range or chroma." error:error];
    return 0;
  }
  // Unspecified YUV uses the codec's range before this method, then limited
  // range by convention. Legacy YUVJ explicitly denotes full range.
  BOOL full = range == AVCOL_RANGE_JPEG || source == AV_PIX_FMT_YUVJ420P;
  return depth == 10 ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                     : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}
- (BOOL)validateHardwarePixelBuffer:(CVPixelBufferRef)buffer sourceFormat:(enum AVPixelFormat)source
                             range:(enum AVColorRange)range error:(NSError **)error {
  OSType expected = [self nativePixelFormatForSource:source range:range error:error];
  if (!expected) return NO;
  if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != expected || CVPixelBufferGetPlaneCount(buffer) != 2 ||
      CVPixelBufferGetWidthOfPlane(buffer, 0) != CVPixelBufferGetWidth(buffer) ||
      CVPixelBufferGetHeightOfPlane(buffer, 0) != CVPixelBufferGetHeight(buffer) ||
      CVPixelBufferGetWidthOfPlane(buffer, 1) != (CVPixelBufferGetWidth(buffer) + 1) / 2 ||
      CVPixelBufferGetHeightOfPlane(buffer, 1) != (CVPixelBufferGetHeight(buffer) + 1) / 2)
    return [self fail:CYNMediaDecoderErrorUnsupported message:@"The VideoToolbox output does not preserve the source pixel precision, range and chroma." error:error];
  return YES;
}
- (BOOL)configureScaleColorspace:(int)space fullRange:(BOOL)full error:(NSError **)error {
  if (!_scale || sws_setColorspaceDetails(_scale, sws_getCoefficients(space), full,
                                         sws_getCoefficients(space), full, 0, 1 << 16, 1 << 16) < 0)
    return [self fail:CYNMediaDecoderErrorDecode message:@"The native color conversion could not be configured safely." error:error];
  return YES;
}
- (BOOL)attachColor:(AVFrame *)frame buffer:(CVPixelBufferRef)buffer error:(NSError **)error {
  int primaries = frame->color_primaries, transfer = frame->color_trc, matrix = frame->colorspace;
  if (primaries == AVCOL_PRI_UNSPECIFIED && _video) primaries = _video->color_primaries;
  if (transfer == AVCOL_TRC_UNSPECIFIED && _video) transfer = _video->color_trc;
  if (matrix == AVCOL_SPC_UNSPECIFIED && _video) matrix = _video->colorspace;
  if (primaries == AVCOL_PRI_UNSPECIFIED) primaries = frame->height > 576 ? AVCOL_PRI_BT709 : AVCOL_PRI_SMPTE170M;
  if (transfer == AVCOL_TRC_UNSPECIFIED) transfer = AVCOL_TRC_BT709;
  if (matrix == AVCOL_SPC_UNSPECIFIED) matrix = frame->height > 576 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
  CFStringRef p = CVColorPrimariesGetStringForIntegerCodePoint(primaries);
  CFStringRef t = CVTransferFunctionGetStringForIntegerCodePoint(transfer);
  CFStringRef m = CVYCbCrMatrixGetStringForIntegerCodePoint(matrix);
  if (!p || !t || !m) return [self fail:CYNMediaDecoderErrorUnsupported message:@"The video color encoding cannot be represented safely by the native renderer." error:error];
  CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, p, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, t, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, m, kCVAttachmentMode_ShouldPropagate);
  CFStringRef chroma = NULL;
  switch (frame->chroma_location) {
    case AVCHROMA_LOC_LEFT: chroma = kCVImageBufferChromaLocation_Left; break;
    case AVCHROMA_LOC_CENTER: chroma = kCVImageBufferChromaLocation_Center; break;
    case AVCHROMA_LOC_TOPLEFT: chroma = kCVImageBufferChromaLocation_TopLeft; break;
    case AVCHROMA_LOC_TOP: chroma = kCVImageBufferChromaLocation_Top; break;
    case AVCHROMA_LOC_BOTTOMLEFT: chroma = kCVImageBufferChromaLocation_BottomLeft; break;
    case AVCHROMA_LOC_BOTTOM: chroma = kCVImageBufferChromaLocation_Bottom; break;
    default: break;
  }
  if (chroma) {
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, chroma, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, chroma, kCVAttachmentMode_ShouldPropagate);
  }
  AVRational ratio = frame->sample_aspect_ratio;
  if (ratio.num > 0 && ratio.den > 0) {
    NSDictionary *aspect = @{(__bridge NSString *)kCVImageBufferPixelAspectRatioHorizontalSpacingKey:@(ratio.num),
                             (__bridge NSString *)kCVImageBufferPixelAspectRatioVerticalSpacingKey:@(ratio.den)};
    CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, (__bridge CFDictionaryRef)aspect, kCVAttachmentMode_ShouldPropagate);
  }
  AVFrameSideData *mastering = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
  if (mastering) {
    if (mastering->size < sizeof(AVMasteringDisplayMetadata))
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"The static HDR mastering metadata is truncated." error:error];
    const AVMasteringDisplayMetadata *metadata = (const void *)mastering->data;
    uint16_t coordinates[8];
    uint32_t luminance[2], value;
    BOOL valid = metadata->has_primaries && metadata->has_luminance;
    int order[3] = {1, 2, 0};
    for (int i = 0; valid && i < 3; ++i) for (int j = 0; valid && j < 2; ++j) {
      valid = CYNEncodeHDRRational(metadata->display_primaries[order[i]][j], 50000, 50000, &value);
      if (valid) coordinates[2*i+j] = CFSwapInt16HostToBig((uint16_t)value);
    }
    for (int j = 0; valid && j < 2; ++j) {
      valid = CYNEncodeHDRRational(metadata->white_point[j], 50000, 50000, &value);
      if (valid) coordinates[6+j] = CFSwapInt16HostToBig((uint16_t)value);
    }
    valid = valid && CYNEncodeHDRRational(metadata->max_luminance, 10000, UINT32_MAX, &luminance[0]) &&
                     CYNEncodeHDRRational(metadata->min_luminance, 10000, UINT32_MAX, &luminance[1]);
    if (!valid || metadata->max_luminance.num <= 0 || luminance[0] == 0 ||
        (int64_t)metadata->min_luminance.num * metadata->max_luminance.den >
        (int64_t)metadata->max_luminance.num * metadata->min_luminance.den)
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"The static HDR mastering metadata cannot be represented safely." error:error];
    luminance[0] = CFSwapInt32HostToBig(luminance[0]);
    luminance[1] = CFSwapInt32HostToBig(luminance[1]);
    NSMutableData *bytes = [NSMutableData dataWithBytes:coordinates length:sizeof(coordinates)];
    [bytes appendBytes:luminance length:sizeof(luminance)];
    CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, (__bridge CFDataRef)bytes, kCVAttachmentMode_ShouldPropagate);
  }
  AVFrameSideData *light = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
  if (light) {
    if (light->size < sizeof(AVContentLightMetadata))
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"The static HDR light-level metadata is truncated." error:error];
    const AVContentLightMetadata *metadata = (const void *)light->data;
    if (metadata->MaxCLL > UINT16_MAX || metadata->MaxFALL > UINT16_MAX)
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"The static HDR light levels exceed the native metadata range." error:error];
    uint16_t values[2] = {CFSwapInt16HostToBig((uint16_t)metadata->MaxCLL),
                          CFSwapInt16HostToBig((uint16_t)metadata->MaxFALL)};
    NSData *bytes = [NSData dataWithBytes:values length:sizeof(values)];
    CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, (__bridge CFDataRef)bytes, kCVAttachmentMode_ShouldPropagate);
  }
  return YES;
}
- (CYNMediaSample *)videoSample:(AVFrame *)frame error:(NSError **)error {
  if (CYNFrameHasDynamicHDR(frame)) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"Dynamic HDR requires the compatibility playback engine; it will not be silently discarded." error:error];
    return nil;
  }
  AVFrameSideData *display = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
  if (display) {
    if (display->size < 9 * sizeof(int32_t)) {
      [self fail:CYNMediaDecoderErrorUnsupported message:@"The frame display transform is invalid." error:error];
      return nil;
    }
    const int32_t *m = (const int32_t *)display->data;
    double angle = av_display_rotation_get(m);
    double quarter = round(angle / 90.0);
    if (!isfinite(angle) || fabs(angle - quarter * 90) > 0.01 ||
        (double)m[0] * m[4] - (double)m[1] * m[3] <= 0 ||
        fabs(hypot(m[0], m[1]) - 65536) > 2 || fabs(hypot(m[3], m[4]) - 65536) > 2 ||
        m[2] || m[5] || m[6] || m[7] || m[8] != (1 << 30) ||
        ((-(NSInteger)quarter * 90) % 360 + 360) % 360 != _info.rotationDegrees) {
      [self fail:CYNMediaDecoderErrorUnsupported message:@"Changing or transformed frames require the compatibility playback engine." error:error];
      return nil;
    }
  }
  if (av_frame_get_side_data(frame, AV_FRAME_DATA_ICC_PROFILE)) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"Embedded ICC video profiles require the compatibility playback engine." error:error];
    return nil;
  }
  if (frame->flags & AV_FRAME_FLAG_INTERLACED) {
    [self fail:CYNMediaDecoderErrorUnsupported message:@"Interlaced video requires the compatibility playback engine." error:error];
    return nil;
  }
  if (frame->width <= 0 || frame->height <= 0 || (int64_t)frame->width * frame->height > CYNMaxPixels) {
    [self fail:CYNMediaDecoderErrorResourceLimit message:@"The decoded video dimensions exceed the native limit." error:error];
    return nil;
  }
  BOOL hardware = frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
  enum AVPixelFormat source = hardware ? (_video ? _video->sw_pix_fmt : AV_PIX_FMT_NONE) : frame->format;
  enum AVColorRange range = frame->color_range;
  if (range == AVCOL_RANGE_UNSPECIFIED && _video) range = _video->color_range;
  OSType type = [self nativePixelFormatForSource:source range:range error:error];
  if (!type) return nil;
  CVPixelBufferRef pixel = NULL;
  if (hardware) {
    // sw_pix_fmt describes the original codec format, not the potentially
    // reduced VideoToolbox output. Never infer source precision from CV alone.
    if ((_video->bits_per_raw_sample > 0 && _video->bits_per_raw_sample != CYNSupportedVideoDepth(source)) ||
        (frame->hw_frames_ctx && CYNSupportedVideoDepth(((AVHWFramesContext *)frame->hw_frames_ctx->data)->sw_format) != CYNSupportedVideoDepth(source))) {
      [self fail:CYNMediaDecoderErrorUnsupported message:@"The hardware frame format does not match the original video precision." error:error];
      return nil;
    }
    pixel = (CVPixelBufferRef)frame->data[3];
    if (![self validateHardwarePixelBuffer:pixel sourceFormat:source range:range error:error]) return nil;
    CVPixelBufferRetain(pixel);
  } else {
    BOOL deep = CYNSupportedVideoDepth(source) == 10;
    BOOL full = range == AVCOL_RANGE_JPEG || source == AV_PIX_FMT_YUVJ420P;
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                 (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, frame->width, frame->height, type,
                                          (__bridge CFDictionaryRef)attributes, &pixel);
    if (result == kCVReturnSuccess && CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess) {
      uint8_t *planes[4] = {CVPixelBufferGetBaseAddressOfPlane(pixel, 0), CVPixelBufferGetBaseAddressOfPlane(pixel, 1), NULL, NULL};
      int strides[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 1), 0, 0};
      _scale = sws_getCachedContext(_scale, frame->width, frame->height, frame->format,
                                    frame->width, frame->height, deep ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
                                    SWS_BILINEAR, NULL, NULL, NULL);
      if (_scale) {
        int space = frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 :
                    frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601;
        if (![self configureScaleColorspace:space fullRange:full error:error]) {
          CVPixelBufferUnlockBaseAddress(pixel, 0);
          CVPixelBufferRelease(pixel);
          return nil;
        }
      }
      int rows = _scale ? sws_scale(_scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides) : 0;
      CVPixelBufferUnlockBaseAddress(pixel, 0);
      if (rows != frame->height) { CVPixelBufferRelease(pixel); pixel = NULL; }
    } else if (pixel) { CVPixelBufferRelease(pixel); pixel = NULL; }
  }
  if (!pixel) {
    [self fail:CYNMediaDecoderErrorDecode message:@"The decoded video frame could not be transferred to the native renderer." error:error];
    return nil;
  }
  if (CVPixelBufferGetWidth(pixel) != (size_t)frame->width || CVPixelBufferGetHeight(pixel) != (size_t)frame->height) {
    CVPixelBufferRelease(pixel);
    [self fail:CYNMediaDecoderErrorDecode message:@"The native pixel buffer dimensions do not match the decoded frame." error:error];
    return nil;
  }
  if (![self attachColor:frame buffer:pixel error:error]) { CVPixelBufferRelease(pixel); return nil; }
  OSStatus status = noErr;
  if (!_videoDescription || !CMVideoFormatDescriptionMatchesImageBuffer(_videoDescription, pixel)) {
    if (_videoDescription) CFRelease(_videoDescription);
    _videoDescription = NULL;
    status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &_videoDescription);
  }
  CMTime pts = [self timeForFrame:frame stream:_videoIndex fallback:_nextVideoTime];
  if (!CMTIME_IS_NUMERIC(pts)) {
    CVPixelBufferRelease(pixel);
    [self fail:CYNMediaDecoderErrorUnsupported message:@"The video timestamps exceed the native time range." error:error];
    return nil;
  }
  CMTime duration = frame->duration > 0 ? CMTimeMake(av_rescale_q(frame->duration, _format->streams[_videoIndex]->time_base,
                                                                  (AVRational){1, 1000000}), 1000000)
                    : (_info.frameRate > 0 ? CMTimeMakeWithSeconds(1.0 / _info.frameRate, 1000000) : kCMTimeInvalid);
  CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
  CMSampleBufferRef buffer = NULL;
  if (!status) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, _videoDescription, &timing, &buffer);
  CVPixelBufferRelease(pixel);
  if (status || !buffer) {
    [self fail:CYNMediaDecoderErrorDecode message:@"The native video sample could not be created." error:error];
    return nil;
  }
  _nextVideoTime = CMTIME_IS_NUMERIC(duration) ? CMTimeAdd(pts, duration) : pts;
  // FFmpeg 7's HEVC decoder specification only enables hardware; other VT
  // codecs require it. No private FFmpeg internals are accessed to guess a
  // HEVC session's actual implementation.
  BOOL verifiedHardware = hardware && _video->codec_id != AV_CODEC_ID_HEVC;
  CYNMediaSample *sample = [[CYNMediaSample alloc] initWithBuffer:buffer video:YES hardware:verifiedHardware videoToolbox:hardware];
  CFRelease(buffer);
  return sample;
}

- (BOOL)prepareAudio:(AVFrame *)frame error:(NSError **)error {
  if (frame->sample_rate != _info.audioSampleRate || frame->ch_layout.nb_channels != _info.audioChannels)
    return [self fail:CYNMediaDecoderErrorUnsupported message:@"Changing audio formats require the compatibility playback engine." error:error];
  enum AVSampleFormat packed = av_get_packed_sample_fmt(frame->format);
  if (packed == AV_SAMPLE_FMT_DBL || packed == AV_SAMPLE_FMT_S64 ||
      (packed == AV_SAMPLE_FMT_S32 && (_audio->bits_per_raw_sample <= 0 || _audio->bits_per_raw_sample > 24)))
    return [self fail:CYNMediaDecoderErrorUnsupported message:@"This audio precision requires the compatibility playback engine; it will not be reduced to float32." error:error];
  if (_resample) {
    BOOL unspecifiedMonoOrStereo = frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC && frame->ch_layout.nb_channels <= 2;
    if (frame->format != _audioFormat || (!unspecifiedMonoOrStereo && av_channel_layout_compare(&_audioLayout, &frame->ch_layout) != 0))
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"Changing audio layouts require the compatibility playback engine." error:error];
    return YES;
  }
  if (av_channel_layout_copy(&_audioLayout, &frame->ch_layout) < 0)
    return [self fail:CYNMediaDecoderErrorResourceLimit message:@"The audio channel layout could not be allocated." error:error];
  if (_audioLayout.order == AV_CHANNEL_ORDER_UNSPEC && _audioLayout.nb_channels <= 2)
    av_channel_layout_default(&_audioLayout, _audioLayout.nb_channels);
  NSUInteger layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) + _audioLayout.nb_channels * sizeof(AudioChannelDescription);
  NSMutableData *layoutData = [NSMutableData dataWithLength:layoutSize];
  AudioChannelLayout *layout = layoutData.mutableBytes;
  layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
  layout->mNumberChannelDescriptions = _audioLayout.nb_channels;
  for (int i = 0; i < _audioLayout.nb_channels; ++i) {
    AudioChannelLabel label = CYNChannelLabel(av_channel_layout_channel_from_index(&_audioLayout, i));
    if (label == kAudioChannelLabel_Unknown)
      return [self fail:CYNMediaDecoderErrorUnsupported message:@"The audio channel positions cannot be represented safely." error:error];
    layout->mChannelDescriptions[i].mChannelLabel = label;
  }
  _audioFormat = frame->format;
  int result = swr_alloc_set_opts2(&_resample, &_audioLayout, AV_SAMPLE_FMT_FLT, frame->sample_rate,
                                   &_audioLayout, frame->format, frame->sample_rate, 0, NULL);
  if (result < 0 || !_resample || swr_init(_resample) < 0)
    return [self fail:CYNMediaDecoderErrorDecode message:@"The native PCM converter could not be created." error:error];
  AudioStreamBasicDescription format = {0};
  format.mSampleRate = frame->sample_rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
  format.mBytesPerPacket = format.mBytesPerFrame = (UInt32)(sizeof(float) * frame->ch_layout.nb_channels);
  format.mFramesPerPacket = 1;
  format.mChannelsPerFrame = frame->ch_layout.nb_channels;
  format.mBitsPerChannel = 32;
  if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, layoutSize, layout, 0, NULL, NULL, &_audioDescription) != noErr)
    return [self fail:CYNMediaDecoderErrorDecode message:@"The PCM channel description could not be created." error:error];
  return YES;
}
- (CYNMediaSample *)audioSample:(AVFrame *)frame error:(NSError **)error {
  if (frame && ![self prepareAudio:frame error:error]) return nil;
  if (!_resample) { _resamplerEOF = YES; return nil; }
  int inputCount = frame ? frame->nb_samples : 0;
  int capacity = swr_get_out_samples(_resample, inputCount);
  if (capacity < 0 || capacity > _info.audioSampleRate * 10) {
    [self fail:CYNMediaDecoderErrorResourceLimit message:@"The decoded audio block exceeds the native buffer limit." error:error];
    return nil;
  }
  capacity = MAX(capacity, 1);
  int channels = (int)_info.audioChannels, rate = (int)_info.audioSampleRate;
  uint8_t *bytes = av_malloc((size_t)capacity * channels * sizeof(float));
  if (!bytes) {
    [self fail:CYNMediaDecoderErrorResourceLimit message:@"The PCM buffer could not be allocated." error:error];
    return nil;
  }
  int64_t start = _nextAudioSample;
  if (frame) {
    CMTime timestamp = [self timeForFrame:frame stream:_audioIndex fallback:CMTimeMake(start, rate)];
    CMTime converted = CMTimeConvertScale(timestamp, rate, kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted) || __builtin_sub_overflow(converted.value, swr_get_delay(_resample, rate), &start)) {
      av_free(bytes);
      [self fail:CYNMediaDecoderErrorUnsupported message:@"The audio timestamps exceed the native time range." error:error];
      return nil;
    }
  }
  int count = swr_convert(_resample, &bytes, capacity, frame ? (const uint8_t **)frame->extended_data : NULL, inputCount);
  if (count <= 0) {
    av_free(bytes);
    if (count < 0) [self fail:CYNMediaDecoderErrorDecode message:@"The audio frame could not be converted to PCM." error:error];
    else if (!frame) _resamplerEOF = YES;
    return nil;
  }
  size_t length = (size_t)count * channels * sizeof(float);
  CMBlockBufferRef block = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length, kCFAllocatorDefault,
                                                     NULL, 0, length, 0, &block);
  if (!status) status = CMBlockBufferReplaceDataBytes(bytes, block, 0, length);
  av_free(bytes);
  CMSampleBufferRef buffer = NULL;
  CMSampleTimingInfo timing = {CMTimeMake(1, rate), CMTimeMake(start, rate), kCMTimeInvalid};
  size_t sampleSize = channels * sizeof(float);
  if (!status) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _audioDescription, count, 1, &timing, 1, &sampleSize, &buffer);
  if (block) CFRelease(block);
  if (status || !buffer) {
    [self fail:CYNMediaDecoderErrorDecode message:@"The native audio sample could not be created." error:error];
    return nil;
  }
  if (__builtin_add_overflow(start, (int64_t)count, &_nextAudioSample)) {
    CFRelease(buffer);
    [self fail:CYNMediaDecoderErrorUnsupported message:@"The audio timestamps exceed the native time range." error:error];
    return nil;
  }
  CYNMediaSample *sample = [[CYNMediaSample alloc] initWithBuffer:buffer video:NO hardware:NO videoToolbox:NO];
  CFRelease(buffer);
  return sample;
}
- (CYNMediaSample *)readSampleWithError:(NSError **)error {
  NSError *readError = nil;
  CYNMediaSample *sample = [self readDecodedSampleWithError:&readError];
  if (readError) {
    [self close];
    _failure = readError;
  }
  if (error) *error = readError;
  return sample;
}
- (CYNMediaSample *)readDecodedSampleWithError:(NSError **)error {
  if (error) *error = nil;
  if ([self checkCancelled:error]) return nil;
  if (_failure) { if (error) *error = _failure; return nil; }
  if (!_info || !_packet || !_frame) {
    [self fail:CYNMediaDecoderErrorInvalidInput message:@"The native decoder has no open media." error:error];
    return nil;
  }
  while (![self checkCancelled:error]) {
    BOOL receivedFrame = NO;
    for (int kind = 0; kind < 2; ++kind) {
      AVCodecContext *context = kind == 0 ? _video : _audio;
      BOOL *eof = kind == 0 ? &_videoEOF : &_audioEOF;
      if (!context || *eof) continue;
      int result = avcodec_receive_frame(context, _frame);
      if (result == AVERROR_EOF) { *eof = YES; continue; }
      if (result == AVERROR(EAGAIN)) continue;
      if (result < 0) {
        [self fail:CYNMediaDecoderErrorDecode message:@"The codec rejected a media frame." error:error];
        return nil;
      }
      CYNMediaSample *sample = kind == 0 ? [self videoSample:_frame error:error] : [self audioSample:_frame error:error];
      receivedFrame = YES;
      av_frame_unref(_frame);
      if (_failure) return nil;
      if ([self checkCancelled:error]) return nil;
      if (sample) return sample;
      // A resampler may buffer a frame without producing output yet.
    }
    if (receivedFrame) continue;
    if (_audioEOF && !_resamplerEOF) {
      CYNMediaSample *sample = [self audioSample:NULL error:error];
      if (_failure || sample) return sample;
    }
    if (_videoEOF && _audioEOF && _resamplerEOF) return nil;
    if (_hasPacket) {
      AVCodecContext *context = _packet->stream_index == _videoIndex ? _video : _audio;
      int result = avcodec_send_packet(context, _packet);
      if (result == AVERROR(EAGAIN)) {
        // Both receive calls just returned no output. FFmpeg forbids EAGAIN
        // from send and receive at the same time; do not spin forever.
        [self fail:CYNMediaDecoderErrorDecode message:@"The decoder made no forward progress." error:error];
        return nil;
      }
      av_packet_unref(_packet); _hasPacket = NO;
      if (result < 0) {
        [self fail:CYNMediaDecoderErrorDecode message:@"The codec rejected a media packet." error:error];
        return nil;
      }
      continue;
    }
    if (_demuxEOF) {
      BOOL flushed = NO;
      if (_video && !_videoFlushed) {
        int result = avcodec_send_packet(_video, NULL);
        if (result < 0 && result != AVERROR_EOF) {
          [self fail:CYNMediaDecoderErrorDecode message:@"The video decoder could not be drained." error:error]; return nil;
        }
        _videoFlushed = YES; flushed = YES;
      }
      if (_audio && !_audioFlushed) {
        int result = avcodec_send_packet(_audio, NULL);
        if (result < 0 && result != AVERROR_EOF) {
          [self fail:CYNMediaDecoderErrorDecode message:@"The audio decoder could not be drained." error:error]; return nil;
        }
        _audioFlushed = YES; flushed = YES;
      }
      if (!flushed) {
        [self fail:CYNMediaDecoderErrorDecode message:@"The drained decoder made no forward progress." error:error]; return nil;
      }
      continue;
    }
    int result = av_read_frame(_format, _packet);
    if (result == AVERROR_EOF) { _demuxEOF = YES; continue; }
    if (result < 0) {
      if ([self checkCancelled:error]) return nil;
      [self fail:CYNMediaDecoderErrorDecode message:@"The media packets could not be read completely." error:error];
      return nil;
    }
    if (_packet->stream_index != _videoIndex && _packet->stream_index != _audioIndex) {
      av_packet_unref(_packet); continue;
    }
    if (_packet->stream_index == _videoIndex && CYNPacketHasDynamicHDR(_packet->side_data, _packet->side_data_elems)) {
      av_packet_unref(_packet);
      [self fail:CYNMediaDecoderErrorUnsupported message:@"Dynamic HDR requires the compatibility playback engine; it will not be silently discarded." error:error];
      return nil;
    }
    _hasPacket = YES;
  }
  return nil;
}
- (BOOL)seekToSeconds:(double)seconds error:(NSError **)error {
  if (error) *error = nil;
  if ([self checkCancelled:error]) return NO;
  if (_failure) { if (error) *error = _failure; return NO; }
  if (!_info || !isfinite(seconds) || seconds < 0 || seconds > (double)INT64_MAX / AV_TIME_BASE - 1)
    return [self fail:CYNMediaDecoderErrorInvalidInput message:@"The seek time is invalid." error:error];
  long double scaled = roundl((long double)seconds * AV_TIME_BASE);
  int64_t target;
  if (scaled >= 0x1p63L || __builtin_add_overflow((int64_t)scaled, _originUS, &target))
    return [self fail:CYNMediaDecoderErrorInvalidInput message:@"The seek time exceeds the native time range." error:error];
  if (avformat_seek_file(_format, -1, INT64_MIN, target, target, 0) < 0) {
    if ([self checkCancelled:error]) return NO;
    return [self fail:CYNMediaDecoderErrorDecode message:@"The media container could not seek to this time." error:error];
  }
  if (_video) avcodec_flush_buffers(_video);
  if (_audio) avcodec_flush_buffers(_audio);
  av_packet_unref(_packet); av_frame_unref(_frame);
  _hasPacket = _demuxEOF = _videoFlushed = _audioFlushed = NO;
  _videoEOF = !_video; _audioEOF = !_audio; _resamplerEOF = !_audio;
  swr_free(&_resample);
  av_channel_layout_uninit(&_audioLayout);
  if (_audioDescription) CFRelease(_audioDescription);
  _audioDescription = NULL;
  _nextVideoTime = CMTimeMakeWithSeconds(seconds, AV_TIME_BASE);
  _nextAudioSample = llround(seconds * _info.audioSampleRate);
  return YES;
}
@end
