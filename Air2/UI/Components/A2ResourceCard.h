//
//  A2ResourceCard.h
//  Air2
//
//  资源卡片 —— 对应 ZL2 的 ResultProjectLayout。
//
//  布局（严格对齐 ZL2 的规格）：
//    ┌──────────────────────────────────────────────────┐
//    │ ┌──────┐ 项目名 │ 作者              [MODRINTH]   │
//    │ │      │ ┌─────────────────────┐  ⬇ 1.2M         │
//    │ │ 72pt │ │ 描述（最多 2 行省略） │                 │
//    │ │ 图标 │ └─────────────────────┘                 │
//    │ └──────┘ [Fabric][Forge] . [模组] ✓已装 ★收藏    │
//    └──────────────────────────────────────────────────┘
//
//  规格要点（ZL2 的实测值）：
//    · 图标 72dp、圆角 10dp
//    · 内边距 8dp
//    · 图标与内容间距 12dp
//    · 标题与作者之间有竖直分隔线
//    · 平台标签在右上角
//
//  独立成组件的理由：搜索页、收藏页、详情页的相关推荐都要用它，
//  内嵌在某个 VC 里会导致重复实现。
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ResourceCard : UIView

/// 配置内容
- (void)configureWithItem:(A2ContentItem *)item;

/// 当前条目
@property (nonatomic, strong, readonly, nullable) A2ContentItem *item;

/// 是否已安装（显示对勾角标）
@property (nonatomic, assign, getter=isInstalled) BOOL installed;

/// 是否已收藏
@property (nonatomic, assign, getter=isFavorite) BOOL favorite;

/// 点击卡片
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// 点击收藏
@property (nonatomic, copy, nullable) void (^onFavoriteToggle)(BOOL isFavorite);

/// 入场动画（从 0.95 缩放展开，与 ZL2 一致）
- (void)playEntranceAnimationWithDelay:(NSTimeInterval)delay;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
