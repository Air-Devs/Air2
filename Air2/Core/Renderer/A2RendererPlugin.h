//
//  A2RendererPlugin.h
//  Air2
//
//  渲染器插件 —— 从 zip 导入、解析、注册。
//
//  设计目标：导入一个 .air2plugin（zip）后，渲染器自动出现在
//  「设置 → 渲染」里，不需要重启、不需要改代码。
//
//  与 FCL 的关系：
//    FCL 的插件是独立 APK，Android 可以扫描已安装应用来发现。
//    iOS 没有这个概念（沙箱 + 代码签名），所以改成「导入 zip」。
//    但 manifest 的 env 部分【完全兼容 FCL 的 v2 格式】——
//    渲染器作者的配置可以基本复用，只需把 .so 重编成 .dylib。
//
//  ⚠️ iOS 的签名限制：
//    导入的 dylib 只有在 TrollStore / 越狱环境下才能直接 dlopen。
//    正常签名环境下会返回 "code signature invalid" ——
//    我们仍然允许导入并列出，但标记为不可用并给出准确原因，
//    而不是让用户面对一个静默失败的选项。
//

#import <Foundation/Foundation.h>
#import "A2RendererLibraryLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// 渲染器可用状态
typedef NS_ENUM(NSInteger, A2RendererAvailability) {
    A2RendererAvailabilityUnknown = 0,
    A2RendererAvailabilityAvailable,      ///< 可以 dlopen
    A2RendererAvailabilityMissingLib,     ///< 文件不存在
    A2RendererAvailabilitySignatureInvalid,///< 代码签名无效（正常签名环境）
    A2RendererAvailabilityArchitectureMismatch, ///< 架构不匹配（x86 库等）
    A2RendererAvailabilityMissingDependency,    ///< 缺依赖库
};

#pragma mark - 环境变量配置项

/// 环境变量的类型（对应 FCL v2 的四种 EnvV2）
typedef NS_ENUM(NSInteger, A2RendererEnvType) {
    A2RendererEnvTypeNormal = 0,      ///< 固定值，用户不可改
    A2RendererEnvTypeToggleable,      ///< 开关
    A2RendererEnvTypeSelectable,      ///< 单选
    A2RendererEnvTypeCustomizable,    ///< 自由输入
};

@interface A2RendererEnvSpec : NSObject
@property (nonatomic, assign) A2RendererEnvType type;
@property (nonatomic, copy) NSString *key;
/// NormalEnv 的固定值 / ToggleableEnv 打开时的值
@property (nonatomic, copy, nullable) NSString *value;
/// 显示标题（Toggleable / Selectable / Customizable 用）
@property (nonatomic, copy, nullable) NSString *title;
/// Toggleable：默认是否开启
@property (nonatomic, assign) BOOL defaultOn;
/// Selectable：默认选中项
@property (nonatomic, copy, nullable) NSString *defaultValue;
/// Selectable：可选值列表 [{value, label}]
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *selectableValues;
/// Customizable：默认值
@property (nonatomic, copy, nullable) NSString *customDefault;

/// 根据用户当前设置，算出这个环境变量应该输出什么。
/// 返回 nil 表示不设置。
- (nullable NSString *)resolvedValueWithUserSettings:(NSDictionary<NSString *, id> *)settings;
@end

#pragma mark - 渲染器插件

@interface A2RendererPlugin : NSObject

// ---- manifest 字段 ----
@property (nonatomic, assign) NSInteger formatVersion;
@property (nonatomic, copy) NSString *rendererID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *pluginDescription;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy, nullable) NSString *homepage;

/// 库的布局形态。manifest 里用 "libraryLayout" 字段声明：
///   "combined"  —— GL 与 EGL 在同一个 dylib（MobileGlues / NG-GL4ES）
///   "separate"  —— 两个独立 dylib（Zink / VirGL）
///   "glOnly"    —— 只有 GL
/// 缺省时自动推断：eglPath 为空或等于 glPath → combined，否则 separate。
@property (nonatomic, assign) A2RendererLibraryLayout libraryLayout;

@property (nonatomic, copy) NSString *rendererGLPath;   ///< 相对包根
/// EGL 库。libraryLayout 为 combined 时可留空（表示与 GL 同一个文件）。
@property (nonatomic, copy) NSString *rendererEGLPath;
@property (nonatomic, copy) NSArray<NSString *> *dlopenLibPaths;
@property (nonatomic, copy, nullable) NSString *minMCVer;
@property (nonatomic, copy, nullable) NSString *maxMCVer;
@property (nonatomic, copy) NSArray<A2RendererEnvSpec *> *envSpecs;

// ---- iOS 扩展 ----
@property (nonatomic, copy, nullable) NSString *minSystemVersion;
@property (nonatomic, assign) BOOL requiresJIT;
@property (nonatomic, copy, nullable) NSString *iosNotes;

// ---- 运行时状态 ----
/// 插件解压后的目录
@property (nonatomic, copy, readonly) NSString *installPath;
/// 是否可用
@property (nonatomic, assign, readonly) A2RendererAvailability availability;
/// 不可用原因（给用户看的人话）
@property (nonatomic, copy, nullable, readonly) NSString *unavailableReason;
/// 图标路径（可选）
@property (nonatomic, copy, nullable, readonly) NSString *iconPath;
/// 是否为用户导入（false = 内置）
@property (nonatomic, assign, readonly, getter=isImported) BOOL imported;

/// GL / EGL 库的绝对路径
@property (nonatomic, copy, readonly) NSString *absoluteGLPath;
@property (nonatomic, copy, readonly) NSString *absoluteEGLPath;

/// 从 manifest JSON 构造（不做文件校验）
+ (nullable instancetype)pluginWithManifest:(NSDictionary *)json
                                installPath:(NSString *)installPath;

/// 校验文件并探测能否 dlopen。会更新 availability 与 unavailableReason。
- (void)validate;

/// 检查 Mach-O 是否导出指定符号 —— **纯静态，不执行任何库代码**。
///
/// ⚠️ 不要用 dlopen 做"能否加载"的探测：
///   dlopen 会执行库的 constructor，而 GL 库的 constructor
///   通常假设 EGL 上下文已就绪 —— 探测阶段没有那个环境，
///   会直接 SIGSEGV。（实测：导入 MobileGlues 崩在 init_target_egl）
+ (BOOL)machO:(NSString *)path
    exportsSymbol:(const char *)symbolName
          missing:(NSString * _Nullable * _Nullable)missing;

@end

NS_ASSUME_NONNULL_END
