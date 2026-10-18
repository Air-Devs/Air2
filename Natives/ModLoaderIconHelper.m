//
//  ModLoaderIconHelper.m
//  Amethyst
//
//  模组加载器图标统一工具类实现
// 参照 FCL/ZL2 的加载器图标体系，统一项目中三套并行的加载器视觉表示
//

#import "ModLoaderIconHelper.h"

@implementation ModLoaderIconHelper

#pragma mark - 品牌色

/// 统一的加载器品牌色映射（全项目共用，消除多文件间配色不一致问题）
/// 配色参照各加载器官方品牌指南，与 FCL/ZL2 使用的官方色保持一致
+ (UIColor *)brandColorForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return [UIColor tertiaryLabelColor];
    }
    NSString *lower = loader.lowercaseString;

    // 注意判断顺序：neoforge 必须在 forge 之前（neoforge 包含 forge 子串）
    // optifabric 必须在 optifine 之前（optifabric 包含 optifine 子串）
    if ([lower containsString:@"neoforge"]) {
        // NeoForge 官方橙 #E0732B
        return [UIColor colorWithRed:0.88 green:0.45 blue:0.17 alpha:1.0];
    }
    if ([lower containsString:@"forge"]) {
        // Forge 官方棕 #8B5A2B
        return [UIColor colorWithRed:0.55 green:0.35 blue:0.20 alpha:1.0];
    }
    if ([lower containsString:@"optifabric"]) {
        // OptiFabric 与 OptiFine 同色系
        return [UIColor colorWithRed:0.90 green:0.60 blue:0.10 alpha:1.0];
    }
    if ([lower containsString:@"optifine"]) {
        // OptiFine 官方黄 #E6991A
        return [UIColor colorWithRed:0.90 green:0.60 blue:0.10 alpha:1.0];
    }
    if ([lower containsString:@"quilt"]) {
        // Quilt 官方紫粉 #D668AC
        return [UIColor colorWithRed:0.84 green:0.41 blue:0.67 alpha:1.0];
    }
    if ([lower containsString:@"fabric"]) {
        // Fabric 官方蓝 #5B8DF9
        return [UIColor colorWithRed:0.18 green:0.55 blue:0.95 alpha:1.0];
    }
    if ([lower containsString:@"iris"]) {
        // Iris 官方浅蓝 #4DA6F2
        return [UIColor colorWithRed:0.30 green:0.65 blue:0.95 alpha:1.0];
    }
    if ([lower containsString:@"rift"]) {
        // Rift 官方绿 #33B280
        return [UIColor colorWithRed:0.20 green:0.70 blue:0.50 alpha:1.0];
    }
    if ([lower containsString:@"vanilla"]) {
        // 原版绿 #66CC66
        return [UIColor colorWithRed:0.40 green:0.80 blue:0.40 alpha:1.0];
    }
    // 未识别：返回系统次级标签色（灰色，作为兜底）
    return [UIColor tertiaryLabelColor];
}

#pragma mark - SF Symbol 名称

/// 加载器对应的 SF Symbol 名称（与官方 logo 形状相近）
/// 仅在 bundle 中无对应 PNG 时作为回退使用
+ (NSString *)symbolNameForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return @"cube.box.fill";
    }
    NSString *lower = loader.lowercaseString;

    // 注意判断顺序与 brandColorForLoader 一致
    if ([lower containsString:@"neoforge"]) {
        // NeoForge: 锤子形状（官方 logo 是锤子）
        return @"hammer.fill";
    }
    if ([lower containsString:@"forge"]) {
        // Forge: 铁砧形状（官方 logo 是铁砧）
        return @"anvil.fill";
    }
    if ([lower containsString:@"optifabric"] || [lower containsString:@"optifine"]) {
        // OptiFine: 眼睛形状（官方 logo 是眼睛）
        return @"eye.fill";
    }
    if ([lower containsString:@"quilt"]) {
        // Quilt: 六边形网格（官方 logo 是拼布图案）
        return @"circle.hexagongrid.fill";
    }
    if ([lower containsString:@"fabric"]) {
        // Fabric: 闪电/星星（官方 logo 是织布针，SF Symbol 无完全匹配，用相近的）
        return @"wand.and.stars";
    }
    if ([lower containsString:@"iris"]) {
        // Iris: 彩虹/圆形（官方 logo 是彩虹眼睛）
        return @"circle.lefthalf.filled";
    }
    if ([lower containsString:@"rift"]) {
        // Rift: 闪电（官方 logo 是裂缝/闪电）
        return @"bolt.fill";
    }
    if ([lower containsString:@"vanilla"]) {
        // Vanilla: 立方体（原版方块）
        return @"cube.fill";
    }
    // 默认：立方体盒子
    return @"cube.box.fill";
}

