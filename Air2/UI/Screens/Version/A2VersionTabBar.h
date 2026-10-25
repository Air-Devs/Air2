//
//  A2VersionTabBar.h
//  Air2
//
//  版本详情页的左侧标签栏 —— 对照 ZL2 的 TabMenu（VersionSettingsScreen.kt）。
//
//  ## 为什么改成分标签
//
//  之前所有内容堆在一条长滚动列表里（头部 / 隔离 / 目录 / 启动 / 删除），
//  用户要滚很久才能找到要的东西，而且「删除版本」这种危险操作
//  就紧挨着普通设置。
//
//  ZL2 的做法：左侧竖排标签，右侧只显示当前标签的内容。
//
//    ┌────────┬──────────────────────┐
//    │ 总览    │                      │
//    │ 启动    │   当前标签的内容      │
//    │ 目录    │                      │
//    │ ────   │                      │
//    │ 删除    │                      │
//    └────────┴──────────────────────┘
//
//  ## 与 ZL2 的差异
//
//  ZL2 有 9 个标签（含模组/存档/资源包/光影/截图/服务器列表），
//  那些是独立的完整页面。我们先把「版本设置」本身拆开，
//  资源管理类页面后续再加。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2VersionTab) {
    A2VersionTabOverview = 0,   ///< 总览（状态 + 隔离）
    A2VersionTabLaunch,         ///< 启动配置
    A2VersionTabFolder,         ///< 游戏目录
    A2VersionTabDanger,         ///< 危险操作（删除/导出）
    A2VersionTabCount
};

@interface A2VersionTabBar : UIView

@property (nonatomic, assign) A2VersionTab selectedTab;
@property (nonatomic, copy, nullable) void (^onTabChanged)(A2VersionTab tab);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
