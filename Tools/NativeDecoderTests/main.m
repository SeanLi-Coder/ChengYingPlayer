#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "../../iina/NativePlayback/CYNMediaDecoder.h"
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#include <libavutil/mastering_display_metadata.h>

@interface CYNMediaDecoder (Tests)
- (CYNMediaSample *)videoSample:(AVFrame *)frame error:(NSError **)error;
- (BOOL)attachColor:(AVFrame *)frame buffer:(CVPixelBufferRef)buffer error:(NSError **)error;
- (BOOL)validateHardwarePixelBuffer:(CVPixelBufferRef)buffer sourceFormat:(enum AVPixelFormat)source
                             range:(enum AVColorRange)range error:(NSError **)error;
- (BOOL)configureScaleColorspace:(int)space fullRange:(BOOL)full error:(NSError **)error;
- (BOOL)populateAspectSummary:(CYNMediaInfo *)summary streamRatio:(AVRational)streamRatio
                  codecRatio:(AVRational)codecRatio error:(NSError **)error;
@end

@interface CYNMediaInfo (Tests)
@property(nonatomic) NSInteger width, height;
@end

@interface FailingColorDecoder : CYNMediaDecoder
@property(nonatomic) BOOL configured;
@end
@implementation FailingColorDecoder
- (BOOL)configureScaleColorspace:(int)space fullRange:(BOOL)full error:(NSError **)error {
  self.configured = YES;
  if (error) *error = [NSError errorWithDomain:CYNMediaDecoderErrorDomain code:CYNMediaDecoderErrorDecode userInfo:nil];
  return NO;
}
@end

