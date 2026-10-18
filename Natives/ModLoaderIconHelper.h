//
//  ModLoaderIconHelper.h
//  Amethyst
//
//  模组加载器图标统一工具类
// 参照 FCL/ZL2 的加载器图标体系，统一项目中三套并行的加载器视觉表示：
//   1. PNG 图片（ModLoaderIcons/ 目录，已有 fabric/forge/neoforge 的 dark/light 版本）
//   2. SF Symbol（VersionManagerViewController/ModLoaderInstallViewController 使用，配色不一致）
//   3. 纯文字 pill 徽章（ModVersionTableViewCell/ShaderVersionTableViewCell/AssetDetailHeaderView/DownloadViewController）
// 本工具类将三者统一为单一入口，优先使用 bundle 中的官方 PNG 图标，
// 缺失时回退到与官方 logo 形状相近的 SF Symbol + 官方品牌色，确保全项目视觉一致。
//
// 加载器品牌色统一参照各加载器官方品牌指南：
//   fabric   = #5B8DF9 (官方蓝)
//   quilt    = #D668AC (官方紫粉)
//   forge    = #8B5A2B (官方棕)
//   neoforge = #E0732B (官方橙)
//   optifine = #E6991A (官方黄)
//   iris     = #4DA6F2 (官方浅蓝)
//   rift     = #33B280 (官方绿)
//   vanilla  = #66CC66 (原版绿)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModLoaderIconHelper : NSObject

/// 根据加载器名称获取官方品牌色（统一配色，全项目共用）
/// 支持 fabric/quilt/forge/neoforge/optifine/optifabric/iris/rift/vanilla 等关键字
/// @param loader 加载器名称（大小写不敏感，支持包含子串匹配，如 "fabric-loader" 也能识别）
/// @return 官方品牌色，未识别返回系统次级标签色
+ (UIColor *)brandColorForLoader:(NSString *)loader;

/// 获取加载器对应的 SF Symbol 名称（与官方 logo 形状相近的符号）
/// 用于 bundle 中无对应 PNG 时的回退显示
+ (NSString *)symbolNameForLoader:(NSString *)loader;

/// 获取加载器的本地化显示名（用于徽章文字）
+ (NSString *)displayNameForLoader:(NSString *)loader;

/// 加载加载器图标（优先 bundle PNG，回退 SF Symbol）
/// 会根据 traitCollection 的 userInterfaceStyle 自动选择 dark/light 主题 PNG
/// @param loader 加载器名称
/// @param traitCollection 当前界面的 traitCollection（用于深浅色判断），传 nil 默认浅色
/// @return 加载器图标 UIImage（PNG 或 SF Symbol），未识别返回 nil
+ (nullable UIImage *)iconImageForLoader:(NSString *)loader
                         traitCollection:(nullable UITraitCollection *)traitCollection;

/// 配置 UIImageView 显示加载器图标
/// 自动设置 image、tintColor（SF Symbol 时着色，PNG 时不着色保持原色）、contentMode
/// @param imageView 要配置的 UIImageView
/// @param loader 加载器名称
/// @param traitCollection 当前 traitCollection
+ (void)configureImageView:(UIImageView *)imageView
                forLoader:(NSString *)loader
           traitCollection:(nullable UITraitCollection *)traitCollection;

/// 创建加载器徽章视图（图标 + 文字 pill，参照 FCL/ZL2 的加载器标签）
/// 图标优先使用 PNG，文字使用 displayNameForLoader:
/// @param loader 加载器名称
/// @param traitCollection 当前 traitCollection
/// @return 配置好的 UIView（含图标和文字的水平排列）
+ (UIView *)createBadgeViewForLoader:(NSString *)loader
                      traitCollection:(nullable UITraitCollection *)traitCollection;

/// 创建纯图标徽章（无文字，仅图标 + 品牌色背景圆角，参照 ZL2 LittleTextLabel 风格）
/// 用于空间紧凑的场景（如版本行右侧的加载器小图标）
/// @param loader 加载器名称
/// @param traitCollection 当前 traitCollection
/// @param size 图标尺寸（默认 18pt）
+ (UIView *)createIconBadgeForLoader:(NSString *)loader
                      traitCollection:(nullable UITraitCollection *)traitCollection
                                size:(CGFloat)size;

/// 判断加载器名称是否为已知加载器（用于过滤显示）
+ (BOOL)isKnownLoader:(NSString *)loader;

/// 从版本 ID 字符串中识别加载器类型
/// 例如 "1.20.1-Fabric-0.15.7" → "fabric"，"1.20.1-forge-47.2.0" → "forge"
+ (nullable NSString *)detectLoaderFromVersionId:(NSString *)versionId;

@end

NS_ASSUME_NONNULL_END
