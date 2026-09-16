#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import "FFmpegController.h"
#import "IINA-Swift.h"

@implementation FFmpegLogger
+ (void)debug:(NSString *)message {}
+ (void)warn:(NSString *)message {}
+ (void)error:(NSString *)message {}
@end

static NSUInteger checks = 0;
static void check(BOOL condition, NSString *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
  checks++;
  printf("PASS: %s\n", message.UTF8String);
}

static BOOL spinUntil(BOOL (^predicate)(void), NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!predicate() && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
  }
  return predicate();
}

@interface Recorder: NSObject <FFmpegControllerDelegate>
@property NSMutableArray<NSNumber *> *generations;
@property NSArray<FFThumbnail *> *thumbnails;
@property BOOL succeeded;
@property BOOL allOnMain;
@end

@implementation Recorder
- (instancetype)init {
  if ((self = [super init])) {
    _generations = [NSMutableArray array];
    _allOnMain = YES;
  }
  return self;
}
- (void)didUpdateThumbnails:(NSArray<FFThumbnail *> *)thumbnails forFile:(NSString *)filename withProgress:(NSInteger)progress generation:(NSUInteger)generation {
  _allOnMain &= [NSThread isMainThread];
  check(generation > 0, @"partial update preserves generation");
}
- (void)didGenerateThumbnails:(NSArray<FFThumbnail *> *)thumbnails forFile:(NSString *)filename succeeded:(BOOL)succeeded generation:(NSUInteger)generation {
  _allOnMain &= [NSThread isMainThread];
  [_generations addObject:@(generation)];
  _thumbnails = thumbnails;
  _succeeded = succeeded;
}
@end

static uint64_t footprint(void) {
  task_vm_info_data_t info = {0};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
  return result == KERN_SUCCESS ? info.phys_footprint : 0;
}

static NSUInteger descriptorCount(void) {
  NSUInteger count = 0;
  for (int descriptor = 0; descriptor < 2048; descriptor++) {
    if (fcntl(descriptor, F_GETFD) >= 0) count++;
  }
  return count;
}

