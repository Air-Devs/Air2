//
//  A2JITFacts.h
//  Air2
//
//  Player —— JIT 决策所需的【本机环境事实】（不可变值对象）。
//
//  为什么要有这一层：Player 只编排、不跨界（见 docs/ARCHITECTURE.md）。
//  版本号、越狱/巨魔形态、配对文件是否存在、外部工具是否可拉起、签名能力
//  （get-task-allow / dynamic-codesigning）这些【平台事实】由 App 装配处从
//  Natives/Support 取好后构造本对象注入；Player 侧只做纯逻辑判定（可单测）。
//
//  ★事实变化（用户导入配对文件、装好外部工具、App 回前台重探）的处置★：
//  由 App 重建 A2JITFacts 与 Provider（或后续给 Coordinator 加 updateFacts:），
//  本单不做热更新。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 运行环境形态（越狱识别的【结果】，不是检测实现）。
typedef NS_ENUM(NSInteger, A2JITEnvironmentKind) {
    A2JITEnvironmentKindPlain      = 0,  ///< 纯签名侧载（AltStore / SideStore 免费签名）
    A2JITEnvironmentKindTrollStore = 1,  ///< TrollStore / 蓝巨魔
    A2JITEnvironmentKindJailbroken = 2,  ///< 越狱（Dopamine / palera1n / Taurine / RootHide…）
};

/// JIT 供给决策所需的本机事实（不可变）。
@interface A2JITFacts : NSObject

/// 主版本号：26 / 27（Apple 新版号）或 16 / 17 / 18。
@property (nonatomic, readonly) NSInteger osMajorVersion;
/// 次版本号（如 17.4 的 4）。
@property (nonatomic, readonly) NSInteger osMinorVersion;
@property (nonatomic, readonly) A2JITEnvironmentKind environment;
/// 沙盒内已存在可用配对文件（多候选路径的探测结果，探测面要宽、返回值要窄）。
@property (nonatomic, readonly) BOOL hasImportedPairingFile;
/// canOpenURL 能拉起外部使能器（stikdebug:// / sidestore:// …）。
@property (nonatomic, readonly) BOOL hasExternalEnablerInstalled;
/// 签名带 get-task-allow（免费签名/开发签名默认具备；内置 helper 的前置）。
@property (nonatomic, readonly) BOOL hasGetTaskAllow;
/// 签名带 dynamic-codesigning（越狱/巨魔常见）。
@property (nonatomic, readonly) BOOL hasDynamicCodesigning;

+ (instancetype)factsWithOSMajorVersion:(NSInteger)majorVersion
                             minorVersion:(NSInteger)minorVersion
                              environment:(A2JITEnvironmentKind)environment
                 hasImportedPairingFile:(BOOL)hasImportedPairingFile
            hasExternalEnablerInstalled:(BOOL)hasExternalEnablerInstalled
                         hasGetTaskAllow:(BOOL)hasGetTaskAllow
                   hasDynamicCodesigning:(BOOL)hasDynamicCodesigning;

/// iOS ≥ 17.4：远程调试式 JIT（配对文件 + 隧道）的最低系统。
- (BOOL)supportsRemoteDebugJIT;

/// iOS ≥ 26：内置 helper（ExtensionKit app extension）可用。
- (BOOL)supportsBuiltInHelper;

/// iOS ≥ 27：设备内自动配对可用。
- (BOOL)supportsAutomaticPairing;

/// 具备内核级 JIT 环境（越狱 / TrollStore / dynamic-codesigning）——不靠外部调试器。
- (BOOL)hasKernelJITEnvironment;

@end

NS_ASSUME_NONNULL_END