static int assertions;
static void check(BOOL condition, NSString *message) {
  assertions++;
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSURL *fixture(NSString *root, NSString *name) {
  return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
}
static CVPixelBufferRef pixelBuffer(OSType format) CF_RETURNS_RETAINED {
  CVPixelBufferRef pixel = NULL;
  check(CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, format, NULL, &pixel) == kCVReturnSuccess && pixel,
        @"Synthetic CoreVideo pixel buffer");
  return pixel;
}
static void pixelFormatBoundaries(void) {
  CYNMediaDecoder *decoder = [CYNMediaDecoder new];
  OSType types[] = {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                    kCVPixelFormatType_32BGRA};
  enum AVPixelFormat sources[] = {AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_YUV420P12LE,
                                 AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_RGBA, AV_PIX_FMT_YUVA420P,
                                 AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P9LE};
  for (NSUInteger output = 0; output < sizeof(types) / sizeof(*types); ++output) {
    CVPixelBufferRef pixel = pixelBuffer(types[output]);
    for (NSUInteger source = 0; source < sizeof(sources) / sizeof(*sources); ++source) {
      for (int full = 0; full < 2; ++full) {
        NSError *error = nil;
        BOOL accepted = [decoder validateHardwarePixelBuffer:pixel sourceFormat:sources[source]
                                                      range:full ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG error:&error];
        BOOL expected = (source == 0 && output == (NSUInteger)full) || (source == 1 && output == (NSUInteger)(2 + full));
        check(accepted == expected && (expected ? !error : error.code == CYNMediaDecoderErrorUnsupported),
              @"Hardware source/output precision, chroma, alpha and range matrix");
      }
    }
    CVPixelBufferRelease(pixel);
  }
  NSError *error = nil;
  check(![decoder validateHardwarePixelBuffer:NULL sourceFormat:AV_PIX_FMT_YUV420P range:AVCOL_RANGE_MPEG error:&error] &&
        error.code == CYNMediaDecoderErrorUnsupported, @"Missing hardware image rejected");
  CVPixelBufferRef full = pixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
  error = nil;
  check([decoder validateHardwarePixelBuffer:full sourceFormat:AV_PIX_FMT_YUVJ420P range:AVCOL_RANGE_UNSPECIFIED error:&error] && !error,
        @"Legacy YUVJ full range preserved");
  error = nil;
  check(![decoder validateHardwarePixelBuffer:full sourceFormat:AV_PIX_FMT_YUVJ420P range:AVCOL_RANGE_MPEG error:&error] &&
        error.code == CYNMediaDecoderErrorUnsupported, @"Contradictory source range rejected");
  error = nil;
  check(![decoder validateHardwarePixelBuffer:full sourceFormat:AV_PIX_FMT_YUV420P range:AVCOL_RANGE_NB error:&error] &&
        error.code == CYNMediaDecoderErrorUnsupported, @"Unknown source range rejected");
  CVPixelBufferRelease(full);
}
static AVMasteringDisplayMetadata validMastering(void) {
  AVMasteringDisplayMetadata metadata = {0};
  metadata.has_primaries = metadata.has_luminance = 1;
  metadata.display_primaries[0][0] = (AVRational){34000, 50000};
  metadata.display_primaries[0][1] = (AVRational){16000, 50000};
  metadata.display_primaries[1][0] = (AVRational){13250, 50000};
  metadata.display_primaries[1][1] = (AVRational){34500, 50000};
  metadata.display_primaries[2][0] = (AVRational){7500, 50000};
  metadata.display_primaries[2][1] = (AVRational){3000, 50000};
  metadata.white_point[0] = (AVRational){15635, 50000};
  metadata.white_point[1] = (AVRational){16450, 50000};
  metadata.max_luminance = (AVRational){1000, 1};
  metadata.min_luminance = (AVRational){1, 10000};
  return metadata;
}
static void staticHDRBoundaries(void) {
  CYNMediaDecoder *decoder = [CYNMediaDecoder new];
  AVFrame *frame = av_frame_alloc();
  check(frame != NULL, @"Static HDR frame allocation");
  frame->color_primaries = AVCOL_PRI_BT2020;
  frame->color_trc = AVCOL_TRC_SMPTE2084;
  frame->colorspace = AVCOL_SPC_BT2020_NCL;
  CVPixelBufferRef pixel = pixelBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
  AVMasteringDisplayMetadata *metadata = av_mastering_display_metadata_create_side_data(frame);
  check(metadata != NULL, @"Static HDR side data allocation");
  *metadata = validMastering();
  NSError *error = nil;
  check([decoder attachColor:frame buffer:pixel error:&error] && !error, @"Valid static HDR accepted");
  CFDataRef data = CVBufferCopyAttachment(pixel, kCVImageBufferMasteringDisplayColorVolumeKey, NULL);
  const uint8_t expected[] = {0x33,0xc2,0x86,0xc4,0x1d,0x4c,0x0b,0xb8,0x84,0xd0,0x3e,0x80,
                              0x3d,0x13,0x40,0x42,0x00,0x98,0x96,0x80,0x00,0x00,0x00,0x01};
  check(data && CFDataGetLength(data) == sizeof(expected) && !memcmp(CFDataGetBytePtr(data), expected, sizeof(expected)),
        @"Mastering data exact GBR order, quantization and network byte order");
  if (data) CFRelease(data);
  for (int scenario = 0; scenario < 16; ++scenario) {
    *metadata = validMastering();
    switch (scenario) {
      case 0: metadata->display_primaries[0][0].den = 0; break;
      case 1: metadata->display_primaries[1][1].num = -1; break;
      case 2: metadata->display_primaries[2][0] = (AVRational){50001, 50000}; break;
      case 3: metadata->white_point[0].den = -1; break;
      case 4: metadata->white_point[1].num = INT_MAX; break;
      case 5: metadata->max_luminance.den = 0; break;
      case 6: metadata->max_luminance = (AVRational){INT_MAX, 1}; break;
      case 7: metadata->min_luminance.num = -1; break;
      case 8: metadata->min_luminance = (AVRational){1001, 1}; break;
      case 9: metadata->max_luminance.num = 0; break;
      case 10: metadata->has_primaries = 0; break;
      case 11: metadata->has_luminance = 0; break;
      case 12: metadata->min_luminance.den = INT_MIN; break;
      case 13: metadata->display_primaries[0][1] = (AVRational){INT_MIN, INT_MIN}; break;
      case 14: metadata->max_luminance = (AVRational){429496730, 1000}; break;
      case 15: metadata->max_luminance = (AVRational){1, INT_MAX}; metadata->min_luminance = (AVRational){0, 1}; break;
    }
    error = nil;
    check(![decoder attachColor:frame buffer:pixel error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
          @"Invalid or unrepresentable mastering metadata rejected without rescale assertions");
  }
  av_frame_remove_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
  check(av_frame_new_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, 1) != NULL, @"Truncated mastering fixture");
  error = nil;
  check(![decoder attachColor:frame buffer:pixel error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
        @"Truncated mastering metadata is not silently discarded");
  av_frame_remove_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
  AVContentLightMetadata *light = av_content_light_metadata_create_side_data(frame);
  check(light != NULL, @"Light-level metadata allocation");
  light->MaxCLL = UINT16_MAX; light->MaxFALL = 0;
  error = nil;
  check([decoder attachColor:frame buffer:pixel error:&error] && !error, @"Maximum encoded light level and unspecified zero accepted");
  data = CVBufferCopyAttachment(pixel, kCVImageBufferContentLightLevelInfoKey, NULL);
  const uint8_t expectedLight[] = {0xff,0xff,0x00,0x00};
  check(data && CFDataGetLength(data) == sizeof(expectedLight) && !memcmp(CFDataGetBytePtr(data), expectedLight, sizeof(expectedLight)),
        @"Light levels encoded without clipping");
  if (data) CFRelease(data);
  for (int scenario = 0; scenario < 2; ++scenario) {
    light->MaxCLL = scenario ? 1000 : UINT16_MAX + 1U;
    light->MaxFALL = scenario ? UINT_MAX : 200;
    error = nil;
    check(![decoder attachColor:frame buffer:pixel error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
          @"Overflowing light level rejected instead of silently clipped");
  }
  av_frame_remove_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
  check(av_frame_new_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL, 1) != NULL, @"Truncated light-level fixture");
  error = nil;
  check(![decoder attachColor:frame buffer:pixel error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
        @"Truncated light-level metadata rejected");
  av_frame_remove_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
  frame->sample_aspect_ratio = (AVRational){1, 0};
  error = nil;
  check(![decoder attachColor:frame buffer:pixel error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
        @"Malformed decoded-frame SAR is rejected instead of silently dropped");
  av_frame_free(&frame);
  CVPixelBufferRelease(pixel);
}
static void capabilityMetadata(NSString *root) {
  CYNMediaDecoder *decoder = [CYNMediaDecoder new];
  NSError *error = nil;
  CYNMediaInfo *info = [decoder openURL:fixture(root, @"inventory.mkv") error:&error];
  check(info && !error, @"Container inventory fixture opens");
  check(info.videoStreamCount == 2 && info.audioStreamCount == 2 && info.subtitleStreamCount == 1 &&
        info.chapterCount == 2 && info.attachedPictureStreamCount == 0, @"All tracks and chapters exposed without selecting them");
  check(info.selectedVideoStreamIndex >= 0 && info.selectedVideoStreamIndex <= 1 &&
        info.selectedAudioStreamIndex >= 2 && info.selectedAudioStreamIndex <= 3,
        @"Selected FFmpeg stream indices belong to the expected media types");
  check(info.sampleAspectRatioKnown && info.sampleAspectNumerator == 1 && info.sampleAspectDenominator == 1 &&
        info.displayWidth == 320 && info.displayHeight == 180, @"Explicit square-pixel container geometry");
  check(!info.isHDR && !info.hasStaticHDRMetadata && [info.videoTransfer isEqualToString:@"bt709"], @"SDR transfer summary");
  [decoder close];
  for (NSString *name in @[@"aspect.mp4", @"aspect-rotated.mp4", @"aspect-override.mp4"]) {
    NSInteger numerator = [name isEqualToString:@"aspect-override.mp4"] ? 9 : 4;
    NSInteger denominator = [name isEqualToString:@"aspect-override.mp4"] ? 8 : 3;
    info = [decoder openURL:fixture(root, name) error:&error];
    check(info && !error && info.sampleAspectRatioKnown && info.sampleAspectNumerator == numerator && info.sampleAspectDenominator == denominator,
          @"Non-square sample aspect preserved at open");
    check(fabs(info.displayWidth - 320.0 * numerator / denominator) < 1e-9 && info.displayHeight == 180,
          @"Display dimensions apply SAR without premature integer rounding");
    check(info.rotationDegrees == ([name isEqualToString:@"aspect-rotated.mp4"] ? 270 : 0),
          @"Rotation remains separate from unrotated display geometry");
    CYNMediaSample *sample = [decoder readSampleWithError:&error];
    check(sample && !error, @"Non-square geometry still decodes");
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample.sampleBuffer);
    CFDictionaryRef aspect = CVBufferCopyAttachment(pixel, kCVImageBufferPixelAspectRatioKey, NULL);
    NSDictionary *aspectValues = CFBridgingRelease(aspect);
    check([aspectValues[(__bridge NSString *)kCVImageBufferPixelAspectRatioHorizontalSpacingKey] integerValue] == numerator &&
          [aspectValues[(__bridge NSString *)kCVImageBufferPixelAspectRatioVerticalSpacingKey] integerValue] == denominator,
          [NSString stringWithFormat:@"Rendered sample geometry agrees with open summary (%@, expected %ld/%ld, got %@/%@)",
            name, (long)numerator, (long)denominator,
            aspectValues[(__bridge NSString *)kCVImageBufferPixelAspectRatioHorizontalSpacingKey],
            aspectValues[(__bridge NSString *)kCVImageBufferPixelAspectRatioVerticalSpacingKey]]);
    [decoder close];
  }
  info = [decoder openURL:fixture(root, @"static-hdr.mkv") error:&error];
  check(info && !error && info.isHDR && info.hasStaticHDRMetadata && [info.videoTransfer isEqualToString:@"smpte2084"],
        @"Static HDR metadata and PQ reported from the selected video at open");
  check([decoder readSampleWithError:&error] && !error, @"Static HDR metadata remains accepted by frame validation");
  [decoder close];
  info = [decoder openURL:fixture(root, @"surround.wav") error:&error];
  check(info && !error && info.videoStreamCount == 0 && info.audioStreamCount == 1 && info.subtitleStreamCount == 0 &&
        info.chapterCount == 0 && info.selectedVideoStreamIndex == -1 && info.selectedAudioStreamIndex == 0,
        @"Audio-only inventory has explicit absent video selection");
  check(!info.sampleAspectRatioKnown && info.sampleAspectNumerator == 0 && info.sampleAspectDenominator == 1 &&
        info.displayWidth == 0 && info.displayHeight == 0 && !info.isHDR && [info.videoTransfer isEqualToString:@"unknown"],
        @"Audio-only input does not fabricate video geometry or transfer");
  [decoder close];
  info = [decoder openURL:fixture(root, @"cover.m4a") error:&error];
  check(info && !error && info.videoStreamCount == 1 && info.attachedPictureStreamCount == 1 &&
        info.audioStreamCount == 1 && !info.hasVideo && info.hasAudio && info.selectedVideoStreamIndex == -1,
        @"Attached cover is counted without being advertised as a selected video stream");
  [decoder close];
  info = [CYNMediaInfo new];
  info.width = 320; info.height = 180;
  AVRational invalid[] = {{-1, 1}, {1, 0}, {1, -1}, {0, -1}, {INT_MIN, INT_MIN}};
  for (NSUInteger index = 0; index < sizeof(invalid) / sizeof(*invalid); ++index) {
    for (int source = 0; source < 2; ++source) {
      error = nil;
      check(![decoder populateAspectSummary:info streamRatio:source ? (AVRational){1, 1} : invalid[index]
                                    codecRatio:source ? invalid[index] : (AVRational){1, 1} error:&error] &&
            error.code == CYNMediaDecoderErrorUnsupported, @"Malformed stream or codec SAR cannot be hidden by fallback");
    }
  }
  error = nil;
  check([decoder populateAspectSummary:info streamRatio:(AVRational){0, 0} codecRatio:(AVRational){0, 1} error:&error] && !error &&
        !info.sampleAspectRatioKnown && info.sampleAspectNumerator == 0 && info.sampleAspectDenominator == 1 &&
        info.displayWidth == 0 && info.displayHeight == 0, @"Unknown SAR remains unknown instead of square pixels");
  error = nil;
  check([decoder populateAspectSummary:info streamRatio:(AVRational){0, 1} codecRatio:(AVRational){8, 6} error:&error] && !error &&
        info.sampleAspectRatioKnown && info.sampleAspectNumerator == 4 && info.sampleAspectDenominator == 3,
        @"Codec SAR fallback is reduced without changing its value");
  error = nil;
  check([decoder populateAspectSummary:info streamRatio:(AVRational){2, 1} codecRatio:(AVRational){4, 3} error:&error] && !error &&
        info.sampleAspectNumerator == 2 && info.sampleAspectDenominator == 1 && info.displayWidth == 640,
        @"Explicit container display aspect has precedence over codec SAR");
}
static void exercise(NSString *root, NSString *name, BOOL audio, BOOL deep, BOOL hdr, BOOL full) {
  @autoreleasepool {
    CYNMediaDecoder *decoder = [CYNMediaDecoder new];
    NSError *error = nil;
    CYNMediaInfo *info = [decoder openURL:fixture(root, name) error:&error];
    check(info && !error, [@"Open " stringByAppendingString:name]);
    check(info.hasVideo && info.hasAudio == audio, @"Stream presence");
    check(info.width == 320 && info.height == 180, @"Original dimensions");
    check(info.duration > 3.9 && info.duration < 4.2, @"Duration");
    NSUInteger videos = 0, sounds = 0, hardware = 0, videoToolbox = 0, pcmFrames = 0;
    double lastVideo = -100, lastAudio = -100;
    CYNMediaSample *retained = nil;
    while (YES) {
      @autoreleasepool {
        CYNMediaSample *sample = [decoder readSampleWithError:&error];
        check(!error, @"Decode without errors");
        if (!sample) break;
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer));
        check(isfinite(pts), @"Finite presentation timestamp");
        if (sample.isVideo) {
          videos++;
          hardware += sample.hardwareDecoded;
          videoToolbox += sample.videoToolboxDecoded;
          check(!sample.hardwareDecoded || sample.videoToolboxDecoded, @"Hardware proof requires VideoToolbox path");
          check(pts >= lastVideo, @"Video timestamps monotonic");
          lastVideo = pts;
          CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample.sampleBuffer);
          check(pixel && CVPixelBufferGetWidth(pixel) == 320 && CVPixelBufferGetHeight(pixel) == 180, @"Pixel dimensions");
          OSType type = CVPixelBufferGetPixelFormatType(pixel);
          OSType expectedType = deep ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                                     : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
          check(type == expectedType, @"Pixel precision and range preserved");
          if (hdr) {
            CFTypeRef transfer = CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, NULL);
            CFTypeRef primaries = CVBufferCopyAttachment(pixel, kCVImageBufferColorPrimariesKey, NULL);
            check(transfer && CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ), @"PQ preserved");
            check(primaries && CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020), @"BT.2020 preserved");
            if (transfer) CFRelease(transfer);
            if (primaries) CFRelease(primaries);
          }
          if (!retained) retained = sample;
        } else {
          sounds++;
          check(pts >= lastAudio, @"Audio timestamps monotonic");
          lastAudio = pts;
          const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample.sampleBuffer));
          check(format && format->mFormatID == kAudioFormatLinearPCM && (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32,
                @"Float32 PCM");
          check(!(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved), @"Interleaved PCM");
          check(format->mSampleRate == info.audioSampleRate && format->mChannelsPerFrame == info.audioChannels, @"Audio parameters preserved");
          pcmFrames += CMSampleBufferGetNumSamples(sample.sampleBuffer);
        }
        check(videos + sounds < 5000, @"Bounded sample count");
      }
    }
    check(videos == 120, @"All 120 video frames including delayed tail");
    check(audio ? sounds > 0 && pcmFrames >= 191000 && pcmFrames <= 194000 : sounds == 0, @"Audio tail drained");
    check([decoder readSampleWithError:&error] == nil && !error, @"Repeated EOF remains EOF");
    check([decoder seekToSeconds:2 error:&error] && !error, @"Seek after EOF");
    BOOL found = NO;
    for (int i = 0; i < 500 && !found; ++i) {
      CYNMediaSample *sample = [decoder readSampleWithError:&error];
      check(sample && !error, @"Decode after seek");
      if (sample.isVideo) {
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer));
        check(pts <= 2.05 && pts >= -0.1, @"Seek preserves normalized origin and preroll");
        found = YES;
      }
    }
    check(found, @"Video after seek");
    [decoder close];
    check(retained && CMSampleBufferIsValid(retained.sampleBuffer) && CMSampleBufferGetImageBuffer(retained.sampleBuffer), @"Sample ownership survives decoder close");
    fprintf(stdout, "PASS %s video=%lu audio=%lu hardware=%lu videotoolbox=%lu pcm=%lu\n", name.UTF8String, videos, sounds, hardware, videoToolbox, pcmFrames);
  }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    check(argc == 2, @"Fixture directory argument");
    NSString *root = @(argv[1]);
    pixelFormatBoundaries();
    staticHDRBoundaries();
    capabilityMetadata(root);
    exercise(root, @"av.mp4", YES, NO, NO, NO);
    exercise(root, @"software.mkv", NO, NO, NO, NO);
    exercise(root, @"software10.mkv", NO, YES, NO, NO);
    exercise(root, @"hdr.mkv", NO, YES, YES, NO);
    exercise(root, @"offset.mp4", YES, NO, NO, NO);
    exercise(root, @"full.mp4", NO, NO, NO, YES);
    exercise(root, @"full10.mkv", NO, YES, NO, YES);
    NSError *error = nil;
    for (NSString *name in @[@"software12.mkv", @"software444.mkv"]) {
      CYNMediaDecoder *unsupported = [CYNMediaDecoder new];
      check([unsupported openURL:fixture(root, name) error:&error] && !error, @"High precision/chroma fixture opens");
      check(![unsupported readSampleWithError:&error] && error.code == CYNMediaDecoderErrorUnsupported,
            @"Real high precision/chroma frame is not silently reduced");
      error = nil;
      check(![unsupported readSampleWithError:&error] && error.code == CYNMediaDecoderErrorUnsupported,
            @"Unsupported precision/chroma failure survives cleanup");
      [unsupported close];
    }
    FailingColorDecoder *failingColor = [FailingColorDecoder new];
    check([failingColor openURL:fixture(root, @"software.mkv") error:&error] && !error, @"Color failure fixture opens");
    check(![failingColor readSampleWithError:&error] && failingColor.configured && error.code == CYNMediaDecoderErrorDecode,
          @"Failed color setup cannot return a successful sample");
    error = nil;
    check(![failingColor readSampleWithError:&error] && error.code == CYNMediaDecoderErrorDecode,
          @"Color setup failure remains observable after resource cleanup");
    [failingColor close];
    CYNMediaDecoder *decoder = [CYNMediaDecoder new];
    CYNMediaInfo *info = [decoder openURL:fixture(root, @"rotated.mp4") error:&error];
    check(info && !error && info.rotationDegrees == 270, @"Rotation metadata normalized clockwise");
    check([decoder readSampleWithError:&error] && !error, @"Rotated stream sample");
    [decoder cancel];
    check(![decoder readSampleWithError:&error] && error.code == CYNMediaDecoderErrorCancelled, @"Cancellation returns an error, not EOF");
    error = nil;
    check(![decoder openURL:fixture(root, @"av.mp4") error:&error] && error.code == CYNMediaDecoderErrorCancelled, @"Reopen never clears cancellation");
    [decoder close];
    decoder = [CYNMediaDecoder new];
    check(![decoder openURL:[NSURL URLWithString:@"https://127.0.0.1/media"] error:&error] && error.code == CYNMediaDecoderErrorInvalidInput, @"Network input rejected");
    check(![decoder openURL:[NSURL fileURLWithPath:root] error:&error] && error.code == CYNMediaDecoderErrorInvalidInput, @"Directory input rejected");
    NSURL *playlist = fixture(root, @"nested.ffconcat");
    check([@"ffconcat version 1.0\nfile 'av.mp4'\n" writeToURL:playlist atomically:YES encoding:NSUTF8StringEncoding error:&error], @"Local nested-input fixture");
    check(![decoder openURL:playlist error:&error] && error, @"Nested container rejected before loading children");
    check([decoder openURL:fixture(root, @"av.mp4") error:&error] && !error, @"Reuse after invalid open");
    AVFrame *frame = av_frame_alloc();
    check(av_frame_new_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS, 32) != NULL, @"Dynamic HDR fixture");
    check(![decoder videoSample:frame error:&error] && error.code == CYNMediaDecoderErrorUnsupported, @"Dynamic HDR explicitly rejected");
    av_frame_free(&frame);
    [decoder close];
    decoder = [CYNMediaDecoder new];
    info = [decoder openURL:fixture(root, @"surround.wav") error:&error];
    check(info && !error && !info.hasVideo && info.audioChannels == 6, @"Surround audio-only input");
    NSUInteger surroundFrames = 0;
    while (YES) {
      CYNMediaSample *sample = [decoder readSampleWithError:&error];
      check(!error, @"Surround decode");
      if (!sample) break;
      check(!sample.isVideo, @"Audio-only sample");
      size_t layoutSize = 0;
      const AudioChannelLayout *layout = CMAudioFormatDescriptionGetChannelLayout(CMSampleBufferGetFormatDescription(sample.sampleBuffer), &layoutSize);
      check(layout && layout->mNumberChannelDescriptions == 6, @"Six explicit channel positions");
      check(layout->mChannelDescriptions[0].mChannelLabel == kAudioChannelLabel_Left &&
            layout->mChannelDescriptions[1].mChannelLabel == kAudioChannelLabel_Right &&
            layout->mChannelDescriptions[2].mChannelLabel == kAudioChannelLabel_Center &&
            layout->mChannelDescriptions[3].mChannelLabel == kAudioChannelLabel_LFEScreen &&
            layout->mChannelDescriptions[4].mChannelLabel == kAudioChannelLabel_RearSurroundLeft &&
            layout->mChannelDescriptions[5].mChannelLabel == kAudioChannelLabel_RearSurroundRight, @"Surround order preserved");
      surroundFrames += CMSampleBufferGetNumSamples(sample.sampleBuffer);
    }
    check(surroundFrames == 96000, @"Surround PCM frame count");
    [decoder close];
    check([decoder openURL:fixture(root, @"audio24.wav") error:&error] && !error, @"24-bit audio fixture");
    check([decoder readSampleWithError:&error] && !error, @"24-bit integer precision fits float32");
    [decoder close];
    check([decoder openURL:fixture(root, @"audio32.wav") error:&error] && !error, @"32-bit audio fixture");
    check(![decoder readSampleWithError:&error] && error.code == CYNMediaDecoderErrorUnsupported, @"Full 32-bit integer precision is not silently reduced");
    [decoder close];
    decoder = [CYNMediaDecoder new];
    check([decoder openURL:fixture(root, @"av.mp4") error:&error] && !error, @"Concurrent cancel fixture");
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    CYNMediaDecoder *cancelledReader = decoder;
    __block NSError *workerError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      dispatch_semaphore_signal(entered);
      for (int i = 0; i < 5000; ++i) {
        @autoreleasepool {
          if (![cancelledReader readSampleWithError:&workerError]) break;
        }
      }
      dispatch_semaphore_signal(finished);
    });
    check(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"Reader entered worker");
    [cancelledReader cancel];
    check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"Concurrent cancellation exits promptly");
    check(workerError.code == CYNMediaDecoderErrorCancelled, @"Concurrent cancellation is observable");
    [decoder close];
    for (int round = 0; round < 20; ++round) {
      decoder = [CYNMediaDecoder new];
      check([decoder openURL:fixture(root, @"av.mp4") error:&error] && !error, @"Repeated open");
      for (int i = 0; i < 4; ++i) check([decoder readSampleWithError:&error] && !error, @"Repeated sample");
      [decoder close];
    }
    printf("PASS assertions=%d\n", assertions);
  }
  return 0;
}
