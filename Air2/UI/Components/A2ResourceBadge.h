//
//  A2ResourceBadge.h
//  Air2
//
//  资源标签 —— 对应 ZL2 的 PlatformIdentifier / ClassesIdentifier /
//  InstalledModBadge / FavoriteToggleLabel 这一组小标识。
//
//  四种形态：
//    · 平台标签     Modrinth / CurseForge（区分来源，色板不同）
//    · 类别标签     模组 / 光影 / 资源包 …（带图标的彩色 pill）
//    · 已安装标记   圆形对勾
//    · 收藏按钮     星标，可点击切换
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 平台标签

/// 平台标签。Modrinth 用绿色系、CurseForge 用橙色系 —— 这是两家的品牌色，
/// 不做主题适配（用户需要一眼分辨来源）。
@interface A2PlatformBadge : UIView

- (instancetype)initWithPlatform:(A2ContentPlatform)platform;
@property (nonatomic, assign) A2ContentPlatform platform;

@end

#pragma mark - 类别标签

/// 类别标签：小图标 + 文字，彩色 pill。
@interface A2ClassBadge : UIView

- (instancetype)initWithContentClass:(A2ContentClass)contentClass;
@property (nonatomic, assign) A2ContentClass contentClass;

@end

#pragma mark - 已安装标记

/// 已安装标记：圆形底 + 对勾。
@interface A2InstalledBadge : UIView

/// 是否已安装（未安装时整体隐藏）
@property (nonatomic, assign, getter=isInstalled) BOOL installed;

@end

#pragma mark - 收藏按钮

/// 收藏按钮：星标，点击切换。
@interface A2FavoriteButton : UIControl

@property (nonatomic, assign, getter=isFavorite) BOOL favorite;
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL isFavorite);

@end

NS_ASSUME_NONNULL_END
