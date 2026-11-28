//
//  A2RendererDiscovery.h
//  Air2
//
//  渲染器自动发现。
//
//  ## 为什么需要它
//
//  安卓那边装一个 APK，PackageManager 就能枚举出它提供的渲染器，用户在设置页
//  直接看到新选项。iOS 没有等价的包注册机制，所以要自己造一个：
//
//      Android                          Air2
//      ─────────────────────────────    ──────────────────────────────────────
//      install APK                     用户把 .dylib 丢进目录（Filza / 爱思助手）
//      PackageManager 枚举组件         本类扫描固定目录
//      APK 里的 manifest               ① 同名 .json 侧车文件
//                                      ② dylib 内嵌的 air2RendererManifestJSON()
//      装完即出现在列表                 下次进设置页即出现
//
//  ## 安全策略（重要）
//
//  **不轻易 dlopen 未审核的 dylib**。dylib 的 constructor 在 dlopen 时就会执行，
//  一个来路不明的文件可以在用户只是「打开设置页看一眼」的时候拿到任意代码执行。
//
//  所以发现流程是分级的：
//
//    第 1 级：同目录有 <name>.json 侧车文件      → 直接读，不碰 dylib（最安全）
//    第 2 级：dylib 里能搜到 AIR2RENDERER 字样    → 才去 dlopen 读 manifest
//    第 3 级：什么都拿不到                        → 登记成「未识别」，只给文件名，
//                                                  用户可以手动选，参数走默认
//
//  第 3 级也有用：用户明确知道自己在干什么时（例如自己编译的渲染器），
//  就算没写 manifest 也能直接用，这跟安卓侧「没写 manifest 的 APK 装不上」
//  相比反而更宽容。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条被发现出来的渲染器候选。
@interface A2DiscoveredRenderer : NSObject

/// 稳定标识。有 manifest 时取 manifest 里的 rendererID，否则用 dylib 文件名。
@property (nonatomic, copy, readonly) NSString *identifier;
/// 显示名。未识别时就是文件名去掉前缀后缀。
@property (nonatomic, copy, readonly) NSString *displayName;
/// 一句话描述，可为空。
@property (nonatomic, copy, readonly, nullable) NSString *summary;
/// dylib 的绝对路径。
@property (nonatomic, copy, readonly) NSString *libraryPath;

/// 发现来源，用于 UI 分组与排障：
///   "内置"            Frameworks/ 里编译进包的
///   "用户导入"        Documents/Air2/Renderers/ 里通过 zip 导入的
///   "目录"            同一目录下用户手动放进去的
///   "越狱共享目录"    /var/jb/usr/lib/air2-renderers/
@property (nonatomic, copy, readonly) NSString *sourceName;

/// 是否拿到了可信的元数据（第 1/2 级为 YES，第 3 级为 NO）。
@property (nonatomic, assign, readonly) BOOL hasManifest;
/// 已解析的 manifest（若有）。结构同 A2RendererPlugin 的原始 JSON。
@property (nonatomic, copy, readonly, nullable) NSDictionary *manifest;
/// 可信的 MC 版本范围（manifest 里写了才有）。
@property (nonatomic, copy, readonly, nullable) NSString *minMCVersion;
@property (nonatomic, copy, readonly, nullable) NSString *maxMCVersion;

@end


@interface A2RendererDiscovery : NSObject

+ (instancetype)shared;

/// 扫描全部目录，返回去重后的候选列表（按 identifier 去重，先扫到的优先）。
///
/// 扫描顺序（先扫的优先，保证内置不会被同名的外部文件顶掉）：
///   1. Bundle/Frameworks/            （内置）
///   2. Documents/Air2/Renderers/     （导入 + 手动放）
///   3. /var/jb/usr/lib/air2-renderers/  （越狱共享，仅当存在）
- (NSArray<A2DiscoveredRenderer *> *)scan;

/// 带跳过集合的扫描。
///
/// `skipLibraryPaths` 里的路径会**在读取文件之前**被跳过 —— 内置渲染器已经在
/// 注册表里按 dylib 名登记过，没必要再对每个内置库读 256KB 做标记探测。
/// 调用方传进来的是「已知的库绝对路径」。
- (NSArray<A2DiscoveredRenderer *> *)scanSkippingLibraryPaths:(nullable NSSet<NSString *> *)skipLibraryPaths;

/// 上次扫描耗时（秒），给设置页显示「重新扫描用了多久」。
@property (nonatomic, assign, readonly) NSTimeInterval lastScanDuration;

/// 扫描过的目录清单，便于用户排查「我丢进去为什么没出现」。
@property (nonatomic, copy, readonly) NSArray<NSString *> *scannedDirectories;

@end

NS_ASSUME_NONNULL_END
