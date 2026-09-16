#import <Cocoa/Cocoa.h>

@interface FFmpegLogger: NSObject
+ (void)debug:(NSString *)message;
+ (void)warn:(NSString *)message;
+ (void)error:(NSString *)message;
@end