#pragma mark - 显示名

/// 加载器的本地化显示名（用于徽章文字）
+ (NSString *)displayNameForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return @"Unknown";
    }
    NSString *lower = loader.lowercaseString;

    if ([lower containsString:@"neoforge"])   return @"NeoForge";
    if ([lower containsString:@"forge"])      return @"Forge";
    if ([lower containsString:@"optifabric"]) return @"OptiFabric";
    if ([lower containsString:@"optifine"])   return @"OptiFine";
    if ([lower containsString:@"quilt"])      return @"Quilt";
    if ([lower containsString:@"fabric"])     return @"Fabric";
    if ([lower containsString:@"iris"])       return @"Iris";
    if ([lower containsString:@"rift"])       return @"Rift";
    if ([lower containsString:@"vanilla"])    return @"Vanilla";

    // 未知加载器：首字母大写返回
    if (loader.length > 0) {
        NSString *firstChar = [[loader substringToIndex:1] uppercaseString];
        NSString *rest = [loader substringFromIndex:1];
        return [NSString stringWithFormat:@"%@%@", firstChar, rest];
    }
    return @"Unknown";
}

#pragma mark - 图标加载

/// 加载加载器图标（优先 bundle PNG，回退 SF Symbol）
/// 加载顺序：
///   1. ModLoaderIcons/{key}.png（HMCL 官方标准单文件，不区分深浅色，品牌色透明 PNG）
///   2. ModLoaderIcons/{key}_{light|dark}.png（旧格式兼容，区分主题）
///   3. SF Symbol + 品牌色着色（兜底）
+ (UIImage *)iconImageForLoader:(NSString *)loader
                 traitCollection:(UITraitCollection *)traitCollection {
    if (!loader || loader.length == 0) {
        return [UIImage systemImageNamed:@"cube.box.fill"];
    }

    // Vanilla 原版：使用 Assets.xcassets 中的 VanillaIcon 草方块图标
    // 与 VersionCardCell 中版本卡片的原版图标保持一致（HMCL 仓库自带的标准草方块）
    if ([loader.lowercaseString containsString:@"vanilla"]) {
        UIImage *vanillaIcon = [UIImage imageNamed:@"VanillaIcon"];
        if (vanillaIcon) {
            return vanillaIcon;
        }
        // 如果 VanillaIcon 加载失败，回退到 SF Symbol
        return [UIImage systemImageNamed:@"cube.fill"];
    }

    // 提取加载器的规范化名称（用于 PNG 文件名匹配）
    NSString *pngKey = [self pngKeyForLoader:loader];
    if (pngKey) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resourcePath = [bundle resourcePath];

        // 1. 优先加载 HMCL 官方标准单文件（不区分深浅色主题）
        NSString *standardPath = [resourcePath stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"ModLoaderIcons/%@.png", pngKey]];
        UIImage *image = [UIImage imageWithContentsOfFile:standardPath];
        if (image) {
            return image;
        }

        // 2. 回退到旧格式（区分 light/dark 主题）
        BOOL isDarkMode = NO;
        if (traitCollection) {
            isDarkMode = (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        }
        NSString *theme = isDarkMode ? @"dark" : @"light";
        NSString *themedPath = [resourcePath stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
        image = [UIImage imageWithContentsOfFile:themedPath];
        if (image) {
            return image;
        }
        // 尝试相反主题
        theme = isDarkMode ? @"light" : @"dark";
        themedPath = [resourcePath stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
        image = [UIImage imageWithContentsOfFile:themedPath];
        if (image) {
            return image;
        }
    }

    // 3. 无 PNG 或加载失败：回退到 SF Symbol
    NSString *symbolName = [self symbolNameForLoader:loader];
    UIImage *symbolImage = [UIImage systemImageNamed:symbolName];
    return symbolImage ?: [UIImage systemImageNamed:@"cube.box.fill"];
}

/// 将加载器名称转换为 PNG 文件名 key（如 "fabric-loader" → "fabric"）
/// 用于匹配 ModLoaderIcons/ 目录下的 PNG 文件
+ (nullable NSString *)pngKeyForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) return nil;
    NSString *lower = loader.lowercaseString;

    // 注意顺序：neoforge 在 forge 之前，optifabric 在 optifine 之前
    if ([lower containsString:@"neoforge"])   return @"neoforge";
    if ([lower containsString:@"forge"])      return @"forge";
    if ([lower containsString:@"optifabric"]) return @"optifine"; // 与 OptiFine 共用图标
    if ([lower containsString:@"optifine"])   return @"optifine"; // HMCL 官方 PNG
    if ([lower containsString:@"quilt"])      return @"quilt";    // HMCL 官方 PNG
    if ([lower containsString:@"fabric"])     return @"fabric";
    if ([lower containsString:@"iris"])       return nil; // 暂无官方 PNG，回退 SF Symbol
    if ([lower containsString:@"rift"])       return nil; // 暂无官方 PNG，回退 SF Symbol
    if ([lower containsString:@"vanilla"])    return nil; // 用 Assets.xcassets 的 VanillaIcon
    return nil;
}

