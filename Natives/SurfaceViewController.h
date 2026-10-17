#import <UIKit/UIKit.h>
#import "UIKit+hook.h"

#import "customcontrols/ControlLayout.h"
#import "GameSurfaceView.h"
#import "PLLogOutputView.h"

BOOL canAppendToLog;
dispatch_group_t fatalExitGroup;

CGRect virtualMouseFrame;
CGPoint lastVirtualMousePoint;

@interface SurfaceViewController : UIViewController

@property(nonatomic) ControlLayout *ctrlView;
@property(nonatomic) GameSurfaceView* surfaceView;
@property(nonatomic) UIView *touchView;
@property UIImageView* mousePointerView;
@property(nonatomic) UIPanGestureRecognizer* scrollPanGesture;

@property(nonatomic) UIView* rootView;

- (instancetype)initWithMetadata:(NSDictionary *)metadata;
- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event;
- (void)updateSavedResolution;
- (void)updateGrabState;

+ (GameSurfaceView *)surface;
+ (BOOL)isRunning;
// 获取当前显示的 SurfaceViewController 实例
// 支持作为 rootViewController 或以模态方式呈现两种情况
+ (instancetype)currentInstance;

// LogView category
@property(nonatomic) PLLogOutputView* logOutputView;

// Navigation category
@property(nonatomic) NSArray *menuArray;
@property(nonatomic) UITableView *menuView;
@property(nonatomic) UIScreenEdgePanGestureRecognizer* edgeGesture;
@property(nonatomic) UIView *gameMenuOverlay; // FCL 风格悬浮按钮 + FPS/内存显示

@end

@interface SurfaceViewController(ExternalDisplay)

- (void)switchToExternalDisplay;
- (void)switchToInternalDisplay;

@end

@interface SurfaceViewController(LogView)

- (void)viewWillTransitionToSize_LogView:(CGRect)frame;

@end

@interface SurfaceViewController(Navigation)<UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>

- (void)actionOpenNavigationMenu;
- (void)didSelectMenuItem:(int)item;
- (void)viewWillTransitionToSize_Navigation:(CGRect)frame;
// FCL 风格游戏内菜单动作
- (void)actionToggleControls;        // 隐藏/显示控制按钮
- (void)actionToggleVirtualMouse;    // 虚拟鼠标开关
- (void)actionToggleKeyboard;        // 游戏内键盘开关
- (void)actionAdjustResolution;      // 分辨率调整
- (void)actionOpenMultiplayer;       // 联机（ZeroTier）

@end

// MARK: - SDL3 渲染层卫兵（egl_bridge 使用）
// 找到当前嵌入的 SDL 视图（SDL_uikitview）；非 SDL3 路径返回 nil。
UIView *Amethyst_FindEmbeddedSDLView(void);
// 把 SDL 嵌入视图（及其内部的金属子视图）改为透明。
// 它位于最前以接收触摸，但不透明会整块遮住下面的 GameSurfaceView → 黑屏。
// 只置 opaque / 背景色，不改 alpha、不重排 z 序，以免影响输入与虚拟鼠标。
// 已处理过（全部已透明）返回 NO，本次确实改过返回 YES。
BOOL Amethyst_MakeSDLRenderTransparent(void);
// Air Task 32 / Task 52：SDL3 呈现层不变量执法（黑屏根治）。
// 必须在主线程调用。依次做四件事：
//   1) 隐藏 SDL 自己的 UIWindow —— 原生 UIKit_ShowWindow 会 makeKeyAndVisible，
//      那个空窗口浮在整个宿主窗口之上，直接盖住 GameSurfaceView = 黑屏
//      （Air 原话：“空窗黑盖子”）。隐藏后把 key window 还给宿主。
//   2) 揭开渲染目标：GameSurfaceView 及其 layer 的 hidden 置 NO。
//      供应商 libSDL3.dylib 的 Zalith 同源嵌入补丁会按类名找到它并
//      setHidden:YES，而 GL/Vulkan 的真正呈现面正是它的 CAMetalLayer。
//   3) 让 SDL 嵌入视图透明（复用 Amethyst_MakeSDLRenderTransparent）。
//   4) z 序终局：GameSurfaceView 紧贴 SDL 触摸视图「之下」，容器内其余
//      子视图（虚拟鼠标指针、控制按钮）压到最上——即 Air 的排布。
// 返回 YES 表示本次发现并修复了「渲染层被外部隐藏」。
BOOL Amethyst_EnforceSDL3Presentation(void);
