#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <dirent.h>

static int testSend(AVCodecContext *, const AVPacket *);
static int testReceive(AVCodecContext *, AVFrame *);
static int testOpen(AVCodecContext *, const AVCodec *, AVDictionary **);
static int testDevice(AVBufferRef **, enum AVHWDeviceType, const char *, AVDictionary *, int);
static const AVCodecHWConfig *testHWConfig(const AVCodec *, int);
static AVCodecContext *testAllocContext(const AVCodec *);
#define avcodec_send_packet testSend
#define avcodec_receive_frame testReceive
#define avcodec_open2 testOpen
#define av_hwdevice_ctx_create testDevice
#define avcodec_get_hw_config testHWConfig
#define avcodec_alloc_context3 testAllocContext
#ifndef CYN_DECODER_SOURCE
#define CYN_DECODER_SOURCE "../../iina/NativePlayback/CYNMediaDecoder.m"
#endif
#include CYN_DECODER_SOURCE
#undef avcodec_send_packet
#undef avcodec_receive_frame
#undef avcodec_open2
#undef av_hwdevice_ctx_create
#undef avcodec_get_hw_config
#undef avcodec_alloc_context3

// The compiled production source is unmodified. These explicit C-call fault
// boundaries never synthesize a decoded frame or claim real hardware output.
typedef NS_ENUM(int, Fault) { None, SendInit, ReceiveInit, DrainInit, Corrupt, Memory, Cancel, Stall, Oversized,
  DeviceMissing, DeviceMemory, DeviceExit, OpenInit, OpenCorrupt, OpenMemory, OpenExit,
  InvalidPacket, InvalidSideData, NoProgress, NoVTConfiguration, VideoContextMemory, AudioContextMemory };
