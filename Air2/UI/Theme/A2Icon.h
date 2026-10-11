//
//  A2Icon.h
//  Air2
//
//  图标统一入口 —— 所有图标从这里取，不在视图里硬编码名字。
//
//  三类图标：
//    1. 位图资源（Assets/Images.xcassets）
//       草方块、模组加载器 —— 来自 Air1 的 Minecraft 风格图标
//    2. SF Symbols
//       绝大多数界面图标
//    3. 版本状态色（图标方块底色）
//
//  为什么集中：之前各处写 [UIImage systemImageNamed:@"cube.fill"]，
//  改图标要全工程搜。集中后换图标只改这一处。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Icon : NSObject

#pragma mark - 位图资源

/// 原版草方块图标（MC 版本、版本卡片用）
+ (nullable UIImage *)vanillaIcon;

/// 模组加载器图标。identifier 取 fabric / forge / neoforge / optifine / quilt。
/// 未知加载器返回 nil，调用方应回退到 SF Symbol。
+ (nullable UIImage *)loaderIconForIdentifier:(NSString *)identifier;

/// 从版本名推断加载器图标（如 "1.21.5-fabric" → fabric 图标）
+ (nullable UIImage *)loaderIconForVersionName:(NSString *)versionName;

/// 从加载器显示名推断（如 "Fabric 0.16.10" → fabric 图标）
+ (nullable UIImage *)loaderIconForLoaderInfo:(nullable NSString *)loaderInfo;

#pragma mark - 版本类型

/// 版本类型对应的 SF Symbol 名
/// release / snapshot / old_beta / old_alpha
+ (NSString *)symbolForVersionType:(nullable NSString *)type;

/// 版本类型的中文名
+ (NSString *)displayNameForVersionType:(nullable NSString *)type;

/// 版本类型对应的图标方块底色（用于列表）
+ (UIColor *)boxColorForVersionType:(nullable NSString *)type;

/// 版本类型对应的符号色
+ (UIColor *)symbolColorForVersionType:(nullable NSString *)type;

#pragma mark - 界面图标

// 顶栏
+ (UIImage *)accountIcon;
+ (UIImage *)downloadIcon;
+ (UIImage *)settingsIcon;
+ (UIImage *)folderIcon;

// 通用
+ (UIImage *)checkmarkIcon;
+ (UIImage *)closeIcon;
+ (UIImage *)chevronDownIcon;
+ (UIImage *)chevronRightIcon;
+ (UIImage *)warningIcon;
+ (UIImage *)refreshIcon;
+ (UIImage *)moreIcon;

@end

NS_ASSUME_NONNULL_END