static void request(FFmpegController *controller, Recorder *recorder, NSString *path, int width, NSUInteger generation) {
  NSUInteger before = recorder.generations.count;
  [controller generateThumbnailForFile:path thumbWidth:width generation:generation];
  check(spinUntil(^BOOL { return recorder.generations.count > before; }, 15), @"decoder completes within deadline");
  check(recorder.generations.lastObject.unsignedIntegerValue == generation, @"completion preserves generation");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    check(argc == 2, @"fixture directory provided");
    NSString *directory = [NSString stringWithUTF8String:argv[1]];
    NSString *video = [directory stringByAppendingPathComponent:@"4k.mp4"];
    FFmpegController *controller = [[FFmpegController alloc] init];
    Recorder *recorder = [[Recorder alloc] init];
    controller.delegate = recorder;
    controller.thumbnailCount = 8;
    request(controller, recorder, video, 240, 1);
    check(recorder.succeeded && recorder.thumbnails.count > 0, @"real 4K B-frame video generates thumbnails");
    for (FFThumbnail *thumbnail in recorder.thumbnails) {
      check(thumbnail.image.size.width == 240 && thumbnail.image.size.height == 135, @"4K thumbnails have bounded expected dimensions");
      check(isfinite(thumbnail.realTime) && thumbnail.realTime >= 0 && thumbnail.realTime <= 1.1, @"4K timestamps stay on the video timeline");
    }
    request(controller, recorder, [directory stringByAppendingPathComponent:@"offset.ts"], 240, 2);
    check(recorder.succeeded && recorder.thumbnails.count > 0, @"nonzero-start transport stream generates thumbnails");
    check(recorder.thumbnails.firstObject.realTime < 1.1, @"container start offset is removed from preview timestamps");
    request(controller, recorder, [directory stringByAppendingPathComponent:@"resize.ts"], 240, 3);
    check(recorder.succeeded && recorder.thumbnails.count > 0, @"changing-resolution stream decodes without out-of-bounds scaling");
    NSMutableSet *heights = [NSMutableSet set];
    for (FFThumbnail *thumbnail in recorder.thumbnails) [heights addObject:@(thumbnail.image.size.height)];
    check([heights containsObject:@135] && [heights containsObject:@180], @"changing-resolution fixture scales both landscape and 4:3 frames");
    check(recorder.allOnMain, @"all delegate callbacks run on the main thread");

    NSUInteger initialDescriptors = descriptorCount();
    uint64_t initialFootprint = footprint();
    for (NSUInteger index = 0; index < 24; index++) {
      @autoreleasepool {
        request(controller, recorder, [directory stringByAppendingPathComponent:@"audio.wav"], 240, 10 + index);
        check(!recorder.succeeded, @"audio-only input fails safely");
      }
    }
    check(descriptorCount() <= initialDescriptors + 2, @"repeated decoder failures do not leak file descriptors");
    uint64_t failureGrowth = footprint() - MIN(initialFootprint, footprint());
    check(failureGrowth < 32ULL * 1024 * 1024, @"repeated error exits have bounded memory growth");

    NSString *corrupt = [directory stringByAppendingPathComponent:@"corrupt.mp4"];
    [@"Invalid movie payload" writeToFile:corrupt atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    for (NSUInteger index = 0; index < 8; index++) {
      request(controller, recorder, corrupt, 240, 300 + index);
      check(!recorder.succeeded, @"malformed input fails safely");
      request(controller, recorder, [directory stringByAppendingPathComponent:@"missing.mp4"], 240, 400 + index);
      check(!recorder.succeeded, @"missing input fails safely");
    }
    check(descriptorCount() <= initialDescriptors + 2, @"malformed and missing inputs do not leak descriptors");
    request(controller, recorder, [directory stringByAppendingPathComponent:@"resize.ts"], 4096, 49);
    check(!recorder.succeeded, @"large thumbnails are bounded by the total decoded-memory budget");

    request(controller, recorder, video, 0, 50);
    check(!recorder.succeeded, @"zero thumbnail width is rejected");
    request(controller, recorder, video, INT_MAX, 51);
    check(!recorder.succeeded, @"oversized thumbnail width is rejected");
    controller.thumbnailCount = 0;
    request(controller, recorder, video, 240, 52);
    check(!recorder.succeeded, @"zero thumbnail count is rejected");
    controller.thumbnailCount = NSIntegerMax;
    request(controller, recorder, video, 240, 53);
    check(!recorder.succeeded, @"oversized thumbnail count is rejected");

    controller.thumbnailCount = 1000;
    [recorder.generations removeAllObjects];
    [controller generateThumbnailForFile:video thumbWidth:240 generation:100];
    // Let the worker enter real decoding without servicing the main callback queue.
    [NSThread sleepForTimeInterval:0.04];
    CFTimeInterval cancellationStart = CACurrentMediaTime();
    [controller cancelThumbnailGeneration];
    controller.thumbnailCount = 2;
    request(controller, recorder, video, 240, 101);
    check(CACurrentMediaTime() - cancellationStart < 4, @"running 4K work cancels promptly before replacement work");
    check(![recorder.generations containsObject:@100], @"cancelled decode does not publish stale completion");

    [recorder.generations removeAllObjects];
    [controller generateThumbnailForFile:video thumbWidth:0 generation:200];
    [NSThread sleepForTimeInterval:0.05];
    [controller cancelThumbnailGeneration];
    spinUntil(^BOOL { return recorder.generations.count > 0; }, 0.1);
    check(recorder.generations.count == 0, @"cancellation also suppresses an already queued main-thread completion");
    [controller cancelThumbnailGeneration];
    recorder.thumbnails = nil;
    __weak FFmpegController *weakController = controller;
    controller = nil;
    check(spinUntil(^BOOL { return weakController == nil; }, 1), @"completed operation does not retain the decoder forever");
    printf("Thumbnail decoder: %lu checks passed.\n", (unsigned long)checks);
  }
  return 0;
}