#pragma mark - UIImageView 配置

/// 配置 UIImageView 显示加载器图标
/// PNG 图标保持原色不着色，SF Symbol 用品牌色着色
+ (void)configureImageView:(UIImageView *)imageView
                forLoader:(NSString *)loader
           traitCollection:(UITraitCollection *)traitCollection {
    if (!imageView) return;

    UIImage *image = [self iconImageForLoader:loader traitCollection:traitCollection];
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFit;

    // 判断是否为 PNG 或 VanillaIcon（不着色），SF Symbol 着色
    // Vanilla 使用 Assets.xcassets 的草方块图标，保持原色不着色
    if ([loader.lowercaseString containsString:@"vanilla"]) {
        imageView.tintColor = nil;
        return;
    }

    // 与 iconImageForLoader 的加载顺序一致：先标准单文件，再主题文件
    NSString *pngKey = [self pngKeyForLoader:loader];
    BOOL hasPng = NO;
    if (pngKey) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resourcePath = [bundle resourcePath];
        // 1. 先检查 HMCL 官方标准单文件
        NSString *standardPath = [resourcePath stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"ModLoaderIcons/%@.png", pngKey]];
        if ([NSFileManager.defaultManager fileExistsAtPath:standardPath]) {
            hasPng = YES;
        } else {
            // 2. 再检查旧格式主题文件
            BOOL isDarkMode = traitCollection ? (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) : NO;
            NSString *theme = isDarkMode ? @"dark" : @"light";
            NSString *themedPath = [resourcePath stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
            if ([NSFileManager.defaultManager fileExistsAtPath:themedPath]) {
                hasPng = YES;
            } else {
                theme = isDarkMode ? @"light" : @"dark";
                themedPath = [resourcePath stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
                if ([NSFileManager.defaultManager fileExistsAtPath:themedPath]) {
                    hasPng = YES;
                }
            }
        }
    }

    if (hasPng) {
        // PNG 图标：保持原色，不着色
        imageView.tintColor = nil;
    } else {
        // SF Symbol：用品牌色着色
        imageView.tintColor = [self brandColorForLoader:loader];
    }
}

