//
//  A2Icon.m
//  Air2
//

#import "A2Icon.h"
#import "A2ThemeManager.h"

@implementation A2Icon

#pragma mark - 位图资源

+ (UIImage *)vanillaIcon {
    // 资源在 Assets/Images.xcassets/VanillaIcon.imageset
    // 提供 1x/2x/3x，系统按屏幕自动选
    return [UIImage imageNamed:@"VanillaIcon"];
}

+ (UIImage *)loaderIconForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;

    NSString *lower = identifier.lowercaseString;

    // 归一化：不同来源的写法不同（fabric / Fabric / fabricmc）
    NSString *setName = nil;
    if ([lower containsString:@"neoforge"]) {
        setName = @"ModLoaderNeoForge";
    } else if ([lower containsString:@"forge"]) {
        // 注意顺序：先判 neoforge，否则 "neoforge" 会被 forge 匹配
        setName = @"ModLoaderForge";
    } else if ([lower containsString:@"fabric"]) {
        // legacy-fabric / fabric-api 都归到 fabric
        setName = @"ModLoaderFabric";
    } else if ([lower containsString:@"quilt"]) {
        setName = @"ModLoaderQuilt";
    } else if ([lower containsString:@"optifine"]) {
        setName = @"ModLoaderOptiFine";
    }

    if (!setName) return nil;
    return [UIImage imageNamed:setName];
}

+ (UIImage *)loaderIconForVersionName:(NSString *)versionName {
    // 版本名通常形如 1.21.5-fabric，直接交给统一的标识符解析
    return [self loaderIconForIdentifier:versionName];
}

+ (UIImage *)loaderIconForLoaderInfo:(NSString *)loaderInfo {
    return [self loaderIconForIdentifier:loaderInfo ?: @""];
}

#pragma mark - 版本类型

+ (NSString *)symbolForVersionType:(NSString *)type {
    if ([type isEqualToString:@"release"])    return @"cube.fill";
    if ([type isEqualToString:@"snapshot"])   return @"camera.fill";
    if ([type isEqualToString:@"old_beta"])   return @"clock.fill";
    if ([type isEqualToString:@"old_alpha"])  return @"archivebox.fill";
    return @"cube.fill";
}

+ (NSString *)displayNameForVersionType:(NSString *)type {
    if ([type isEqualToString:@"release"])    return @"正式版";
    if ([type isEqualToString:@"snapshot"])   return @"快照";
    if ([type isEqualToString:@"old_beta"])   return @"旧版 Beta";
    if ([type isEqualToString:@"old_alpha"])  return @"旧版 Alpha";
    return type.length ? type : @"未知";
}

+ (UIColor *)boxColorForVersionType:(NSString *)type {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if ([type isEqualToString:@"release"])  return t.cPrimaryContainer;
    if ([type isEqualToString:@"snapshot"]) return t.cTertiaryContainer;
    return t.cSurfaceVariant;
}

+ (UIColor *)symbolColorForVersionType:(NSString *)type {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if ([type isEqualToString:@"release"])  return t.cPrimary;
    if ([type isEqualToString:@"snapshot"]) return t.cTertiary;
    return t.cOnSurfaceVariant;
}

#pragma mark - 插件语义图标

/// 语义 ID → SF Symbol（`PLUGIN-COMPAT.md` 2.4 的词表逐条对应）。
/// 词表里没有的一律 `info.circle`：契约要求「宿主新增图标不会让旧插件画不出来」，
/// 反过来「插件用了新 ID」也只降级成信息图标，不拒载、不空白。
+ (NSString *)symbolForSemanticIconID:(NSString *)iconID {
    if (iconID.length == 0) return @"info.circle";

    // 动作类
    if ([iconID isEqualToString:@"action.download"]) return @"arrow.down.circle";
    if ([iconID isEqualToString:@"action.play"])     return @"play.fill";
    if ([iconID isEqualToString:@"action.settings"]) return @"gearshape";
    if ([iconID isEqualToString:@"action.folder"])   return @"folder";
    if ([iconID isEqualToString:@"action.share"])    return @"square.and.arrow.up";
    if ([iconID isEqualToString:@"action.export"])   return @"square.and.arrow.up.on.square";
    if ([iconID isEqualToString:@"action.import"])   return @"square.and.arrow.down";
    if ([iconID isEqualToString:@"action.info"])     return @"info.circle";
    if ([iconID isEqualToString:@"action.warning"])  return @"exclamationmark.triangle";
    if ([iconID isEqualToString:@"action.refresh"])  return @"arrow.clockwise";
    if ([iconID isEqualToString:@"action.delete"])   return @"trash";

    // 状态类
    if ([iconID isEqualToString:@"status.online"])   return @"circle.fill";
    if ([iconID isEqualToString:@"status.offline"])  return @"circle.slash";
    if ([iconID isEqualToString:@"status.running"])  return @"bolt.fill";
    if ([iconID isEqualToString:@"status.idle"])     return @"moon.zzz";

    // 内容类
    if ([iconID isEqualToString:@"media.pack"])      return @"shippingbox";
    if ([iconID isEqualToString:@"media.world"])     return @"globe";
    if ([iconID isEqualToString:@"media.schematic"]) return @"square.on.square";

    return @"info.circle";
}

#pragma mark - 界面图标

/// 统一的构造方法。用 medium 字重，避免过细在深色背景上看不清。
+ (UIImage *)symbol:(NSString *)name size:(CGFloat)size {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:cfg];
}

+ (UIImage *)accountIcon   { return [self symbol:@"person.crop.circle" size:19]; }
+ (UIImage *)downloadIcon  { return [self symbol:@"arrow.down.circle" size:19]; }
+ (UIImage *)settingsIcon  { return [self symbol:@"gearshape" size:19]; }
+ (UIImage *)folderIcon    { return [self symbol:@"folder" size:19]; }

+ (UIImage *)checkmarkIcon    { return [self symbol:@"checkmark" size:12]; }
+ (UIImage *)closeIcon        { return [self symbol:@"xmark" size:12]; }
+ (UIImage *)chevronDownIcon  { return [self symbol:@"chevron.down" size:14]; }
+ (UIImage *)chevronRightIcon { return [self symbol:@"chevron.right" size:12]; }
+ (UIImage *)warningIcon      { return [self symbol:@"exclamationmark.triangle.fill" size:14]; }
+ (UIImage *)refreshIcon      { return [self symbol:@"arrow.clockwise" size:17]; }
+ (UIImage *)moreIcon         { return [self symbol:@"ellipsis" size:17]; }

@end