static Fault fault;
static BOOL injected;
static BOOL requireHardware;
static __weak CYNMediaDecoder *activeDecoder;
static int checks, failures;
static void check(BOOL condition, NSString *message) {
  ++checks;
  if (!condition) { ++failures; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static BOOL av1Native(AVCodecContext *context) { return context && !strcmp(context->codec->name, "av1"); }
static int initFailure(AVCodecContext *context) {
  CYNAV1Bootstrap *state = context->opaque;
  const enum AVPixelFormat first[] = {AV_PIX_FMT_VIDEOTOOLBOX, AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
  const enum AVPixelFormat retry[] = {AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
  check(state && context->get_format(context, first) == AV_PIX_FMT_VIDEOTOOLBOX,
        @"Controlled initialization selects the actual production VT format callback");
  check(context->get_format(context, retry) == AV_PIX_FMT_NONE && state->initializationRejected,
        @"Only removal of the attempted VT format marks initialization rejection");
  injected = YES;
  return AVERROR_INVALIDDATA;
}
static int testSend(AVCodecContext *context, const AVPacket *packet) {
  if (av1Native(context)) {
    if (fault == DrainInit || fault == Stall) return packet ? 0 : initFailure(context);
    if (fault == ReceiveInit) return 0;
    if (!injected && packet) {
      if (fault == SendInit) return initFailure(context);
      if (fault == Corrupt || fault == Memory || fault == Cancel || fault == NoProgress) {
        injected = YES;
        if (fault == Cancel) [activeDecoder cancel];
        return fault == Memory ? AVERROR(ENOMEM) : fault == NoProgress ? AVERROR(EAGAIN) : AVERROR_INVALIDDATA;
      }
    }
  }
  return avcodec_send_packet(context, packet);
}
static int testReceive(AVCodecContext *context, AVFrame *frame) {
  if (av1Native(context)) {
    if (fault == DrainInit || fault == Stall) return AVERROR(EAGAIN);
    if (fault == ReceiveInit && !injected && avcodec_is_open(context)) {
      // Wait until a compressed packet is actually retained/sent.
      if ([[activeDecoder valueForKey:@"av1ReplayCount"] unsignedIntegerValue]) return initFailure(context);
      return AVERROR(EAGAIN);
    }
  }
  return avcodec_receive_frame(context, frame);
}
static int testOpen(AVCodecContext *context, const AVCodec *codec, AVDictionary **options) {
  if (codec && !strcmp(codec->name, "av1")) {
    if (fault == OpenInit) return initFailure(context);
    if (fault == OpenCorrupt) return AVERROR_INVALIDDATA;
    if (fault == OpenMemory) return AVERROR(ENOMEM);
    if (fault == OpenExit) return AVERROR_EXIT;
  }
  return avcodec_open2(context, codec, options);
}
static int testDevice(AVBufferRef **context, enum AVHWDeviceType type, const char *device, AVDictionary *options, int flags) {
  if (fault == DeviceMissing) return AVERROR(ENOSYS);
  if (fault == DeviceMemory) return AVERROR(ENOMEM);
  if (fault == DeviceExit) return AVERROR_EXIT;
  return av_hwdevice_ctx_create(context, type, device, options, flags);
}
static const AVCodecHWConfig *testHWConfig(const AVCodec *codec, int index) {
  if (fault == NoVTConfiguration && codec && codec->id == AV_CODEC_ID_AV1) return NULL;
  return avcodec_get_hw_config(codec, index);
}
static AVCodecContext *testAllocContext(const AVCodec *codec) {
  if (codec && ((fault == VideoContextMemory && codec->id == AV_CODEC_ID_AV1) ||
                (fault == AudioContextMemory && codec->type == AVMEDIA_TYPE_AUDIO))) {
    injected = YES;
    return NULL;
  }
  return avcodec_alloc_context3(codec);
}

@interface ObservedDecoder : CYNMediaDecoder
@property(nonatomic) NSInteger nativeOpens, softwareOpens, fallbacks;
@property(nonatomic) NSUInteger maxPackets, maxBytes;
@end
@implementation ObservedDecoder
- (AVCodecContext *)openCodec:(const AVCodec *)codec stream:(int)index video:(BOOL)video error:(NSError **)error {
  if (video && codec) {
    if (!strcmp(codec->name, "av1")) ++_nativeOpens;
    if (!strcmp(codec->name, "libdav1d")) ++_softwareOpens;
  }
  return [super openCodec:codec stream:index video:video error:error];
}
- (BOOL)switchAV1ToSoftware:(NSError **)error {
  ++_fallbacks;
  return [super switchAV1ToSoftware:error];
}
- (BOOL)retainAV1BootstrapPacket:(AVPacket *)packet error:(NSError **)error {
  // A size-only boundary: the production code must switch before cloning or
  // reading an oversized packet, so no undersized allocation is accessed.
  int original = packet->size;
  int originalSideCount = packet->side_data_elems;
  if (fault == Oversized && !_fallbacks) packet->size = (int)CYNAV1ReplayByteLimit + 1;
  if (fault == InvalidPacket) packet->size = -1;
  if (fault == InvalidSideData) packet->side_data_elems = -1;
  BOOL result = [super retainAV1BootstrapPacket:packet error:error];
  packet->size = original;
  packet->side_data_elems = originalSideCount;
  _maxPackets = MAX(_maxPackets, [[self valueForKey:@"av1ReplayCount"] unsignedIntegerValue]);
  _maxBytes = MAX(_maxBytes, [[self valueForKey:@"av1ReplayBytes"] unsignedIntegerValue]);
  return result;
}
@end

static NSData *pixels(CMSampleBufferRef sample) {
  CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
  check(pixel && CVPixelBufferGetPlaneCount(pixel) == 2, @"Actual native image has two YUV planes");
  if (!pixel || CVPixelBufferGetPlaneCount(pixel) != 2) return nil;
  CVReturn lockResult = CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
  check(lockResult == kCVReturnSuccess, @"Actual native image is readable");
  if (lockResult != kCVReturnSuccess) return nil;
  OSType type = CVPixelBufferGetPixelFormatType(pixel);
  BOOL ten = type == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  NSMutableData *data = [NSMutableData data];
  for (size_t plane = 0; plane < 2; ++plane) {
    size_t rowBytes = CVPixelBufferGetWidth(pixel) * (ten ? 2 : 1);
    check(CVPixelBufferGetBaseAddressOfPlane(pixel, plane) != NULL, @"Actual native image plane has readable storage");
    if (!CVPixelBufferGetBaseAddressOfPlane(pixel, plane)) {
      CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
      return nil;
    }
    for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(pixel, plane); ++y)
      [data appendBytes:(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel, plane) + y * CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                 length:rowBytes];
  }
  CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
  return data;
}
static NSDictionary *drain(ObservedDecoder *decoder, BOOL expectError) {
  NSMutableArray *pts = [NSMutableArray array];
  NSMutableArray *audioTiming = [NSMutableArray array];
  NSMutableData *video = [NSMutableData data], *audio = [NSMutableData data];
  NSInteger hardware = 0, vt = 0;
  NSError *error = nil;
  for (int guard = 0; guard < 20000; ++guard) {
    CYNMediaSample *sample = [decoder readSampleWithError:&error];
    if (!sample) break;
    if (sample.isVideo) {
      [pts addObject:@(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)))];
      [video appendData:pixels(sample.sampleBuffer)];
      hardware += sample.hardwareDecoded;
      vt += sample.videoToolboxDecoded;
    } else {
      CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample.sampleBuffer);
      size_t length = CMBlockBufferGetDataLength(block);
      NSMutableData *bytes = [NSMutableData dataWithLength:length];
      check(CMBlockBufferCopyDataBytes(block, 0, length, bytes.mutableBytes) == kCMBlockBufferNoErr, @"Read actual decoded PCM");
      [audio appendData:bytes];
      CMTime start = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer);
      CMTime duration = CMSampleBufferGetDuration(sample.sampleBuffer);
      [audioTiming addObject:@[@(start.value), @(start.timescale), @(duration.value), @(duration.timescale),
                              @(CMSampleBufferGetNumSamples(sample.sampleBuffer))]];
    }
  }
  check(expectError ? error != nil : error == nil, expectError ? @"Invalid/cancelled input fails explicitly" : @"Native AV1 reaches fully drained EOF without error");
  if (!expectError) check(![decoder readSampleWithError:&error] && !error, @"Repeated fully drained EOF stays EOF");
  if (requireHardware) {
    check(pts.count > 0 && hardware == (NSInteger)pts.count && vt == (NSInteger)pts.count,
          @"STRICT M4: every actual drain, including seek/restart/new open, contains only hardware VT frames");
    check(decoder.softwareOpens == 0 && decoder.fallbacks == 0,
          @"STRICT M4: no drain silently switches to software");
  }
  return @{ @"pts":pts, @"video":video, @"audio":audio, @"audioTiming":audioTiming,
            @"hardware":@(hardware), @"vt":@(vt), @"error":@(error.code) };
}
static NSUInteger descriptors(void) {
  DIR *dir = opendir("/dev/fd"); NSUInteger count = 0;
  if (dir) { while (readdir(dir)) ++count; closedir(dir); }
  return count;
}
static void assertReference(NSDictionary *actual, NSData *video, NSData *audio, NSInteger frames, NSString *label) {
  check((NSInteger)[actual[@"pts"] count] == frames, [label stringByAppendingString:@": every AV1 frame appears exactly once"]);
  check([actual[@"video"] isEqual:video], [label stringByAppendingString:@": exact YUV bytes equal independent dav1d output"]);
  check([actual[@"audio"] isEqual:audio], [label stringByAppendingString:@": PCM is neither duplicated nor dropped"]);
  NSArray *pts = actual[@"pts"];
  for (NSUInteger i = 0; i < pts.count; ++i)
    check(fabs([pts[i] doubleValue] - i / 12.0) < 0.0011, @"Original AV1 PTS survives fallback without reset or duplicate");
}
int main(int argc, const char **argv) { @autoreleasepool {
  if (argc != 3) return 2;
  NSString *root = @(argv[1]); BOOL strictHardware = !strcmp(argv[2], "hardware");
  requireHardware = strictHardware;
  check(CYNCodecSupportsVideoToolbox(avcodec_find_decoder_by_name("av1")), @"Candidate AV1 decoder advertises the real VT hardware configuration");
  NSUInteger fdStart = descriptors();
  for (NSString *depth in @[@"8", @"10"]) {
    NSURL *url = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"av1-%@.mkv", depth]]];
    NSData *reference = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"reference-%@.yuv", depth]]];
    NSData *audio = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"reference.f32"]];
    check(reference.length && audio.length, @"Independent video and PCM references exist");
    fault = None; injected = NO;
    ObservedDecoder *decoder = [ObservedDecoder new]; activeDecoder = decoder;
    NSError *error = nil;
    CYNMediaInfo *info = [decoder openURL:url error:&error];
    check(info && !error && info.width == 192 && info.height == 108 && info.hasAudio, @"Real AV1/audio fixture opens with original geometry");
    NSDictionary *result = drain(decoder, NO);
    NSArray *audioTiming = result[@"audioTiming"];
    assertReference(result, reference, audio, 24, @"Automatic real host decode");
    check(decoder.nativeOpens == 1, @"AV1 explicitly tries the VT-capable decoder before software");
    if (strictHardware) {
      check([result[@"hardware"] integerValue] == 24 && [result[@"vt"] integerValue] == 24 && decoder.softwareOpens == 0,
            @"STRICT M4: every actual AV1 frame uses the hardware-required VT path, no software fallback");
    } else {
      check(([result[@"hardware"] integerValue] == 24 && decoder.softwareOpens == 0) ||
            ([result[@"hardware"] integerValue] == 0 && [result[@"vt"] integerValue] == 0 && decoder.softwareOpens == 1),
            @"Automatic path is consistently verified hardware or working software fallback");
    }
    printf("ACTUAL AV1 depth=%s native_opens=%ld software_opens=%ld fallback=%ld frames=%lu vt=%ld hardware=%ld\n",
      depth.UTF8String, decoder.nativeOpens, decoder.softwareOpens, decoder.fallbacks,
      (unsigned long)[result[@"pts"] count], [result[@"vt"] integerValue], [result[@"hardware"] integerValue]);
    NSInteger previousNativeOpens = decoder.nativeOpens;
    BOOL usedSoftware = decoder.softwareOpens > 0;
    check([decoder seekToSeconds:1.0 error:&error], @"Indexed AV1 seek succeeds");
    NSDictionary *tail = drain(decoder, NO);
    check([tail[@"pts"] count] > 0, @"AV1 seek retains decodable frames");
    check([decoder seekToSeconds:0 error:&error], @"Same-owned-FD origin seek succeeds");
    result = drain(decoder, NO);
    assertReference(result, reference, audio, 24, @"Same-FD origin restart");
    check([result[@"audioTiming"] isEqual:audioTiming], @"Origin restart preserves every audio PTS, duration and sample count");
    check(!usedSoftware || decoder.nativeOpens == previousNativeOpens, @"Same media restart keeps the software choice without retrying VT");
    check([decoder openURL:url error:&error] != nil, @"A new open of the same URL succeeds");
    check(decoder.nativeOpens > previousNativeOpens, @"A new open resets the old software fallback choice");
    result = drain(decoder, NO);
    assertReference(result, reference, audio, 24, @"New open of the same URL");
    [decoder close]; [decoder close];
    if (strictHardware) continue;
    fault = NoVTConfiguration; injected = NO;
    decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
    check([decoder openURL:url error:&error] != nil, @"A library without AV1 VT configuration retains direct software playback");
    result = drain(decoder, NO);
    assertReference(result, reference, audio, 24, @"No VT configuration direct dav1d path");
    check(decoder.nativeOpens == 0 && decoder.softwareOpens == 1 && decoder.fallbacks == 0,
          @"Unavailable AV1 VT configuration chooses dav1d directly without failed native opening");
    for (NSNumber *mode in @[@(SendInit), @(ReceiveInit), @(DrainInit), @(Oversized)]) {
      fault = mode.intValue; injected = NO;
      decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
      check([decoder openURL:url error:&error] != nil, @"Controlled initialization-boundary fixture opens");
      result = drain(decoder, NO);
      assertReference(result, reference, audio, 24, [NSString stringWithFormat:@"Boundary mode %d", fault]);
      check([result[@"audioTiming"] isEqual:audioTiming], @"Fallback leaves all original audio timestamps and durations unchanged");
      check(decoder.fallbacks == 1 && decoder.softwareOpens == 1, @"Initialization/budget fallback happens exactly once");
      check(decoder.maxPackets <= 64 && decoder.maxBytes <= 8*1024*1024, @"Bootstrap packet cache respects both hard limits");
      [decoder close];
    }
    for (NSNumber *mode in @[@(DeviceMissing), @(OpenInit)]) {
      fault = mode.intValue; injected = NO;
      decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
      check([decoder openURL:url error:&error] != nil && !error, @"Device unavailable or proven open-time VT rejection uses software");
      result = drain(decoder, NO);
      assertReference(result, reference, audio, 24, @"Open-time software fallback");
      check(decoder.nativeOpens == 1 && decoder.softwareOpens == 1, @"Open-time fallback selects dav1d exactly once");
      [decoder close];
    }
    for (NSNumber *mode in @[@(DeviceMemory), @(DeviceExit), @(OpenCorrupt), @(OpenMemory), @(OpenExit)]) {
      fault = mode.intValue; injected = NO;
      decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
      check(![decoder openURL:url error:&error] && error, @"Open/device interruption, corruption or resource failure remains explicit");
      check(decoder.softwareOpens == 0 && decoder.fallbacks == 0, @"Unproven open failure never masquerades as hardware unavailability");
      [decoder close];
    }
    for (NSNumber *mode in @[@(VideoContextMemory), @(AudioContextMemory)]) {
      fault = mode.intValue; injected = NO;
      decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
      check(![decoder openURL:url error:&error] && error && injected,
            @"Actual codec-context allocation fault makes open fail explicitly");
      check(error.code == CYNMediaDecoderErrorResourceLimit && [error.domain isEqual:CYNMediaDecoderErrorDomain],
            @"Context allocation failure is a resource error, never Unsupported");
      check(decoder.softwareOpens == 0 && decoder.fallbacks == 0,
            @"Codec-context allocation failure never tries another decoder");
      [decoder close];
    }
    fault = None; injected = NO;
    decoder = [ObservedDecoder new]; error = nil;
    check(![decoder openCodec:NULL stream:-1 video:YES error:&error] && error.code == CYNMediaDecoderErrorUnsupported,
          @"A genuinely missing decoder remains Unsupported without accessing a stream");
    [decoder close];
    for (NSNumber *mode in @[@(Corrupt), @(Memory), @(Cancel), @(InvalidPacket), @(InvalidSideData), @(NoProgress)]) {
      fault = mode.intValue; injected = NO;
      decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
      check([decoder openURL:url error:&error] != nil, @"Explicit failure-boundary fixture opens");
      result = drain(decoder, YES);
      check(decoder.fallbacks == 0 && decoder.softwareOpens == 0, @"Corruption/allocation/cancellation is not mislabeled as VT initialization rejection");
      if (fault == Cancel) check([result[@"error"] integerValue] == CYNMediaDecoderErrorCancelled, @"Concurrent cancellation remains terminal and correctly classified");
      [decoder close];
    }
    fault = Stall; injected = NO;
    decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
    NSURL *longURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"long-%@.mkv", depth]]];
    check([decoder openURL:longURL error:&error] != nil, @"Packet-count budget fixture opens");
    result = drain(decoder, NO);
    NSData *longVideo = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"long-%@.yuv", depth]]];
    NSData *longAudio = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"long.f32"]];
    assertReference(result, longVideo, longAudio, 96, @"Packet-count bound fallback");
    check(decoder.maxPackets == 64 && decoder.fallbacks == 1, @"The 65th packet forces software without retaining an unbounded prefix");
    [decoder close];

    fault = SendInit; injected = NO;
    decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
    check([decoder openURL:url error:&error] != nil, @"Post-output guard fixture opens");
    [decoder setValue:@YES forKey:@"av1ProducedVideo"];
    result = drain(decoder, YES);
    check(decoder.fallbacks == 0, @"Controlled already-produced state does not silently restart video after a later error");
    [decoder close];

    fault = None; injected = NO;
    decoder = [ObservedDecoder new]; activeDecoder = decoder; error = nil;
    NSURL *owned = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"owned-%@.mkv", depth]]];
    NSFileManager *manager = NSFileManager.defaultManager;
    check([manager copyItemAtURL:url toURL:owned error:&error], @"Create an owned source for descriptor identity regression");
    check([decoder openURL:owned error:&error] != nil, @"Open descriptor identity fixture");
    result = drain(decoder, NO);
    NSURL *moved = [NSURL fileURLWithPath:[owned.path stringByAppendingString:@".original"]];
    check([manager moveItemAtURL:owned toURL:moved error:&error], @"Move only the owned fixture pathname after opening");
    NSString *otherDepth = [depth isEqual:@"8"] ? @"10" : @"8";
    NSURL *replacement = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"av1-%@.mkv", otherDepth]]];
    check([manager copyItemAtURL:replacement toURL:owned error:&error], @"Replace the owned pathname with different media");
    check([decoder seekToSeconds:0 error:&error], @"Early seek retains the original open file rather than reopening its pathname");
    result = drain(decoder, NO);
    assertReference(result, reference, audio, 24, @"Same-owned-descriptor source replacement");
    [decoder close];
  }
  fault = None; activeDecoder = nil;
  check(descriptors() == fdStart, @"All owned file descriptors close after repeated open, seek, failure and cancellation");
  printf("Native AV1 checks=%d failures=%d strict_hardware=%d\n", checks, failures, strictHardware);
  return failures ? 1 : 0;
}}
