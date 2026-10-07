//
//  A2JITCoordinator.h
//  Air2
//
//  Player —— JIT【供给编排】入口：把「配对 → 开启」的状态机与启动流程串起来。
//
//  分层关系（见 docs/ARCHITECTURE.md 依赖方向 App → UI → Player → Core → Bridge → Natives）：
//    · 本类只表达【状态与优先级】，不含平台/网络细节：真正的配对生成、文件导入、
//      隧道探测、附加调试器都通过注入的 A2JITProvisioning 协议完成。
//    · 真机实现经 Bridge 落到 Natives/Support；UI 只面对本类与协议。
//    · ★不新增全局可变单例★ —— 由 App 装配处（DependencyContainer）创建并注入。
//
//  与既有 A2LaunchChain 的分工：
//    · A2JITCoordinator 负责【取得 JIT】：配对文件就绪 → 开启 → 进程获得 JIT；
//    · A2LaunchChain 负责【用完 JIT 建 VM】：① 下发脚本 → ② 探测 → ③ 建 JVM。
//    启动前先由本类推进到 A2JITStateEnabled，再交给 A2LaunchChain；两者不互相 import。
//
//  取得配对文件的【优先级】（见 docs/DECISIONS.md ADR-007）：
//    ① 设备内自动生成（参考 SideInstaller 思路，自研；需 iOS 27+）
//    ② 用户在设置里导入文件（照 PocketJ；iOS 17.4+）
//    ③ 外部工具（StikDebug / SideStore / iLoader…）
//
//  文档：docs/DECISIONS.md（ADR-006 传统 0x69 回退 / ADR-007 内置 JIT 工作流）、
//        docs/DEPENDENCIES.md（JIT 供给候选依赖，许可证待核实）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// JIT 供给状态机。
///
/// 串起「配对 → 开启」，与 PocketJ Launcher 的 `PocketJJITSetupState`
/// （等待配置 / 就绪 / 已启用 / 不可用）同构；差别是把「配对」从「就绪」里单独拆出，
/// 以承载「自动 / 导入 / 外部」三条取得路径。
typedef NS_ENUM(NSInteger, A2JITState) {
    A2JITStateUnavailable       = 0,  ///< 不可用：系统过低（< iOS 17.4）或签名缺 get-task-allow 且无外部工具
    A2JITStateWaitingPairing    = 1,  ///< 等待配对：尚无本机配对文件
    A2JITStatePaired            = 2,  ///< 已配对：配对文件就绪（自动生成 / 用户导入 / 外部工具）
    A2JITStateWaitingActivation = 3,  ///< 等待开启：已配对 + 隧道/DDI 就绪，尚未附加调试器
    A2JITStateEnabled           = 4,  ///< 已启用：本进程已获得 JIT
};

/// 配对文件的取得路径。★枚举顺序即优先级（0 最高）★。
typedef NS_ENUM(NSInteger, A2JITPairingSource) {
    A2JITPairingSourceAutomatic = 0,  ///< ① 设备内自动生成（参考 SideInstaller 思路，自研；iOS 27+ 可行）
    A2JITPairingSourceImported  = 1,  ///< ② 用户在设置里导入文件（照 PocketJ；iOS 17.4+）
    A2JITPairingSourceExternal  = 2,  ///< ③ 外部工具（StikDebug / SideStore / iLoader…）
};

/// 【注入点】JIT 供给后端。
///
/// UI / 编排层只面对本协议；真机实现经 Bridge 落到 Natives/Support。
/// ★本协议不含任何 UIKit / 网络细节★，也不感知版本 / 账号。
@protocol A2JITProvisioning <NSObject>

@required

/// 系统是否支持远程配对式 JIT（iOS ≥ 17.4 且允许 Debug JIT 的镜像）。
- (BOOL)isSystemSupported;

/// 当前是否已有可用配对文件。
- (BOOL)hasPairingFile;

/// 隧道是否可达（Loopback 路由就绪，通常经 LocalDevVPN → 10.7.0.1:49152）。
- (BOOL)isTunnelReachable;

/// 为本进程开启 JIT（附加/分离调试器）；返回 YES 即代表 JIT 已就绪。
- (BOOL)enableJITForCurrentProcessWithError:(NSError *_Nullable *_Nullable)error;

@optional

/// ① 设备内自动生成配对文件。未实现的能力无需实现本方法，编排层会自动降级到 ②。
- (BOOL)generatePairingFileWithError:(NSError *_Nullable *_Nullable)error;

/// ② 导入用户提供的配对文件（`.plist` / `.mobiledevicepairing`）。
- (BOOL)importPairingFileAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;

@end

/// JIT 编排器：维护 A2JITState 并按优先级取得配对、开启 JIT。
@interface A2JITCoordinator : NSObject

/// 当前状态。
@property (nonatomic, readonly) A2JITState state;

/// 状态的可读说明（用于 UI 展示与诊断；成功/正常态为短句，失败态含原因）。
@property (nonatomic, readonly, copy) NSString *statusDetail;

/// 是否已就绪到可以进入 A2LaunchChain 建 VM。★仅 Enabled 时为 YES★。
@property (nonatomic, readonly) BOOL readyToRunGame;

/// 构造：注入供给后端（真机实现经 Bridge 落到 Natives/Support）。
- (instancetype)initWithProvisioning:(id<A2JITProvisioning>)provisioning;

/// 重新评估环境并推进状态（★不触发 JIT 开启★）。用于设置页出现 / App 回前台。
- (void)refreshState;

/// 按优先级取得配对文件：① 自动生成 → ② 导入给定的 URL → ③ 外部工具（本层只给指引，不接管）。
/// 成功后状态至少推进到 A2JITStatePaired。
- (BOOL)acquirePairingWithImportedURL:(nullable NSURL *)importedURL
                                error:(NSError *_Nullable *_Nullable)error;

/// 开启 JIT：A2JITStatePaired → A2JITStateWaitingActivation → A2JITStateEnabled。
- (BOOL)enableJITWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
