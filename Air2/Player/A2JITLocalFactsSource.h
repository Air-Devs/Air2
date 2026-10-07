//
//  A2JITLocalFactsSource.h
//  Air2
//
//  Player —— 本机事实的【薄探测适配器】（阶段一实现 A2JITFactsSource）。
//
//  [JIT-IMPL] 说明与边界：
//    · 只用 Foundation 公开 API（NSProcessInfo / NSFileManager），★无 UIKit、无私有 API★；
//    · 只读「能安全读到」的判据：系统版本、越狱文件特征、沙盒内配对文件是否存在；
//    · 完整探测（TrollStore 识别、get-task-allow / dynamic-codesigning 取证、
//      外部工具 canOpenURL 探测）需要 UIKit / Security / Natives 能力，
//      按 docs/ARCHITECTURE.md 归 App 装配处 + Natives/Support，属第二阶段，
//      本类对取不到的字段一律返回【保守值】（NO），绝不猜测成 YES。
//    · 越狱识别只用于【选路径】，就绪判据仍以真实能力为准（ADR-006 铁律）。
//
//  用途：设置页 JIT 面板先有可运行的事实来源；单测则注入假 source（本类不参与单测）。
//

#import <Foundation/Foundation.h>
#import "A2JITFacts.h"

NS_ASSUME_NONNULL_BEGIN

/// 本机事实的薄探测适配器（Foundation-only）。
@interface A2JITLocalFactsSource : NSObject <A2JITFactsSource>

/// 沙盒内可能落放配对文件的候选路径（探测面宽，返回值窄）。暴露给诊断/单测。
+ (NSArray<NSString *> *)candidatePairingFilePaths;

@end

NS_ASSUME_NONNULL_END
