import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/ObjcUtils.m"), encoding: .utf8)
let header = try String(contentsOf: root.appendingPathComponent("iina/ObjcUtils.h"), encoding: .utf8)
guard let constantsStart = source.range(of: "#define INDEL_WEIGHT")?.lowerBound,
      let constantsEnd = source.range(of: "@implementation ObjcUtils")?.lowerBound,
      let methodStart = source.range(of: "+ (NSUInteger)levDistance:")?.lowerBound,
      let methodEnd = source.range(of: "@end", range: methodStart..<source.endIndex)?.lowerBound,
      let declaration = header.components(separatedBy: "\n").first(where: { $0.hasPrefix("+ (NSUInteger)levDistance:") }) else {
  fatalError("Production edit-distance extraction boundaries changed")
}
let generatedHeader = """
#import <Foundation/Foundation.h>
@interface ObjcUtils : NSObject
\(declaration)
@end
"""
let generatedSource = """
#import "EditDistance.h"
#import <wchar.h>
\(source[constantsStart..<constantsEnd])
@implementation ObjcUtils
\(source[methodStart..<methodEnd])
@end
"""
try generatedHeader.write(to: output.appendingPathComponent("EditDistance.h"), atomically: true, encoding: .utf8)
try generatedSource.write(to: output.appendingPathComponent("EditDistance.m"), atomically: true, encoding: .utf8)
