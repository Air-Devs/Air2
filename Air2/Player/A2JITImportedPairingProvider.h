//
//  A2JITImportedPairingProvider.h
//  Air2
//
//  Player —— 取得路径 ②：【导入配对文件】（iOS 17.4+）。
//
//  语义（用户拍板 / ADR-008）：
//    · iOS 26：【内置手动】—— 导入配对文件 → 连 LocalDevVPN → 在本 App 内开启 JIT；
//    · iOS 17.4–25：导入配对文件后仍需【外部工具】完成开启（本 Provider 会返回未接入并让编排层降级）。
//  ★本单只落能力检测与占位★：UIDocumentPicker 导入 UI 与文件校验第二阶段接入。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ② 导入配对文件（iOS 17.4+）。
@interface A2JITImportedPairingProvider : NSObject <A2JITProvider>

/// 注入本机环境事实。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

@end

NS_ASSUME_NONNULL_END
