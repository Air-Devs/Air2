//
//  A2GameMenuOverlay.h
//  Air2
//
//  游戏内悬浮球与菜单 —— 完整对齐 ZL2 的 GameMenuSubscreen.kt（1137 行）。
//
//  ## ZL2 的结构
//
//    DualMenuSubscreen（双栏）
//      ├── 左栏：顶部 Tab 栏 + HorizontalPager
//      │     Tab 0  控制总览  输入法 / 自动 IME / 发送键码 / 切换控件 / 编辑布局
//      │     Tab 1  鼠标      灵敏度 / 拖动模式 / 滚轮
//      │     Tab 2  手柄      按键映射 / 死区 / 连接状态
//      │     Tab 3  手势      多点触控映射
//      │     Tab 4  陀螺仪    灵敏度 / 轴向 / 平滑
//      └── 右栏：游戏操作
//           强制关闭 / 切换日志 / 陶瓦联机 / 显示菜单 / 浮球不透明度
//           FPS 显示模式 / 内存显示 / 最大刷新率
//           分辨率规则 / 分辨率缩放 / 自定义分辨率
//
//  ## 我们的实现方式
//
//  ZL2 用 Compose 的 Pager，iOS 上用 UICollectionView 的横向分页更自然。
//  整体是一个全屏覆盖层：左栏占 62%，右栏占 38% —— 与 ZL2 的
//  DualMenuSubscreen 比例一致。
//
//  ## 浮球行为（参照 ZL2）
//
//    · 可拖动，松手吸附到左右边缘
//    · 点击展开菜单
//    · 不透明度可调（Settings 里存 user default）
//    · 可完全隐藏（长按浮球隐藏，双击屏幕边缘恢复）
//

#import <UIKit/UIKit.h>
#import "A2ResolutionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 菜单动作，由宿主实现
@protocol A2GameMenuDelegate <NSObject>
@optional
// —— 控制总览 ——
- (void)gameMenuOpenInputMethod;
- (void)gameMenuSendKeycode;
- (void)gameMenuToggleControls;
- (void)gameMenuEditLayout;
// —— 游戏操作 ——
- (void)gameMenuForceClose;
- (void)gameMenuToggleLog;
- (void)gameMenuOpenTerracotta;
- (void)gameMenuRefreshWindowSize;
// —— 显示选项 ——
- (void)gameMenuSetFPSDisplayMode:(NSInteger)mode;   // 0=关 1=总是 2=仅调试
- (void)gameMenuSetShowMemory:(BOOL)show;
- (void)gameMenuSetMaxRefreshRate:(NSInteger)hz;
@end

/// FPS 显示模式
typedef NS_ENUM(NSInteger, A2FPSDisplayMode) {
    A2FPSDisplayModeOff = 0,
    A2FPSDisplayModeAlways = 1,
    A2FPSDisplayModeDebugOnly = 2,
};

@interface A2GameMenuOverlay : UIView

@property (nonatomic, weak, nullable) id<A2GameMenuDelegate> delegate;

@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;
- (void)expand;
- (void)collapse;
- (void)toggle;

/// 浮球显隐
@property (nonatomic, assign) BOOL visible;
/// 浮球不透明度（0.2 ~ 1.0）
@property (nonatomic, assign) CGFloat ballOpacity;

/// 游戏 surface —— 分辨率调整会作用到它
@property (nonatomic, weak, nullable) CALayer *gameLayer;

- (void)applyTheme;

/// 更新 FPS / 内存显示（悬浮球旁的小字）。
/// 对应 ZL2 的 FPS 与内存显示开关 —— 数据由 SurfaceViewController 的
/// statsTimer 每秒喂一次。
- (void)updateFPS:(double)fps memoryUsageMB:(double)memoryMB;

@end

NS_ASSUME_NONNULL_END