#pragma mark - 徽章视图

/// 创建加载器徽章视图（图标 + 文字 pill，参照 FCL/ZL2 的加载器标签）
/// 圆角背景使用品牌色半透明，图标 + 白色文字
+ (UIView *)createBadgeViewForLoader:(NSString *)loader
                      traitCollection:(UITraitCollection *)traitCollection {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIColor *brandColor = [self brandColorForLoader:loader];

    // 圆角背景
    container.backgroundColor = [brandColor colorWithAlphaComponent:0.18];
    container.layer.cornerRadius = 8;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 0.5;
    container.layer.borderColor = [brandColor colorWithAlphaComponent:0.35].CGColor;

    // 图标
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self configureImageView:iconView forLoader:loader traitCollection:traitCollection];
    [container addSubview:iconView];

    // 文字
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [self displayNameForLoader:loader];
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    label.textColor = brandColor;
    label.textAlignment = NSTextAlignmentCenter;
    [container addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:12],
        [iconView.heightAnchor constraintEqualToConstant:12],

        [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:3],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:3],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-3],

        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor constant:3],
        [iconView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-3],
    ]];

    return container;
}

/// 创建纯图标徽章（无文字，仅图标 + 品牌色背景圆角）
/// 用于空间紧凑的场景（如版本行右侧的加载器小图标）
+ (UIView *)createIconBadgeForLoader:(NSString *)loader
                      traitCollection:(UITraitCollection *)traitCollection
                                size:(CGFloat)size {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIColor *brandColor = [self brandColorForLoader:loader];

    // 圆角背景
    container.backgroundColor = [brandColor colorWithAlphaComponent:0.15];
    container.layer.cornerRadius = size / 3.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;

    // 图标
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self configureImageView:iconView forLoader:loader traitCollection:traitCollection];
    [container addSubview:iconView];

    CGFloat iconSize = size * 0.62;
    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:size],
        [container.heightAnchor constraintEqualToConstant:size],

        [iconView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:iconSize],
        [iconView.heightAnchor constraintEqualToConstant:iconSize],
    ]];

    return container;
}

#pragma mark - 工具方法

/// 判断加载器名称是否为已知加载器（用于过滤显示）
+ (BOOL)isKnownLoader:(NSString *)loader {
    if (!loader || loader.length == 0) return NO;
    NSString *lower = loader.lowercaseString;
    if ([lower containsString:@"fabric"])     return YES;
    if ([lower containsString:@"quilt"])      return YES;
    if ([lower containsString:@"forge"])      return YES;
    if ([lower containsString:@"neoforge"])   return YES;
    if ([lower containsString:@"optifine"])   return YES;
    if ([lower containsString:@"optifabric"]) return YES;
    if ([lower containsString:@"iris"])       return YES;
    if ([lower containsString:@"rift"])       return YES;
    if ([lower containsString:@"vanilla"])    return YES;
    return NO;
}

/// 从版本 ID 字符串中识别加载器类型
/// 例如 "1.20.1-Fabric-0.15.7" → "fabric"，"1.20.1-forge-47.2.0" → "forge"
+ (NSString *)detectLoaderFromVersionId:(NSString *)versionId {
    if (!versionId || versionId.length == 0) return nil;
    NSString *lower = [versionId lowercaseString];

    // 注意顺序：neoforge 在 forge 之前
    if ([lower containsString:@"neoforge"])   return @"neoforge";
    if ([lower containsString:@"forge"])      return @"forge";
    if ([lower containsString:@"optifabric"]) return @"optifabric";
    if ([lower containsString:@"optifine"])   return @"optifine";
    if ([lower containsString:@"quilt"])      return @"quilt";
    if ([lower containsString:@"fabric"])     return @"fabric";
    if ([lower containsString:@"iris"])       return @"iris";
    if ([lower containsString:@"rift"])       return @"rift";
    return nil;
}

@end
