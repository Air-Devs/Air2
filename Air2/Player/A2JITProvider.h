//
//  A2JITProvider.h
//  Air2
//
//  Player —— JIT【取得路径】的协议与类型：四类可插拔 Provider。
//
//  设计（见 docs/JIT-PROVISIONING.md「状态机与 Provider 设计」、ADR-008）：
//    · 本协议只表达四件事：这条取得路径【能不能用】/ 配对材料【就绪否】/
//      【取配对】/【开 JIT】。
//    · ★不含任何平台细节★（无 XPC、无隧道、无 sysctl、无 canOpenURL）：
//      本机环境事实由 A2JITFacts 注入；真机机制（配对解析、LocalDevVPN 隧道、
//      附加/分离调试器）第二阶段经 Bridge 落到 Natives/Support，用同一协议注入。
//    · 四个实现（本单只落【占位 + 能力检测】，真实机制第二阶段接）：
//        A2JITAutomaticPairingProvider  ① 设备内自动配对（iOS 27+，自研 RPPairing）
//        A2JITImportedPairingProvider   ② 导入配对文件（iOS 17.4+）
//        A2JITExternalToolProvider      ③ 外部工具（stikdebug:// 等）
//        A2JITKernelJITProvider         ④ 内核级 JIT（越狱 / TrollStore / dynamic-codesigning）
//
//  分层：本文件属 Player（只编排、不跨界）。边界见 docs/ARCHITECTURE.md。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 按系统分级选出的 JIT 策略（分级表见 docs/JIT-PROVISIONING.md）。
typedef NS_ENUM(NSInteger, A2JITStrategy) {
    A2JITStrategyUnavailable      = 0,  ///< 无可用路径（纯签名 iOS 17.0–17.3）
    A2JITStrategyBuiltInManual    = 1,  ///< iOS 26：内置手动（导入配对 → 连 LocalDevVPN → 内置开启）
    A2JITStrategyAutomatic        = 2,  ///< iOS 27+：设备内自动配对（不导入、不用外部工具）
    A2JITStrategyImportedExternal = 3,  ///< iOS 17.4–25：导入配对文件 + 外部工具
    A2JITStrategyKernel           = 4,  ///< iOS 16- / 越狱 / TrollStore：内核级 JIT（不靠外部调试器）
};

/// 四类取得路径的身份。★顺序即「自动 → 导入 → 外部 → 内核」的推荐优先级★。
typedef NS_ENUM(NSInteger, A2JITProviderKind) {
    A2JITProviderKindAutomaticPairing = 0,  ///< ① 设备内自动生成配对文件
    A2JITProviderKindImportedPairing  = 1,  ///< ② 用户导入配对文件
    A2JITProviderKindExternalTool     = 2,  ///< ③ 外部工具（StikDebug / SideStore…）
    A2JITProviderKindKernel           = 3,  ///< ④ 内核级 JIT（越狱 / TrollStore）
};

/// Provider 层统一的错误 domain（占位实现用可读原因，第二阶段替换为真实错误）。
FOUNDATION_EXPORT NSString *const A2JITProviderErrorDomain;

/// 构造一个「能力已检测、机制尚未接入」的错误（占位实现统一用它，便于日志分流）。
FOUNDATION_EXPORT NSError *A2JITProviderNotImplementedError(NSString *reason);

/// 【注入点】单条 JIT 取得路径。
///
/// UI / 编排层只面对本协议；真机实现经 Bridge 落到 Natives/Support。
/// ★所有属性都应当是【对 A2JITFacts 的纯读取】★，不得在此处发起平台调用。
@protocol A2JITProvider <NSObject>

@required

/// 本条路径的身份。
@property (nonatomic, readonly) A2JITProviderKind kind;

/// 展示名（诊断 / UI 文案用）。
@property (nonatomic, readonly, copy) NSString *displayName;

/// 能力检测：本机环境下这条路径【能不能用】（★只看能力，不看是否已配对★）。
@property (nonatomic, readonly) BOOL isAvailable;

/// 配对材料是否已就绪（配对文件 / 外部工具 / 无需配对的直启环境）。
@property (nonatomic, readonly) BOOL isPairingReady;

/// 取得配对材料。★本单为占位★：未接入时返回 NO 并给出可读原因，编排层据此降级到下一条路径。
- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error;

/// 为当前进程开启 JIT。★本单为占位★：未接入时返回 NO 并给出可读原因。
- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error;

@optional

/// 需要用户动作时的指引（如外部工具的 URL scheme 或「去设置导入」）；无则返回 nil。
@property (nonatomic, readonly, copy, nullable) NSString *userActionHint;

@end

NS_ASSUME_NONNULL_END
