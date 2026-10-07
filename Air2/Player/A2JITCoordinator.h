//
//  A2JITCoordinator.h
//  Air2
//
//  Player —— JIT【供给编排】入口：把「配对 → 开启」的状态机与启动流程串起来。
//
//  分层关系（见 docs/ARCHITECTURE.md 依赖方向 App → UI → Player → Core → Bridge → Natives）：
//    · 本类只表达【状态与优先级】，不含平台/网络细节：配对生成、文件导入、隧道探测、
//      附加调试器都由注入的 A2JITProvider（协议）完成；本机事实由 A2JITFacts 注入。
//    · 真机实现经 Bridge 落到 Natives/Support；UI 只面对本类与协议。
//    · ★不新增全局可变单例★ —— 由 App 装配处（DependencyContainer）创建并注入。
//
//  状态机（★先按系统版本选策略，再在策略内推进★）：
//
//      等待配对 ──(取配对)──▶ 已配对 ──(开启)──▶ 等待开启 ──▶ 已启用
//          ▲                                          │
//          └────────────── 不可用（带原因枚举）◀───────┘
//
//  [JIT-IMPL] 状态与原因枚举、合法迁移表已抽到 A2JITStateMachine.h（纯逻辑、可单测）；
//  本类持有一台状态机，settle: 改为「先过状态机（非法迁移被拒）再落状态」。
//
//  与既有 A2LaunchChain 的分工：
//    · A2JITCoordinator 负责【取得 JIT】：配对材料就绪 → 开启 → 进程获得 JIT；
//    · A2LaunchChain 负责【用完 JIT 建 VM】：① 下发脚本 → ② 探测 → ③ 建 JVM。
//    本单只接【一个钩子】prepareJITThenRunLaunchChain:error: —— 先确保 JIT 已启用，
//    再把控制权交给 A2LaunchChain，★不修改 A2LaunchChain 的任何公开行为★。
//
//  分级策略与取得路径优先级（见 docs/JIT-PROVISIONING.md；用户拍板 / ADR-008）：
//    · iOS 26    ：内置手动（导入配对 → 连 LocalDevVPN → 内置开启）
//    · iOS 27+   ：设备内自动配对（自研 RPPairing）
//    · iOS 17/18 ：导入配对文件 + 外部工具
//    · iOS 16- / 越狱 / TrollStore：内核级 JIT
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITStateMachine.h"   // [JIT-IMPL] A2JITState / A2JITFailureReason 定义处

NS_ASSUME_NONNULL_BEGIN

@class A2JITFacts;
@class A2LaunchChain;
@class A2JITStateMachine;

/// JIT 编排器：按系统分级选择策略，在策略内按优先级推进状态。
@interface A2JITCoordinator : NSObject

/// 当前状态。
@property (nonatomic, readonly) A2JITState state;

/// 当前/最近失败原因（正常态为 A2JITFailureReasonNone）。
@property (nonatomic, readonly) A2JITFailureReason failureReason;

/// 状态的可读说明（用于 UI 展示与诊断；正常态为短句，失败态含原因）。
@property (nonatomic, readonly, copy) NSString *statusDetail;

/// 本次选中的分级策略。
@property (nonatomic, readonly) A2JITStrategy strategy;

/// 是否已选出可用的取得路径。
@property (nonatomic, readonly) BOOL hasActiveProvider;

/// 选中的取得路径（hasActiveProvider 为 NO 时无意义）。
@property (nonatomic, readonly) A2JITProviderKind activeProviderKind;

/// 是否已就绪到可以进入 A2LaunchChain 建 VM。★仅 Enabled 时为 YES★。
@property (nonatomic, readonly) BOOL readyToRunGame;

/// 构造：注入本机事实与四路 Provider（真机实现经 Bridge 落到 Natives/Support）。
/// ★构造后立即评估一次状态★。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                    providers:(NSArray<id<A2JITProvider>> *)providers;

/// 装配便利：按默认四路 Provider 构造（App 装配处调用；★非单例★）。
+ (NSArray<id<A2JITProvider>> *)defaultProvidersWithFacts:(A2JITFacts *)facts;

/// 重新评估环境并推进状态（★不触发 JIT 开启★）。用于设置页出现 / App 回前台。
- (void)refreshState;

/// 取得配对材料并推进到已配对（按策略内的 Provider 优先级）。
- (BOOL)acquirePairingWithError:(NSError *_Nullable *_Nullable)error;

/// 开启 JIT：已配对 → 等待开启 → 已启用。
- (BOOL)enableJITWithError:(NSError *_Nullable *_Nullable)error;

/// ★「先 JIT 后启 JVM」钩子★：确保 JIT 已启用后，把控制权交给 A2LaunchChain；
/// 未就绪则【不运行启动链】（绝不带病建 VM，否则首帧 JIT 取指 SIGBUS）。
- (BOOL)prepareJITThenRunLaunchChain:(A2LaunchChain *)chain
                               error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
