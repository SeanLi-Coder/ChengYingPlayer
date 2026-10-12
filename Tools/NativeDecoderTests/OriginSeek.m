#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "../../iina/NativePlayback/CYNMediaDecoder.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface CYNMediaDecoder (OriginSeekTests)
- (int)duplicateInputDescriptor;
- (CYNMediaInfo *)openOwnedDescriptor:(int)descriptor error:(NSError **)error;
@end

@interface OriginProbeDecoder : CYNMediaDecoder
@property(nonatomic) int rebuilds;
@property(nonatomic) int mode;
@end
@implementation OriginProbeDecoder
- (int)duplicateInputDescriptor {
  self.rebuilds++;
  if (self.mode == 1) return -1;
  int result = [super duplicateInputDescriptor];
  if (self.mode == 2) [self cancel];
  return result;
}
- (CYNMediaInfo *)openOwnedDescriptor:(int)descriptor error:(NSError **)error {
  if (self.mode == 3 && self.rebuilds > 0) {
    if (error) *error = [NSError errorWithDomain:CYNMediaDecoderErrorDomain code:CYNMediaDecoderErrorDecode
      userInfo:@{NSLocalizedDescriptionKey:@"Synthetic rebuild failure."}];
    return nil;
  }
  return [super openOwnedDescriptor:descriptor error:error];
}
@end

