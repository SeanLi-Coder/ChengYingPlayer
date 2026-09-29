#import "EditDistance.h"
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <wchar.h>

// Frozen pre-optimization implementation, used as an independent differential oracle.
static NSUInteger referenceDistance(NSString *left, NSString *right) {
  left = [@" " stringByAppendingFormat:@"%@\0", left];
  right = [@" " stringByAppendingFormat:@"%@\0", right];
  NSData *leftData = [left dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
  NSData *rightData = [right dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
  const wchar_t *a = leftData.bytes;
  const wchar_t *b = rightData.bytes;
  size_t rows = wcslen(a), columns = wcslen(b);
  int *matrix = calloc((rows + 1) * (columns + 1), sizeof(int));
  NSCAssert(matrix != NULL, @"Reference allocation must succeed");
  for (size_t i = 1; i <= rows; i++) matrix[i * (columns + 1)] = (int)i;
  for (size_t j = 1; j <= columns; j++) matrix[j] = (int)j;
  for (size_t j = 1; j <= columns; j++) {
    for (size_t i = 1; i <= rows; i++) {
      int insertion = matrix[(i - 1) * (columns + 1) + j] + 1;
      int deletion = matrix[i * (columns + 1) + j - 1] + 1;
      int substitution = matrix[(i - 1) * (columns + 1) + j - 1] + (a[i] == b[j] ? 0 : 4);
      matrix[i * (columns + 1) + j] = MIN(MIN(insertion, deletion), substitution);
    }
  }
  NSUInteger result = matrix[rows * (columns + 1) + columns];
  free(matrix);
  return result;
}

static uint64_t randomState = 0x93aaff017ee10023;
static NSUInteger nextRandom(NSUInteger bound) {
  randomState ^= randomState << 13;
  randomState ^= randomState >> 7;
  randomState ^= randomState << 17;
  return randomState % bound;
}

static NSString *randomName(NSUInteger length) {
  NSArray<NSString *> *alphabet = @[@"a", @"b", @"c", @" ", @"9", @"-", @"中", @"文", @"é", @"e\u0301", @"🎬", @"𐐀"];
  NSMutableString *value = [NSMutableString string];
  for (NSUInteger i = 0; i < length; i++) [value appendString:alphabet[nextRandom(alphabet.count)]];
  return value;
}

static void compare(NSString *left, NSString *right) {
  NSUInteger expected = referenceDistance(left, right);
  NSCAssert([ObjcUtils levDistance:left and:right] == expected, @"Distance must match the original algorithm");
  NSCAssert([ObjcUtils levDistance:right and:left] == expected, @"Distance must remain symmetric");
}

static double benchmark(NSArray<NSArray<NSString *> *> *pairs, BOOL reference, NSUInteger rounds) {
  volatile NSUInteger checksum = 0;
  NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
  for (NSUInteger round = 0; round < rounds; round++) {
    @autoreleasepool {
      for (NSArray<NSString *> *pair in pairs) {
        checksum += reference ? referenceDistance(pair[0], pair[1]) : [ObjcUtils levDistance:pair[0] and:pair[1]];
      }
    }
  }
  NSCAssert(checksum > 0, @"Benchmark work must not be optimized away");
  return (NSProcessInfo.processInfo.systemUptime - start) * 1000;
}

int main(void) {
  @autoreleasepool {
    NSArray<NSString *> *cases = @[@"", @"a", @"b", @"ab", @"ba", @"aaa", @"中文", @"🎬中", @"é", @"e\u0301", @"abcabc", @"abc", @" " ];
    for (NSString *left in cases) for (NSString *right in cases) compare(left, right);
    for (NSUInteger i = 0; i < 4000; i++) {
      compare(randomName(nextRandom(96)), randomName(nextRandom(96)));
    }
    NSString *prefix = [@"SharedSeries-中文-" stringByPaddingToLength:160 withString:@"x" startingAtIndex:0];
    NSString *suffix = [@".2160p.10bit-WEB-DL.zh-Hans" stringByPaddingToLength:60 withString:@"y" startingAtIndex:0];
    NSMutableArray *sharedPairs = [NSMutableArray array];
    NSMutableArray *unrelatedPairs = [NSMutableArray array];
    for (NSUInteger i = 0; i < 100; i++) {
      NSString *left = [NSString stringWithFormat:@"%@%03lu%@", prefix, (unsigned long)i, suffix];
      NSString *right = [NSString stringWithFormat:@"%@%03lu%@", prefix, (unsigned long)(i + 1), suffix];
      compare(left, right);
      [sharedPairs addObject:@[left, right]];
      [unrelatedPairs addObject:@[randomName(180), randomName(180)]];
    }
    for (NSArray *pair in unrelatedPairs) compare(pair[0], pair[1]);
    compare(@"short", [@"long" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0]);
    compare([prefix stringByAppendingString:@"a"], [prefix stringByAppendingString:@"b"]);
    compare([@"a" stringByAppendingString:suffix], [@"b" stringByAppendingString:suffix]);
    printf("PASS: 4372 edit-distance differential cases (both argument orders)\n");
    for (NSArray *workload in @[@[@"shared-filename", sharedPairs], @[@"unrelated-filename", unrelatedPairs]]) {
      // Warm up both implementations, then report the best of three to reduce scheduler noise.
      benchmark(workload[1], YES, 1);
      benchmark(workload[1], NO, 1);
      double referenceMS = DBL_MAX, productionMS = DBL_MAX;
      for (NSUInteger i = 0; i < 3; i++) {
        referenceMS = MIN(referenceMS, benchmark(workload[1], YES, 20));
        productionMS = MIN(productionMS, benchmark(workload[1], NO, 20));
      }
      printf("BENCHMARK %s: reference_ms=%.3f production_ms=%.3f speedup=%.2fx pairs=2000\n",
             [workload[0] UTF8String], referenceMS, productionMS, referenceMS / productionMS);
    }
  }
  return 0;
}
