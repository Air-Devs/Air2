#import <UIKit/UIKit.h>

// 卡片式（便当盒）启动器根视图控制器
// 左侧：功能菜单卡片 | 中间：内容卡片 | 右侧：账户和启动卡片

@interface LauncherCardLayoutViewController : UIViewController <UINavigationControllerDelegate>

// 三个主要区域
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // 左侧边栏
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // 中间内容
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // 右侧面板

// 切换中间内容
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end

// ★ [TAB-CROSSTALK] E 方案「实例」网格视图(标题行 + 顶部大卡 + 实例卡网格 + 虚线「＋新建实例」)。
//   从 LauncherCardLayoutViewController 抽出为独立 UIView。
//   数据源(PLProfiles)、版式(SPEC §3.1/§3.2)、交互(选中/启动/排序)与抽出前一致。
// ★ [TAB-INST-REVERT] 其唯一的活宿主 InstancesTabViewController 已删除(「实例」标签改回单页
//   VersionManagerViewController)⇒ 本类当前**无活入口**(全仓无人调 e1ShowInstancesPage,
//   setupInstancesPanel 也就不会被触发)。按「不删能力」保留,不在任何标签下占位。
@interface E1InstancesPanelView : UIView

/// 点「＋新建实例」卡 / 启动一个无可启动版本的实例时的落点(宿主决定:切标签 or 切分段)。
@property(nonatomic, copy, nullable) void (^newInstanceHandler)(void);
/// 竖屏右上齿轮。置空时默认 post ShowSettings。
@property(nonatomic, copy, nullable) void (^settingsHandler)(void);

/// 外观令牌/朝向变化时刷新(幂等)。
- (void)applyAppearance;
/// 重建网格(实例/版本/外观数据变化时;幂等)。
- (void)rebuildGrid;
/// 布局后刷新虚线边框路径与玻璃高光。
- (void)refreshCardChrome;
/// 按当前可用宽去重后重建(供宿主在转屏/宽度变化时调用;幂等)。
- (void)refreshForCurrentWidth;

@end
