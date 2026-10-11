//
//  A2JITKernelJITProvider.h
//  Air2
//
//  Player —— 取得路径 ④：【内核级 JIT】（iOS 16- / 越狱 / TrollStore）。
//
//  语义（用户拍板 / ADR-009）：iOS 16 及更早、越狱、TrollStore 走【内核级 JIT】——
//  不靠外部调试器、不需要配对文件；能力来自越狱机制 / TrollStore 的 JIT 授予 /
//  签名带的 dynamic-codesigning。
//
//  [JIT-IMPL-2] 本单只接【复验】，不做启用：
//    · `activateJITWithError:` 改为真调判据内核（注入的 A2JITReadinessProbe），
//      按 A2JITRegionVerdict 如实回答「本进程现在到底能不能用 JIT」；
//    · ★不做★「内核级 JIT 的真实启用」（越狱/TrollStore 的自开机制，本单明确不做）。
//
//  ★不要把「环境能提供 JIT」当「本进程现在能用 JIT」★（见 A2JITEnvironment）：
//  越狱识别只用于【选路径】，就绪判据必须是真实能力。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITReadinessProbe.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ④ 内核级 JIT（越狱 / TrollStore / dynamic-codesigning）。
@interface A2JITKernelJITProvider : NSObject <A2JITProvider>

/// 注入本机环境事实（probe = nil ⇒ 只回答能力，不回答真实可用性）。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

/// ★装配用★：注入判据内核（真机 = Bridge/A2JITEnvironmentProbe）。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                        probe:(nullable id<A2JITReadinessProbe>)probe;

/// ★真调判据★：有界复验「本进程现在能不能用 JIT」。
- (BOOL)refreshReadinessWithBudget:(NSTimeInterval)budget
                          evidence:(NSString *_Nullable *_Nullable)evidenceOut;

/// 最近一次复验的区域判定（无 probe 时为 Unknown）。
@property (nonatomic, readonly) A2JITReadinessVerdict lastVerdict;
/// 最近一次复验的取证摘要（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *lastEvidence;

@end

NS_ASSUME_NONNULL_END