static int checks;
static void check(BOOL value, NSString *label) {
  checks++;
  if (!value) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
}
static NSUInteger inputDescriptorCount(struct stat identity) {
  NSArray<NSString *> *descriptors = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev/fd" error:NULL];
  check(descriptors != nil, @"Descriptor inventory is available");
  NSUInteger count = 0;
  for (NSString *entry in descriptors) {
    struct stat status;
    if (fstat(entry.intValue, &status) == 0 && status.st_dev == identity.st_dev && status.st_ino == identity.st_ino) count++;
  }
  return count;
}
static NSDictionary *decodedSamples(CYNMediaDecoder *decoder) {
  NSMutableArray *audio = [NSMutableArray new], *video = [NSMutableArray new];
  NSError *error = nil;
  while (YES) {
    @autoreleasepool {
      CYNMediaSample *sample = [decoder readSampleWithError:&error];
      check(!error, @"Decode to EOF without an error");
      if (!sample) break;
      check(audio.count + video.count < 1000, @"Bounded synthetic decode");
      CMSampleBufferRef buffer = sample.sampleBuffer;
      CMTime start = CMSampleBufferGetPresentationTimeStamp(buffer), duration = CMSampleBufferGetDuration(buffer);
      NSMutableDictionary *record = [@{@"start":@(start.value), @"start_scale":@(start.timescale),
        @"duration":@(duration.value), @"duration_scale":@(duration.timescale),
        @"count":@(CMSampleBufferGetNumSamples(buffer))} mutableCopy];
      if (sample.isVideo) {
        CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(buffer);
        check(pixel && CVPixelBufferGetPlaneCount(pixel) == 2, @"Native two-plane video sample");
        check(CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess, @"Read original video pixels");
        NSMutableData *bytes = [NSMutableData new];
        for (size_t plane = 0; plane < 2; ++plane) {
          size_t width = CVPixelBufferGetWidthOfPlane(pixel, plane) * (plane == 1 ? 2 : 1);
          size_t height = CVPixelBufferGetHeightOfPlane(pixel, plane);
          size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane);
          const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane);
          check(base && width <= stride && height <= 96, @"Bounded synthetic plane geometry");
          for (size_t row = 0; row < height; ++row) [bytes appendBytes:base + row * stride length:width];
        }
        CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
        record[@"pixels"] = bytes;
        [video addObject:record];
      } else {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buffer);
        size_t size = block ? CMBlockBufferGetDataLength(block) : 0;
        check(size > 0 && size <= 1024 * 1024, @"Bounded original PCM block");
        NSMutableData *bytes = [NSMutableData dataWithLength:size];
        check(CMBlockBufferCopyDataBytes(block, 0, size, bytes.mutableBytes) == kCMBlockBufferNoErr, @"Read original PCM bytes");
        record[@"pcm"] = bytes;
        [audio addObject:record];
      }
    }
  }
  check(![decoder readSampleWithError:&error] && !error, @"Repeated EOF is still successful EOF");
  return @{@"audio":audio, @"video":video};
}
static NSURL *fixture(NSString *root, NSString *name) {
  return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
}
static void earlySeek(NSURL *url) {
  struct stat identity;
  check(stat(url.fileSystemRepresentation, &identity) == 0, @"Synthetic source identity");
  OriginProbeDecoder *decoder = [OriginProbeDecoder new];
  NSError *error = nil;
  CYNMediaInfo *info = [decoder openURL:url error:&error];
  check(info && info.hasAudio && info.hasVideo && !error, @"Delayed source opens");
  NSDictionary *expected = decodedSamples(decoder);
  check([expected[@"audio"] count] >= 185 && [expected[@"video"] count] == 90, @"Complete initial audio and video reference");
  NSDictionary *firstAudio = [expected[@"audio"] firstObject], *firstVideo = [expected[@"video"] firstObject];
  check([firstAudio[@"start"] longLongValue] == 0, @"Audio begins at the normalized origin");
  double firstVideoTime = [firstVideo[@"start"] doubleValue] / [firstVideo[@"start_scale"] doubleValue];
  // A remuxed AAC edit list includes one priming packet before its visible
  // start, so the nonzero-origin fixture has a 1.021333-second normalized gap.
  check(firstVideoTime >= 1 && firstVideoTime < 1.05, @"Video begins about one second after normalized audio");
  check(inputDescriptorCount(identity) == 1, @"One input descriptor while open");
  for (NSNumber *target in @[@0, @0.4, @0.999999, @0]) {
    int previousRebuilds = decoder.rebuilds;
    check([decoder seekToSeconds:2 error:&error] && !error, @"Indexed seek reaches the middle");
    check(decoder.rebuilds == previousRebuilds, @"Ordinary middle seek does not rebuild the decoder");
    for (int index = 0; index < 12; ++index) check([decoder readSampleWithError:&error] && !error, @"Read after middle seek");
    check([decoder seekToSeconds:target.doubleValue error:&error] && !error, @"Early seek rebuilds from the same open input");
    NSDictionary *actual = decodedSamples(decoder);
    check([actual[@"audio"] isEqual:expected[@"audio"]], @"Every PCM byte, PTS, duration and sample count survives early seek");
    check([actual[@"video"] isEqual:expected[@"video"]], @"Every original video pixel, PTS and duration survives early seek");
    check(decoder.rebuilds == previousRebuilds + 1, @"Exactly one rebuild for an early seek");
    check(inputDescriptorCount(identity) == 1, @"Early seek leaves only one owned input descriptor");
  }
  // Unknown header/frame timing must not be fabricated as zero merely to use
  // the fast indexed path. This test changes only that private capability.
  CMTime unknown = kCMTimeInvalid;
  [decoder setValue:[NSValue value:&unknown withObjCType:@encode(CMTime)] forKey:@"originVideoStart"];
  int previousRebuilds = decoder.rebuilds;
  check([decoder seekToSeconds:0.4 error:&error] && !error && decoder.rebuilds == previousRebuilds + 1,
    @"Unknown first-video timing uses the conservative origin path");
  check([decodedSamples(decoder) isEqual:expected], @"Unknown-timing fallback does not lose media");
  [decoder cancel];
  check(![decoder seekToSeconds:0 error:&error] && error.code == CYNMediaDecoderErrorCancelled, @"Origin seek cannot clear terminal cancellation");
  [decoder close];
  check(inputDescriptorCount(identity) == 0, @"All source descriptors close after early-seek cycles");
  printf("PASS early-seek source=%s audio=%lu video=%lu rebuilds=%d\n", url.lastPathComponent.UTF8String,
    (unsigned long)[expected[@"audio"] count], (unsigned long)[expected[@"video"] count], decoder.rebuilds);
}
static void rebuildingFailures(NSURL *url) {
  struct stat identity;
  check(stat(url.fileSystemRepresentation, &identity) == 0, @"Failure fixture identity");
  for (int mode = 1; mode <= 3; ++mode) {
    OriginProbeDecoder *decoder = [OriginProbeDecoder new];
    NSError *error = nil;
    check([decoder openURL:url error:&error] && !error, @"Open before simulated rebuild failure");
    decoder.mode = mode;
    check(![decoder seekToSeconds:0 error:&error] && error, @"Rebuild failure is reported");
    NSInteger code = mode == 2 ? CYNMediaDecoderErrorCancelled : CYNMediaDecoderErrorDecode;
    check(error.code == code, @"Failure and cancellation remain distinct");
    NSError *sticky = nil;
    check(![decoder readSampleWithError:&sticky] && sticky.code == code, @"Read preserves the rebuild failure instead of reporting EOF");
    check(![decoder seekToSeconds:0.4 error:&sticky] && sticky.code == code, @"Later seek preserves the rebuild failure");
    check(inputDescriptorCount(identity) == 0, @"Failed rebuild does not leak original or duplicated descriptors");
    [decoder close];
    if (mode == 2) check(![decoder openURL:url error:&error] && error.code == code, @"A later open cannot reset cancelled identity");
  }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    check(argc == 2, @"Fixture directory argument");
    NSString *root = @(argv[1]);
    for (NSString *name in @[@"delayed-seek.mkv", @"delayed-seek.mp4", @"delayed-seek-offset.mp4"])
      earlySeek(fixture(root, name));
    rebuildingFailures(fixture(root, @"delayed-seek.mkv"));
    NSURL *source = fixture(root, @"path-source.mkv"), *moved = fixture(root, @"path-original.mkv");
    NSFileManager *files = NSFileManager.defaultManager;
    NSError *error = nil;
    check([files copyItemAtURL:fixture(root, @"delayed-seek.mkv") toURL:source error:&error], @"Copy a test-owned path-identity fixture");
    CYNMediaDecoder *decoder = [CYNMediaDecoder new];
    check([decoder openURL:source error:&error] && !error, @"Open original file identity");
    NSDictionary *expected = decodedSamples(decoder);
    check([files moveItemAtURL:source toURL:moved error:&error], @"Rename only the synthetic source path");
    check([files copyItemAtURL:fixture(root, @"audio24.wav") toURL:source error:&error], @"Replace only the synthetic source path");
    check([decoder seekToSeconds:0 error:&error] && !error, @"Early seek keeps the already-open file after path replacement");
    check([decodedSamples(decoder) isEqual:expected], @"Path replacement cannot redirect early seek to different content");
    [decoder close];
    printf("PASS origin-seek assertions=%d\n", checks);
  }
  return 0;
}
