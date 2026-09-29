//
//  ObjcUtils.m
//  iina
//
//  Created by lhc on 16/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "iina-Bridging-Header.h"
#import "ObjcUtils.h"

#import <stdint.h>

#define INDEL_WEIGHT 1
#define SUBSTITUTION_WEIGHT 4

static inline NSUInteger min(NSUInteger a, NSUInteger b, NSUInteger c) {
  NSUInteger m = a;
  if (b < m) m = b;
  if (c < m) m = c;
  return m;
}

@implementation ObjcUtils

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
  @try {
    tryBlock();
    return YES;
  }
  @catch (NSException *exception) {
    *error = [[NSError alloc] initWithDomain:exception.name code:0 userInfo:exception.userInfo];
    return NO;
  }
}

+ (BOOL)silenced:(void(^)(void))tryBlock {
  @try {
    tryBlock();
    return YES;
  }
  @catch (NSException *exception) {
    return NO;
  }
}

+ (NSUInteger)levDistance:(NSString *)str0 and:(NSString *)str1 {
  // Match Unicode scalars, as before, rather than UTF-16 code units or graphemes.
  // Explicit byte lengths avoid depending on an NSData buffer's null termination.
  NSData *data0 = [str0 dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
  NSData *data1 = [str1 dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
  if (!data0 || !data1) return NSUIntegerMax;
  const uint32_t *cstr0 = data0.bytes;
  const uint32_t *cstr1 = data1.bytes;
  NSUInteger len0 = data0.length / sizeof(uint32_t);
  NSUInteger len1 = data1.length / sizeof(uint32_t);

  // Shared release/series names contribute no distance. Trim only exact scalars;
  // canonical-equivalence and weighted substitution behavior remain unchanged.
  while (len0 && len1 && *cstr0 == *cstr1) {
    ++cstr0;
    ++cstr1;
    --len0;
    --len1;
  }
  while (len0 && len1 && cstr0[len0 - 1] == cstr1[len1 - 1]) {
    --len0;
    --len1;
  }
  if (!len0) return len1 * INDEL_WEIGHT;
  if (!len1) return len0 * INDEL_WEIGHT;

  // Keep a single row for the shorter name. The previous implementation used a
  // quadratic matrix and traversed it column-first, defeating cache locality.
  if (len0 > len1) {
    const uint32_t *temporary = cstr0;
    cstr0 = cstr1;
    cstr1 = temporary;
    NSUInteger length = len0;
    len0 = len1;
    len1 = length;
  }
  if (len0 >= NSUIntegerMax / sizeof(NSUInteger)) return NSUIntegerMax;
  NSUInteger *row = malloc(sizeof(NSUInteger) * (len0 + 1));
  if (!row) return NSUIntegerMax;
  for (NSUInteger i = 0; i <= len0; ++i) row[i] = i * INDEL_WEIGHT;
  for (NSUInteger j = 1; j <= len1; ++j) {
    NSUInteger diagonal = row[0];
    row[0] = j * INDEL_WEIGHT;
    for (NSUInteger i = 1; i <= len0; ++i) {
      NSUInteger above = row[i];
      row[i] = min(row[i - 1] + INDEL_WEIGHT, above + INDEL_WEIGHT,
                   diagonal + (cstr0[i - 1] == cstr1[j - 1] ? 0 : SUBSTITUTION_WEIGHT));
      diagonal = above;
    }
  }
  NSUInteger result = row[len0];
  free(row);
  return result;
}

@end
