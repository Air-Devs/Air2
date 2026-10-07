//
//  A2JITExternalToolProvider.h
//  Air2
//
//  Player —— 取得路径 ③：【外部工具】（iOS 17.4+ 兜底）。
//
//  语义（用户拍板 / ADR-008）：iOS 17 / 18 走「导入配对文件 + 外部工具」；
//  外部工具（StikDebug / SideStore / iLoader…）既可能【生成配对文件】，
//  也可能直接【开启 JIT】（经 URL scheme，如 stikdebug:// / stikjit:// / sidestore://）。
//  ★本单只落能力检测与占位★：URL scheme 拉起与有界等待第二阶段接入。
//
//  ★合规★：本 Provider 只走【外部 App 的 URL scheme】——不 vendor、不派生其代码
//  （StikDebug 本体为 AGPL-3.0，只可当外部依赖）。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ③ 外部工具（StikDebug / SideStore…）。
@interface A2JITExternalToolProvider : NSObject <A2JITProvider>

/// 注入本机环境事实。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

@end

NS_ASSUME_NONNULL_END
