//
//  A2JITExternalToolProvider.h
//  Air2
//
//  Player —— 取得路径 ③：【外部工具】（iOS 17.4+ 兜底）。
//
//  语义（用户拍板 / ADR-009）：iOS 17 / 18 走「导入配对文件 + 外部工具」；
//  外部工具（StikDebug / SideStore / iLoader…）既可能【生成配对文件】，
//  也可能直接【开启 JIT】（经 URL scheme，如 stikdebug://）。
//
//  [JIT-IMPL-2] 本单把「占位」换成真实现：
//    · isAvailable ⇒ ★工具未安装就整条路径不可用★（编排层不再尝试、设置页置灰写「未安装」）；
//    · activateJITWithError: ⇒ ★拉起（URL scheme）→ 有界等待 + 轮询判据★：
//      轮询注入的 A2JITReadinessProbe（真机 = Bridge → Natives/A2JITEnvironment），
//      超时即【明确失败】（绝不无限等）。
//
//  ★合规★：本 Provider 只走【外部 App 的 URL scheme】——不 vendor、不派生其代码
//  （StikDebug 本体为 AGPL-3.0，只可当外部依赖）。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITExternalToolLauncher.h"
#import "A2JITReadinessProbe.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ③ 外部工具（StikDebug / SideStore…）。
@interface A2JITExternalToolProvider : NSObject <A2JITProvider>

/// ★已登记的 URL scheme★（探测面宽、返回值窄）。
/// ★必须与 Air2/Info.plist 的 LSApplicationQueriesSchemes 一致★
/// （单测会读 Info.plist 逐项比对，防两处漂移）。
+ (NSArray<NSString *> *)registeredToolSchemes;

/// 某 scheme 的拉起 URL（形如 `stikdebug://enable-jit`）。
+ (nullable NSURL *)launchURLForScheme:(NSString *)scheme;

/// 注入本机环境事实（无拉起器 / 无判据 ⇒ 机制不可用，会如实返回失败）。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

/// ★装配用★：注入拉起器（UIApplication）与判据内核（Bridge probe）+ 等待预算。
/// @param waitBudget   拉起后最多等多久（秒；★超时即失败★）。<=0 时取默认 20s。
/// @param pollInterval 轮询间隔（秒；<=0 时取默认 0.5s）。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                     launcher:(nullable id<A2JITExternalToolLauncher>)launcher
                        probe:(nullable id<A2JITReadinessProbe>)probe
                   waitBudget:(NSTimeInterval)waitBudget
                 pollInterval:(NSTimeInterval)pollInterval;

/// 拉起后的等待预算（秒）。设置页据此提示用户「最多等 N 秒」。
@property (nonatomic, readonly) NSTimeInterval activationWaitBudget;
/// 轮询间隔（秒）。
@property (nonatomic, readonly) NSTimeInterval pollInterval;
/// 最近一次成功拉起的 URL（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSURL *lastLaunchedURL;
/// 最近一次判据 verdict（无 probe 时为 Unknown）。
@property (nonatomic, readonly) A2JITReadinessVerdict lastVerdict;
/// 最近一次取证摘要（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *lastEvidence;

/// 当前实际可拉起的第一条 URL（无拉起器 / 都打不开时返回 nil）。
- (nullable NSURL *)firstLaunchableURL;

@end

NS_ASSUME_NONNULL_END
