#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CYNMediaDecoderErrorDomain;

typedef NS_ERROR_ENUM(CYNMediaDecoderErrorDomain, CYNMediaDecoderError) {
  CYNMediaDecoderErrorInvalidInput = 1,
  CYNMediaDecoderErrorUnsupported = 2,
  CYNMediaDecoderErrorDecode = 3,
  CYNMediaDecoderErrorCancelled = 4,
  CYNMediaDecoderErrorResourceLimit = 5,
};

@interface CYNMediaInfo : NSObject
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double frameRate;
@property(nonatomic, readonly) BOOL hasVideo;
@property(nonatomic, readonly) BOOL hasAudio;
@property(nonatomic, readonly) NSInteger rotationDegrees;
@property(nonatomic, readonly) NSInteger audioSampleRate;
@property(nonatomic, readonly) NSInteger audioChannels;
@property(nonatomic, readonly, copy) NSString *videoCodec;
@property(nonatomic, readonly, copy) NSString *audioCodec;
// Container inventory includes all streams, including attached video pictures.
@property(nonatomic, readonly) NSInteger videoStreamCount;
@property(nonatomic, readonly) NSInteger audioStreamCount;
@property(nonatomic, readonly) NSInteger subtitleStreamCount;
@property(nonatomic, readonly) NSInteger attachedPictureStreamCount;
@property(nonatomic, readonly) NSInteger chapterCount;
// FFmpeg container indices, not mpv track IDs. -1 means no selected stream.
@property(nonatomic, readonly) NSInteger selectedVideoStreamIndex;
@property(nonatomic, readonly) NSInteger selectedAudioStreamIndex;
// Unknown SAR remains 0/1 with zero display dimensions, never fabricated 1/1.
@property(nonatomic, readonly) BOOL sampleAspectRatioKnown;
@property(nonatomic, readonly) NSInteger sampleAspectNumerator;
@property(nonatomic, readonly) NSInteger sampleAspectDenominator;
// Unrotated display size after applying the selected stream's validated SAR.
@property(nonatomic, readonly) double displayWidth;
@property(nonatomic, readonly) double displayHeight;
// Codec code-point names only, never arbitrary media titles or metadata values.
@property(nonatomic, readonly, copy) NSString *videoTransfer;
@property(nonatomic, readonly) BOOL hasStaticHDRMetadata;
@property(nonatomic, readonly) BOOL isHDR;
@end

@interface CYNMediaSample : NSObject
// The sample owns its buffer. Retain it before releasing this object if needed.
@property(nonatomic, readonly) CMSampleBufferRef sampleBuffer;
@property(nonatomic, readonly, getter=isVideo) BOOL video;
@property(nonatomic, readonly) BOOL videoToolboxDecoded;
// True only when the FFmpeg path requires hardware. False may mean unknown:
// FFmpeg 7 HEVC requests hardware but permits a VideoToolbox software fallback.
@property(nonatomic, readonly) BOOL hardwareDecoded;
@end

// All methods except cancel must run on one serial worker queue. Never wait for
// this decoder on the main thread. Cancellation is terminal until a new instance
// is created; openURL does not reset a concurrent cancellation request.
// Native video accepts 8/10-bit 4:2:0 YUV only. Hardware output must match the
// original source depth, range and chroma; unsupported formats are not reduced.
// Unrepresentable, partial or malformed HDR metadata is an explicit error.
@interface CYNMediaDecoder : NSObject
- (nullable CYNMediaInfo *)openURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(open(_:)) __attribute__((swift_error(nonnull_error)));
// A nil sample with no error means fully drained EOF, never temporary EAGAIN.
- (nullable CYNMediaSample *)readSampleWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(readSample()) __attribute__((swift_error(nonnull_error)));
- (BOOL)seekToSeconds:(double)seconds error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(seek(to:));
- (void)cancel;
- (void)close;
@end

NS_ASSUME_NONNULL_END
