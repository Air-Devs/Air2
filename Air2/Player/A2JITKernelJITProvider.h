//
//  A2JITKernelJITProvider.h
//  Air2
//
//  Player —— 取得路径 ④：【内核级 JIT】（iOS 16- / 越狱 / TrollStore）。
//
//  语义（用户拍板 / ADR-008）：iOS 16 及更早、越狱、TrollStore 走【内核级 JIT】——
//  不靠外部调试器、不需要配对文件；能力来自越狱机制 / TrollStore 的 JIT 授予 /
//  签名带的 dynamic-codesigning。
//  ★本单只落能力检测与占位★：真实启用与「本进程真的能用 JIT」的复验第二阶段接入
//  （复用 Natives/Support/A2JITEnvironment 的区域取证判据）。
//
//  ★不要把「环境能提供 JIT」当「本进程现在能用 JIT」★（见 A2JITEnvironment）：
//  越狱识别只用于【选路径】，就绪判据必须是真实能力。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ④ 内核级 JIT（越狱 / TrollStore / dynamic-codesigning）。
@interface A2JITKernelJITProvider : NSObject <A2JITProvider>

/// 注入本机环境事实。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

@end

NS_ASSUME_NONNULL_END
