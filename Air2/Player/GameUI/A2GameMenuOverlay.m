//
//  A2GameMenuOverlay.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2GameMenuOverlay.m
//  Air2
//
//  游戏内悬浮球 + 功能面板的实现。
//
//  对照 ZL2：
//    · zl2/ZalithLauncher/.../ui/screens/game/elements/GameBall.kt
//        —— 悬浮球内容：图标 / FPS / 内存，展开时切换图标
//    · zl2/ZalithLauncher/.../ui/components/Draggabble.kt（FloatingBall）
//        —— 拖动阈值、边界钳制、拖动与点击互斥、松手回调
//    · zl2/ZalithLauncher/.../ui/screens/game/elements/GameMenuSubscreen.kt
//        —— 展开后的菜单项（只取 Air2 已有的能力）
//
//  ## 触摸为什么不冲突
//
//  本视图铺满全屏（由 SurfaceViewController 在 self.view 上挂载），
//  但 hitTest 只放行三块区域：
//      · 收起时：浮球 + 统计文字
//      · 展开时：浮球 + 面板 + 吞触摸的遮罩
//  其余点返回 nil，UIKit 会继续找下层（ctrlView / touchView），
//  所以游戏摇杆、视角拖动照常工作。这与 ZL2 把 FloatingBall 铺在
//  游戏画面之上、只消费自身 pointerInput 的做法等价。
//
//  ## 面板项从哪来
//
//  任务要求「按 Air2 现有能力来，不要发明不存在的功能」，因此：
//    · 编辑控件      → onOpenEditor（SurfaceViewController 已接线）
//    · 显示日志      → A2GameMenuDelegate 或宿主 PLLogOutputView
//                      （-actionToggleLogOutput，PLLogOutputView.m:147）
//    · 退出游戏      → A2GameMenuDelegate -gameMenuForceClose（弹确认）
//    · 返回启动器    → 新增可选 delegate；宿主不实现则不显示
//    · 联机 / 键码 / 重设窗口尺寸 → 已有 delegate 方法，宿主实现才显示
//    · FPS / 内存 / 不透明度 / 大小 → 本类自己实现
//    · 渲染器 / 分辨率 → 只读展示（AMETHYST_RENDERER、gameLayer 尺寸）
//
//  宿主是 SurfaceViewController（Context/，本任务禁止改动）。它目前没有把
//  自己设为 delegate，所以依赖 delegate 的项会在展开时自动隐藏；等宿主接线
//  后无需改本文件即可出现。日志项走宿主 logOutputView 兜底，现在就能用。
//

#import "A2GameMenuOverlay.h"
#import "A2ThemeManager.h"

#include <math.h>

#pragma mark - 常量与偏好键

static const CGFloat kA2BallMinDiameter = 32.0;
static const CGFloat kA2BallMaxDiameter = 64.0;
static const CGFloat kA2BallDefaultDiameter = 44.0;
static const CGFloat kA2EdgeInset = 10.0;
static const CGFloat kA2BallGap = 8.0;
static const CGFloat kA2PanelMaxWidth = 320.0;
static const CGFloat kA2PanelCornerRadius = 18.0;
static const CGFloat kA2PanelHeaderHeight = 56.0;

// 拖动/点击判定阈值：手指位移超过 6pt 才是「拖」，否则松手算「点」。
// 对应 ZL2 Draggabble.kt 里 viewConfiguration.touchSlop 的用途。
static const CGFloat kA2TapDistance = 6.0;

// 位置存【归一化中心坐标】(x/可用宽、y/可用高)，不存绝对点：
// 换方向、换分辨率、换设备后（包括 iPhone/iPad）都能落回相对同一处。
// 对应 ZL2 的 position: Offset 持久化（Draggabble.kt 的 onSavePos）。
// 格式固定为 "x,y" 两个 0~1 的小数，例如 "0.923000,0.104000"。
static NSString *const kA2BallPositionKey = @"game.menu.ballPosition";
static NSString *const kA2BallDiameterKey = @"game.menu.ballDiameter";
static NSString *const kA2BallOpacityKey = @"game.menu.ballOpacity";
static NSString *const kA2BallShowsFPSKey = @"game.menu.ballShowsFPS";
static NSString *const kA2BallShowsMemoryKey = @"game.menu.ballShowsMemory";

#pragma mark - 宿主桥（不 import Context 头，避免 GameUI → Context 的编译耦合）

/// 取当前 SurfaceViewController 实例。用 NSClassFromString + methodForSelector
/// 而不是 #import "SurfaceViewController.h"：
///   1. GameUI 不在 gen_xcodeproj.py 的自动收录范围里，少一个跨目录头依赖，
///      将来工程生成器出问题时的爆炸半径更小；
///   2. 宿主不存在（单元测试 / 预览）时返回 nil，不会链接失败。
static id A2GameMenuHostInstance(void) {
    Class cls = NSClassFromString(@"SurfaceViewController");
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"currentInstance");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:sel];
    return fn ? fn((id)cls, sel) : nil;
}

/// 取任意对象上的无参对象返回值方法（logOutputView 等）。
static id A2GameMenuGetObject(id target, NSString *selectorName) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[target methodForSelector:sel];
    return fn ? fn(target, sel) : nil;
}

/// 调一个无参 void 方法。返回是否真的调到了。
static BOOL A2GameMenuInvokeVoid(id target, NSString *selectorName) {
    if (!target) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL) = (void (*)(id, SEL))[target methodForSelector:sel];
    if (!fn) return NO;
    fn(target, sel);
    return YES;
}

/// 从视图沿响应链找宿主控制器（弹确认框用）。
static UIViewController *A2GameMenuHostController(UIView *view) {
    UIResponder *responder = view.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return view.window.rootViewController;
}

/// 渲染器的人类可读名。SurfaceViewController 的 FPS 初始化注释里说明
/// 环境变量 AMETHYST_RENDERER 是 JavaLauncher 启动时写入的权威值。
static NSString *A2GameMenuRendererDescription(void) {
    NSString *value = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    if (value.length == 0) return @"未知（由启动配置决定）";
    NSString *lower = value.lowercaseString;
    if ([lower containsString:@"moltenvk"]) return @"Vulkan · MoltenVK";
    if ([lower containsString:@"angle"])    return @"OpenGL ES · ANGLE";
    if ([lower containsString:@"gl4es"])    return @"OpenGL · gl4es";
    if ([lower containsString:@"osmesa"])   return @"OpenGL · OSMesa";
    return value.lastPathComponent;
}

#pragma mark - 菜单动作行

/// 一条可点击的菜单项：图标 + 标题 + 右侧箭头/无。
/// 用 UIControl 而不是 UIButton，方便自己控制 highlight 与无障碍语义。
@interface A2GameMenuActionRow : UIControl
@property (nonatomic, copy, nullable) NSString *identifier;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) BOOL destructive;
- (instancetype)initWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                  destructive:(BOOL)destructive;
- (void)applyTheme:(A2ColorScheme *)scheme;
@end

@implementation A2GameMenuActionRow

- (instancetype)initWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                  destructive:(BOOL)destructive {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.destructive = destructive;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = title;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17
                                                       weight:UIImageSymbolWeightRegular];
    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = title;
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.85;
    [self addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:48],
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22],
        [_iconView.heightAnchor constraintEqualToConstant:22],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-14],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = 10;
    self.layer.cornerCurve = kCACornerCurveContinuous;
}

- (void)applyTheme:(A2ColorScheme *)scheme {
    self.titleLabel.textColor = self.destructive ? scheme.cError : scheme.cOnSurface;
    self.iconView.tintColor = self.destructive ? scheme.cError : scheme.cOnSurfaceVariant;
    self.backgroundColor = UIColor.clearColor;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (!self.enabled) {
        self.alpha = 0.45;
        return;
    }
    self.alpha = highlighted ? 0.75 : 1.0;
    self.backgroundColor = highlighted
        ? [UIColor colorWithWhite:1.0 alpha:0.10]
        : UIColor.clearColor;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(nullable UIEvent *)event {
    [super beginTrackingWithTouch:touch withEvent:event];
    if (self.enabled) self.highlighted = YES;
    return YES;
}

- (void)endTrackingWithTouch:(nullable UITouch *)touch withEvent:(nullable UIEvent *)event {
    [super endTrackingWithTouch:touch withEvent:event];
    self.highlighted = NO;
}

- (void)cancelTrackingWithEvent:(nullable UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    self.highlighted = NO;
}

@end

#pragma mark - A2GameMenuOverlay

@interface A2GameMenuOverlay ()
@property (nonatomic, strong) UIView *ball;
@property (nonatomic, strong) UIImageView *ballIcon;
@property (nonatomic, strong) UILabel *statsLabel;

/// 展开时的全屏遮罩：吞掉所有触摸，点一下收起。
@property (nonatomic, strong) UIView *scrim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *panelHeader;
@property (nonatomic, strong) UILabel *panelTitleLabel;
@property (nonatomic, strong) UILabel *panelSubtitleLabel;
@property (nonatomic, strong) UIButton *panelCloseButton;
@property (nonatomic, strong) UIScrollView *panelScroll;
@property (nonatomic, strong) UIStackView *panelStack;

@property (nonatomic, strong) UIPanGestureRecognizer *ballPanGesture;
@property (nonatomic, strong) UILongPressGestureRecognizer *ballLongPressGesture;

@property (nonatomic, assign, readwrite, getter=isExpanded) BOOL expanded;
/// 球心落在屏幕左半还是右半。只用于统计文字与面板的左右翻转，
/// 每次 layout / 拖动都由实际 x 现算，不单独持久化。
@property (nonatomic, assign) BOOL sideIsRight;
/// 归一化球心（0~1）。布局时反算成点，拖动/吸附结束时写回。
@property (nonatomic, assign) CGFloat normalizedX;
@property (nonatomic, assign) CGFloat normalizedY;
/// 当前球心。拖动时以它为准；布局时由 normalizedX/Y 反算。
@property (nonatomic, assign) CGPoint ballCenter;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) BOOL dragging;

/// 触摸跟踪（唯一的 UIPanGestureRecognizer 只在移动超过 slop 后才会
/// Began；纯轻点不会触发它的 Ended，所以点击判定放在视图的触摸回调里）。
@property (nonatomic, assign) CGPoint ballTouchStart;
@property (nonatomic, assign) BOOL ballTouchTracking;
@property (nonatomic, assign) BOOL ballTouchMoved;
/// 长按已经消费了这次触摸：松手时不要再当点击。
@property (nonatomic, assign) BOOL longPressConsumed;

/// 首次布局完成标志。明确用布尔量，不用 CGPointZero 猜 ——
/// 用户把球拖到左上角 (0,0) 是合法位置。
@property (nonatomic, assign) BOOL positionInitialized;
@property (nonatomic, assign) BOOL scheduledDeferredLayout;

@property (nonatomic, assign) CGFloat storedDiameter;
@property (nonatomic, assign) CGFloat storedOpacity;
@property (nonatomic, assign) BOOL storedShowsFPS;
@property (nonatomic, assign) BOOL storedShowsMemory;
@property (nonatomic, assign) double lastFPS;
@property (nonatomic, assign) double lastMemoryMB;

@property (nonatomic, strong, nullable) UILabel *opacityValueLabel;
@property (nonatomic, strong, nullable) UILabel *diameterValueLabel;

- (void)commonInit;
- (void)buildScrim;
- (void)buildBall;
- (void)buildStatsLabel;
- (void)buildPanel;
- (void)rebuildPanelContent;
- (void)layoutBallAndStats;
- (void)layoutPanel;
- (void)refreshStatsLabel;
- (void)positionStatsLabel;
- (void)refreshBallGeometry;
- (void)setBallIconExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)loadPreferences;
- (void)persistPreferences;
- (UIEdgeInsets)effectiveSafeInsets;
- (void)snapToNearestEdgeAnimated:(BOOL)animated;
- (void)applyThemeToRows:(A2ColorScheme *)scheme;
- (NSString *)currentResolutionDescription;

- (void)handleBallTap;
- (void)handleBallPan:(UIPanGestureRecognizer *)gesture;
- (void)handleBallLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleScrimTap;
- (void)handleActionRow:(A2GameMenuActionRow *)row;
- (void)handleFPSSwitch:(UISwitch *)sender;
- (void)handleMemorySwitch:(UISwitch *)sender;
- (void)handleOpacitySlider:(UISlider *)sender;
- (void)handleDiameterSlider:(UISlider *)sender;
- (void)handleThemeChanged:(NSNotification *)note;
- (void)confirmForceClose;
- (void)toggleLogOutput;

- (UIView *)makeSectionLabel:(NSString *)text;
- (UIView *)makeSwitchRowWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                                on:(BOOL)on
                            action:(SEL)action;
- (UIView *)makeSliderRowWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                            minimum:(CGFloat)minimum
                            maximum:(CGFloat)maximum
                              value:(CGFloat)value
                          valueText:(NSString *)valueText
                            action:(SEL)action
                       valueLabelOut:(UILabel *__strong *)valueLabelOut;
- (UIView *)makeInfoRowWithTitle:(NSString *)title value:(NSString *)value;
- (void)addActionRowWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                  identifier:(NSString *)identifier
                  destructive:(BOOL)destructive;
@end

@implementation A2GameMenuOverlay

#pragma mark - 生命周期

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (void)commonInit {
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = NO;
    _visible = YES;   // 旧实现的默认状态：创建即可见（alpha/交互仍由 setVisible: 控制）

    // 先读偏好，再建视图 —— 首帧就落在用户上次的位置/大小上，
    // 避免「先闪一下默认位置再跳过去」。
    [self loadPreferences];

    [self buildScrim];
    [self buildPanel];
    [self buildStatsLabel];
    [self buildBall];

    [self applyTheme];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleThemeChanged:)
                                                 name:A2ThemeDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 构件

- (void)buildScrim {
    _scrim = [[UIView alloc] initWithFrame:self.bounds];
    _scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    _scrim.hidden = YES;
    _scrim.isAccessibilityElement = NO;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleScrimTap)];
    [_scrim addGestureRecognizer:tap];
    [self addSubview:_scrim];
}

- (void)buildBall {
    _ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _storedDiameter, _storedDiameter)];
    _ball.layer.cornerRadius = _storedDiameter / 2.0;
    _ball.layer.cornerCurve = kCACornerCurveContinuous;
    _ball.layer.borderWidth = 1.0;
    _ball.layer.shadowColor = UIColor.blackColor.CGColor;
    _ball.layer.shadowOpacity = 0.35;
    _ball.layer.shadowRadius = 6;
    _ball.layer.shadowOffset = CGSizeMake(0, 2);
    _ball.isAccessibilityElement = YES;
    _ball.accessibilityTraits = UIAccessibilityTraitButton;
    _ball.accessibilityLabel = @"游戏菜单";
    _ball.accessibilityHint = @"轻点展开，拖动移动，长按编辑控件";

    _ballIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _ballIcon.contentMode = UIViewContentModeScaleAspectFit;
    _ballIcon.userInteractionEnabled = NO;
    [_ball addSubview:_ballIcon];
    _ball.alpha = _storedOpacity;
    [self refreshBallGeometry];

    // ★ 只挂一个拖动手势 ★
    // 不再同时挂 UITapGestureRecognizer —— 两个手势互相 requireToFail
    // 会让轻点被拖手势拖住，ZL2 的做法是一个 awaitEachGesture 里
    // 同时判定「移动超阈值 = 拖 / 未超 = 点」。这里用：
    //   · UIPanGestureRecognizer：只负责拖动与阈值判定
    //   · 视图 touchesBegan/Moved/Ended：负责纯轻点（pan 对静止点不 Began）
    // 两者共享同一个 6pt 阈值，不存在第二个点击手势。
    _ballPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                              action:@selector(handleBallPan:)];
    _ballPanGesture.maximumNumberOfTouches = 1;
    [_ball addGestureRecognizer:_ballPanGesture];

    _ballLongPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleBallLongPress:)];
    _ballLongPressGesture.minimumPressDuration = 0.6;
    [_ball addGestureRecognizer:_ballLongPressGesture];

    [self addSubview:_ball];
    [self setBallIconExpanded:NO animated:NO];
}

- (void)buildStatsLabel {
    _statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    _statsLabel.textAlignment = NSTextAlignmentRight;
    _statsLabel.userInteractionEnabled = YES;   // 让 hitTest 的返回结果稳定吞掉触摸
    _statsLabel.hidden = YES;
    _statsLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _statsLabel.layer.shadowOpacity = 0.55;
    _statsLabel.layer.shadowRadius = 2;
    [self addSubview:_statsLabel];
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.hidden = YES;
    _panel.layer.cornerRadius = kA2PanelCornerRadius;
    _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.35;
    _panel.layer.shadowRadius = 16;
    _panel.layer.shadowOffset = CGSizeMake(0, 8);
    [self addSubview:_panel];

    // ---- 头部：标题 + 副标题 + 关闭 ----
    _panelHeader = [[UIView alloc] initWithFrame:CGRectZero];
    _panelHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:_panelHeader];

    _panelTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _panelTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _panelTitleLabel.text = @"游戏菜单";
    _panelTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_panelHeader addSubview:_panelTitleLabel];

    _panelSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _panelSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _panelSubtitleLabel.text = @"拖动浮球移动 · 长按编辑控件";
    _panelSubtitleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _panelSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    _panelSubtitleLabel.minimumScaleFactor = 0.8;
    [_panelHeader addSubview:_panelSubtitleLabel];

    _panelCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _panelCloseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_panelCloseButton setImage:[UIImage systemImageNamed:@"xmark"]
                       forState:UIControlStateNormal];
    _panelCloseButton.accessibilityLabel = @"收起菜单";
    [_panelCloseButton addTarget:self
                          action:@selector(handleBallTap)
                forControlEvents:UIControlEventTouchUpInside];
    [_panelHeader addSubview:_panelCloseButton];

    // ---- 内容区：可滚动，避免横屏高度不够时切掉最后几项 ----
    _panelScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _panelScroll.showsVerticalScrollIndicator = YES;
    _panelScroll.alwaysBounceVertical = NO;
    _panelScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [_panel addSubview:_panelScroll];

    _panelStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _panelStack.translatesAutoresizingMaskIntoConstraints = NO;
    _panelStack.axis = UILayoutConstraintAxisVertical;
    _panelStack.alignment = UIStackViewAlignmentFill;
    _panelStack.spacing = 2.0;
    _panelStack.layoutMarginsRelativeArrangement = YES;
    _panelStack.layoutMargins = UIEdgeInsetsMake(4, 8, 12, 8);
    [_panelScroll addSubview:_panelStack];

    [NSLayoutConstraint activateConstraints:@[
        [_panelHeader.topAnchor constraintEqualToAnchor:_panel.topAnchor],
        [_panelHeader.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_panelHeader.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_panelHeader.heightAnchor constraintEqualToConstant:kA2PanelHeaderHeight],

        [_panelTitleLabel.leadingAnchor constraintEqualToAnchor:_panelHeader.leadingAnchor constant:16],
        [_panelTitleLabel.topAnchor constraintEqualToAnchor:_panelHeader.topAnchor constant:11],
        [_panelTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_panelCloseButton.leadingAnchor constant:-8],

        [_panelSubtitleLabel.leadingAnchor constraintEqualToAnchor:_panelTitleLabel.leadingAnchor],
        [_panelSubtitleLabel.topAnchor constraintEqualToAnchor:_panelTitleLabel.bottomAnchor constant:2],
        [_panelSubtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_panelCloseButton.leadingAnchor constant:-8],

        [_panelCloseButton.trailingAnchor constraintEqualToAnchor:_panelHeader.trailingAnchor constant:-8],
        [_panelCloseButton.centerYAnchor constraintEqualToAnchor:_panelHeader.centerYAnchor],
        [_panelCloseButton.widthAnchor constraintEqualToConstant:32],
        [_panelCloseButton.heightAnchor constraintEqualToConstant:32],

        [_panelScroll.topAnchor constraintEqualToAnchor:_panelHeader.bottomAnchor],
        [_panelScroll.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_panelScroll.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_panelScroll.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor],

        [_panelStack.topAnchor constraintEqualToAnchor:_panelScroll.contentLayoutGuide.topAnchor],
        [_panelStack.leadingAnchor constraintEqualToAnchor:_panelScroll.contentLayoutGuide.leadingAnchor],
        [_panelStack.trailingAnchor constraintEqualToAnchor:_panelScroll.contentLayoutGuide.trailingAnchor],
        [_panelStack.bottomAnchor constraintEqualToAnchor:_panelScroll.contentLayoutGuide.bottomAnchor],
        [_panelStack.widthAnchor constraintEqualToAnchor:_panelScroll.frameLayoutGuide.widthAnchor],
    ]];
}

#pragma mark - 布局

- (UIEdgeInsets)effectiveSafeInsets {
    UIEdgeInsets insets = self.safeAreaInsets;
    if (UIEdgeInsetsEqualToEdgeInsets(insets, UIEdgeInsetsZero) && self.window) {
        insets = self.window.safeAreaInsets;
    }
    return insets;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    _scrim.frame = self.bounds;

    // 每次布局都按归一化坐标重新钳制：
    //   · 首帧 safeAreaInsets 可能还是 0；
    //   · 旋转/分屏/换设备后宽高变化；
    //   · 球可能被存到了越界比例上。
    // 因此这里不做「只算一次」的优化，保证任何一帧都不会跑出安全区。
    [self layoutBallAndStats];
    if (self.expanded) [self layoutPanel];

    // 安全区/窗口尺寸可能在本帧之后才稳定（SurfaceViewController 的
    // gameMenuOverlay 是在 viewDidLoad 里挂的）。延迟一帧再钳一次，
    // 用显式布尔量保证只补一次，不靠 CGPointZero 猜首次。
    if (!self.positionInitialized && self.bounds.size.width > 0) {
        self.positionInitialized = YES;
        if (!self.scheduledDeferredLayout) {
            self.scheduledDeferredLayout = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            });
        }
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window == nil) return;
    // 真正进 window 后再补一帧，覆盖「viewDidLoad 时 safeArea 还是 0」。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    });
}

- (void)layoutBallAndStats {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;

    UIEdgeInsets safe = [self effectiveSafeInsets];
    CGFloat half = _storedDiameter / 2.0;
    CGFloat minX = safe.left + kA2EdgeInset + half;
    CGFloat maxX = width - safe.right - kA2EdgeInset - half;
    CGFloat minY = safe.top + kA2EdgeInset + half;
    CGFloat maxY = height - safe.bottom - kA2EdgeInset - half;

    if (maxX < minX) { minX = maxX = width / 2.0; }
    if (maxY < minY) { minY = maxY = height / 2.0; }

    if (!self.dragging) {
        // 归一化比例 → 当前安全区内的点。旋转后自动跟着新宽高重算。
        CGFloat nx = MAX(0.0, MIN(1.0, _normalizedX));
        CGFloat ny = MAX(0.0, MIN(1.0, _normalizedY));
        CGFloat x = minX + nx * MAX(0.0, maxX - minX);
        CGFloat y = minY + ny * MAX(0.0, maxY - minY);
        self.ballCenter = CGPointMake(x, y);
        _sideIsRight = x >= width / 2.0;
    } else {
        // 拖动中：只按安全区钳制，不重新解释归一化坐标
        self.ballCenter = CGPointMake(MAX(minX, MIN(maxX, self.ballCenter.x)),
                                      MAX(minY, MIN(maxY, self.ballCenter.y)));
    }

    _ball.bounds = CGRectMake(0, 0, _storedDiameter, _storedDiameter);
    _ball.center = self.ballCenter;
    [self refreshBallGeometry];

    [self positionStatsLabel];
}

- (void)layoutPanel {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;

    UIEdgeInsets safe = [self effectiveSafeInsets];
    CGFloat maxWidth = MIN(kA2PanelMaxWidth, width - safe.left - safe.right - 16.0);
    CGFloat panelWidth = MAX(200.0, maxWidth);
    CGFloat maxHeight = MAX(160.0, height - safe.top - safe.bottom - 16.0);

    // 先给面板一个宽度，让内部 stack 完成测量；再按内容高度收紧面板，
    // 避免只有两三项时面板拖着一大块空白。
    _panel.frame = CGRectMake(0, 0, panelWidth, maxHeight);
    [_panel layoutIfNeeded];
    CGFloat measured = _panelScroll.contentSize.height;
    CGFloat panelHeight = measured > 20.0
        ? MIN(maxHeight, measured + kA2PanelHeaderHeight + 8.0)
        : MIN(maxHeight, 380.0);

    CGFloat ballHalf = _storedDiameter / 2.0;
    CGFloat x;
    if (_sideIsRight) {
        x = self.ballCenter.x - ballHalf - kA2BallGap - panelWidth;
    } else {
        x = self.ballCenter.x + ballHalf + kA2BallGap;
    }
    x = MAX(safe.left + 8.0, MIN(width - safe.right - 8.0 - panelWidth, x));

    CGFloat y = self.ballCenter.y - 40.0;
    y = MAX(safe.top + 8.0, MIN(height - safe.bottom - 8.0 - panelHeight, y));

    _panel.frame = CGRectMake(x, y, panelWidth, panelHeight);
    _panel.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:_panel.bounds
                                   cornerRadius:kA2PanelCornerRadius].CGPath;
}

- (void)refreshBallGeometry {
    CGFloat diameter = _storedDiameter;
    _ball.layer.cornerRadius = diameter / 2.0;
    _ball.layer.shadowPath =
        [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)].CGPath;
    CGFloat inset = MAX(8.0, diameter * 0.22);
    _ballIcon.frame = CGRectInset(CGRectMake(0, 0, diameter, diameter), inset, inset);
}

- (void)positionStatsLabel {
    if (!_statsLabel || _statsLabel.hidden) return;

    CGFloat width = MIN(220.0, MAX(120.0, self.bounds.size.width * 0.55));
    CGSize fit = [_statsLabel sizeThatFits:CGSizeMake(width, 24)];
    CGFloat labelWidth = MAX(120.0, MIN(width, fit.width + 6.0));
    CGFloat labelHeight = 20.0;
    CGFloat gap = 6.0;

    CGFloat x = _sideIsRight
        ? self.ballCenter.x - _storedDiameter / 2.0 - gap - labelWidth
        : self.ballCenter.x + _storedDiameter / 2.0 + gap;
    x = MAX(4.0, MIN(self.bounds.size.width - labelWidth - 4.0, x));

    _statsLabel.frame = CGRectMake(x, self.ballCenter.y - labelHeight / 2.0,
                                   labelWidth, labelHeight);
    _statsLabel.textAlignment = _sideIsRight ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

#pragma mark - 抚摸 / 点击 / 拖拽

- (void)handleBallTap {
    [self toggle];
}

- (void)handleScrimTap {
    [self collapse];
}

- (void)handleBallLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    // 长按已经打开了编辑器，松手时不能再判成一次轻点。
    self.longPressConsumed = YES;
    if (self.expanded) [self collapse];

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    if (self.onOpenEditor) self.onOpenEditor();
}

- (void)handleBallPan:(UIPanGestureRecognizer *)gesture {
    // 展开时浮球不拖动 —— 与 ZL2 一致：菜单打开后，球只负责关闭。
    if (self.expanded) return;

    UIGestureRecognizerState state = gesture.state;
    CGPoint translation = [gesture translationInView:self];

    if (state == UIGestureRecognizerStateBegan) {
        self.dragging = NO;
        self.dragStartCenter = _ball.center;
        self.ballCenter = _ball.center;
    }

    // 唯一的位移阈值：6pt 内算点，超过才算拖。
    // UIPanGestureRecognizer 自己对 Began 有 ~10pt 的系统 slop，所以
    // 真正「没动过」的轻点不会走到这里，而是由 touchesEnded 判定；
    // 这一层阈值负责「pan 已经开始但确实只动了几像素」的情况。
    if (state == UIGestureRecognizerStateChanged ||
        state == UIGestureRecognizerStateBegan) {
        if (!self.dragging &&
            hypot(translation.x, translation.y) > kA2TapDistance) {
            self.dragging = YES;
        }

        if (self.dragging) {
            UIEdgeInsets safe = [self effectiveSafeInsets];
            CGFloat half = _storedDiameter / 2.0;
            CGFloat minX = safe.left + kA2EdgeInset + half;
            CGFloat maxX = self.bounds.size.width - safe.right - kA2EdgeInset - half;
            CGFloat minY = safe.top + kA2EdgeInset + half;
            CGFloat maxY = self.bounds.size.height - safe.bottom - kA2EdgeInset - half;

            CGPoint center = CGPointMake(self.dragStartCenter.x + translation.x,
                                         self.dragStartCenter.y + translation.y);
            center.x = MAX(minX, MIN(maxX, center.x));
            center.y = MAX(minY, MIN(maxY, center.y));
            self.ballCenter = center;
            _ball.center = center;
            // 拖动时实时同步侧别、归一化坐标，统计文字跟着换边
            _sideIsRight = center.x >= self.bounds.size.width / 2.0;
            _normalizedX = (maxX - minX) > 0.5 ? (center.x - minX) / (maxX - minX) : 0.0;
            _normalizedY = (maxY - minY) > 0.5 ? (center.y - minY) / (maxY - minY) : 0.0;
            [self positionStatsLabel];
        }
    }

    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        BOOL wasDragging = self.dragging;
        self.dragging = NO;

        if (wasDragging) {
            [self snapToNearestEdgeAnimated:YES];
        } else if (state == UIGestureRecognizerStateEnded && !self.longPressConsumed) {
            // pan 已开始但位移没超过 6pt：当作点击。
            [self toggle];
        }
    }
}

/// 松手吸附到最近的左右边缘。
/// ZL2 的 FloatingBall 只做边界钳制；「吸附左右边」来自 Air2 原实现与
/// GameMenuOverlay 的设计说明，这里保留并补上回弹动画。
- (void)snapToNearestEdgeAnimated:(BOOL)animated {
    UIEdgeInsets safe = [self effectiveSafeInsets];
    CGFloat width = self.bounds.size.width;
    CGFloat half = _storedDiameter / 2.0;
    CGFloat minX = safe.left + kA2EdgeInset + half;
    CGFloat maxX = width - safe.right - kA2EdgeInset - half;
    CGFloat minY = safe.top + kA2EdgeInset + half;
    CGFloat maxY = self.bounds.size.height - safe.bottom - kA2EdgeInset - half;

    BOOL toRight = self.ballCenter.x >= width / 2.0;
    CGFloat targetX = toRight ? maxX : minX;
    CGFloat clampedY = MAX(minY, MIN(maxY, self.ballCenter.y));
    _sideIsRight = toRight;
    // 吸附后是明确的 0 或 1；纵向保留比例。
    _normalizedX = toRight ? 1.0 : 0.0;
    _normalizedY = (maxY - minY) > 0.5 ? (clampedY - minY) / (maxY - minY) : 0.0;

    CGPoint target = CGPointMake(targetX, clampedY);
    // 松手当下先落盘一次：即便回弹动画被下一次触摸打断，位置也不丢。
    [self persistPreferences];

    void (^apply)(void) = ^{
        self.ballCenter = target;
        self.ball.center = target;
        [self positionStatsLabel];
    };

    if (!animated) {
        apply();
        [self persistPreferences];
        return;
    }

    [UIView animateWithDuration:0.30
                          delay:0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState
                                | UIViewAnimationOptionAllowUserInteraction
                     animations:apply
                     completion:^(BOOL finished) {
        [self persistPreferences];
    }];
}

#pragma mark - 展开 / 收起

- (void)toggle {
    if (self.expanded) [self collapse];
    else [self expand];
}

- (void)expand {
    if (self.expanded) return;

    self.expanded = YES;
    _ballPanGesture.enabled = NO;

    // 每次展开都重建菜单项：宿主 delegate 可能在启动过程中才接线，
    // 渲染器信息也要按当前进程环境刷新。
    [self rebuildPanelContent];
    _scrim.hidden = NO;
    _panel.hidden = NO;
    [self setNeedsLayout];
    [self layoutIfNeeded];

    _scrim.alpha = 0.0;
    _panel.alpha = 0.0;
    CGAffineTransform from = CGAffineTransformMakeScale(0.96, 0.96);
    from = CGAffineTransformTranslate(from, _sideIsRight ? 18.0 : -18.0, 0);
    _panel.transform = from;

    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_scrim.alpha = 1.0;
        self->_panel.alpha = 1.0;
        self->_panel.transform = CGAffineTransformIdentity;
        self->_ball.transform = CGAffineTransformMakeScale(1.06, 1.06);
    } completion:nil];

    [self setBallIconExpanded:YES animated:YES];
    _ball.accessibilityLabel = @"游戏菜单，已展开";
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, _panel);
}

- (void)collapse {
    if (!self.expanded) return;

    self.expanded = NO;
    _ballPanGesture.enabled = YES;

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self->_scrim.alpha = 0.0;
        self->_panel.alpha = 0.0;
        self->_panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
        self->_ball.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        if (self.expanded) return;
        self->_panel.hidden = YES;
        self->_scrim.hidden = YES;
        self->_panel.transform = CGAffineTransformIdentity;
    }];

    [self setBallIconExpanded:NO animated:YES];
    _ball.accessibilityLabel = @"游戏菜单，已收起";
}

- (void)setBallIconExpanded:(BOOL)expanded animated:(BOOL)animated {
    CGFloat pointSize = MAX(15.0, _storedDiameter * 0.46);
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:(expanded ? @"xmark" : @"gearshape.fill")
                             withConfiguration:config];

    if (!animated || !_ballIcon.image) {
        _ballIcon.image = image;
        return;
    }

    [UIView transitionWithView:_ballIcon
                      duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self->_ballIcon.image = image;
    } completion:nil];
}

#pragma mark - 菜单内容

- (void)rebuildPanelContent {
    if (!_panelStack) return;

    for (UIView *view in _panelStack.arrangedSubviews.copy) {
        [_panelStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    _opacityValueLabel = nil;
    _diameterValueLabel = nil;

    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    id<A2GameMenuDelegate> delegate = self.delegate;
    BOOL hasHostLog = (A2GameMenuGetObject(A2GameMenuHostInstance(), @"logOutputView") != nil);

    // ---- 操作 ----
    [_panelStack addArrangedSubview:[self makeSectionLabel:@"操作"]];

    [self addActionRowWithTitle:@"编辑控件"
                         symbol:@"slider.horizontal.3"
                     identifier:@"edit"
                    destructive:NO];

    if ([delegate respondsToSelector:@selector(gameMenuSendKeycode)]) {
        [self addActionRowWithTitle:@"发送键码"
                             symbol:@"keyboard"
                         identifier:@"keycode"
                        destructive:NO];
    }
    if ([delegate respondsToSelector:@selector(gameMenuToggleLog)] || hasHostLog) {
        [self addActionRowWithTitle:@"显示日志"
                             symbol:@"terminal.fill"
                         identifier:@"log"
                        destructive:NO];
    }
    if ([delegate respondsToSelector:@selector(gameMenuOpenTerracotta)]) {
        [self addActionRowWithTitle:@"陶瓦联机"
                             symbol:@"network"
                         identifier:@"terracotta"
                        destructive:NO];
    }
    if ([delegate respondsToSelector:@selector(gameMenuRefreshWindowSize)]) {
        [self addActionRowWithTitle:@"重设窗口尺寸"
                             symbol:@"arrow.up.left.and.arrow.down.right"
                         identifier:@"resize"
                        destructive:NO];
    }
    if ([delegate respondsToSelector:@selector(gameMenuReturnToLauncher)]) {
        [self addActionRowWithTitle:@"返回启动器"
                             symbol:@"house.fill"
                         identifier:@"launcher"
                        destructive:NO];
    }
    // 破坏性动作：宿主必须自己实现 -gameMenuForceClose（确认/清理在宿主侧），
    // 否则不显示，避免出现「点了没反应」或越权杀进程。
    if ([delegate respondsToSelector:@selector(gameMenuForceClose)]) {
        [self addActionRowWithTitle:@"退出游戏"
                             symbol:@"xmark.circle.fill"
                         identifier:@"exit"
                        destructive:YES];
    }

    // ---- 显示 ----
    [_panelStack addArrangedSubview:[self makeSectionLabel:@"显示"]];

    UIView *fpsRow = [self makeSwitchRowWithTitle:@"帧率显示"
                                           symbol:@"speedometer"
                                               on:self.showsFPS
                                           action:@selector(handleFPSSwitch:)];
    [_panelStack addArrangedSubview:fpsRow];

    UIView *memoryRow = [self makeSwitchRowWithTitle:@"内存显示"
                                              symbol:@"memorychip"
                                                  on:self.showsMemory
                                              action:@selector(handleMemorySwitch:)];
    [_panelStack addArrangedSubview:memoryRow];

    NSString *opacityText = [NSString stringWithFormat:@"%.0f%%", self.ballOpacity * 100.0];
    UIView *opacityRow = [self makeSliderRowWithTitle:@"悬浮球不透明度"
                                               symbol:@"circle.lefthalf.filled"
                                              minimum:0.2
                                              maximum:1.0
                                                value:self.ballOpacity
                                            valueText:opacityText
                                               action:@selector(handleOpacitySlider:)
                                        valueLabelOut:&_opacityValueLabel];
    [_panelStack addArrangedSubview:opacityRow];

    NSString *diameterText = [NSString stringWithFormat:@"%.0f pt", self.ballDiameter];
    UIView *diameterRow = [self makeSliderRowWithTitle:@"悬浮球大小"
                                                symbol:@"arrow.up.left.and.arrow.down.right"
                                               minimum:kA2BallMinDiameter
                                               maximum:kA2BallMaxDiameter
                                                 value:self.ballDiameter
                                             valueText:diameterText
                                                action:@selector(handleDiameterSlider:)
                                         valueLabelOut:&_diameterValueLabel];
    [_panelStack addArrangedSubview:diameterRow];

    // ---- 信息（只读） ----
    [_panelStack addArrangedSubview:[self makeSectionLabel:@"信息"]];
    [_panelStack addArrangedSubview:[self makeInfoRowWithTitle:@"渲染器"
                                                        value:A2GameMenuRendererDescription()]];
    [_panelStack addArrangedSubview:[self makeInfoRowWithTitle:@"分辨率"
                                                        value:[self currentResolutionDescription]]];

    [self applyThemeToRows:scheme];
}

- (void)applyThemeToRows:(A2ColorScheme *)scheme {
    for (UIView *view in _panelStack.arrangedSubviews) {
        if ([view isKindOfClass:A2GameMenuActionRow.class]) {
            [(A2GameMenuActionRow *)view applyTheme:scheme];
        }
    }
}

- (void)addActionRowWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                  identifier:(NSString *)identifier
                  destructive:(BOOL)destructive {
    A2GameMenuActionRow *row = [[A2GameMenuActionRow alloc] initWithTitle:title
                                                                   symbol:symbol
                                                              destructive:destructive];
    row.identifier = identifier;
    [row addTarget:self
            action:@selector(handleActionRow:)
  forControlEvents:UIControlEventTouchUpInside];
    [_panelStack addArrangedSubview:row];
}

- (void)handleActionRow:(A2GameMenuActionRow *)row {
    NSString *identifier = row.identifier;
    if (identifier.length == 0) return;

    if ([identifier isEqualToString:@"edit"]) {
        [self collapse];
        if (self.onOpenEditor) self.onOpenEditor();
        return;
    }

    if ([identifier isEqualToString:@"log"]) {
        [self collapse];
        [self toggleLogOutput];
        return;
    }

    if ([identifier isEqualToString:@"keycode"]) {
        [self collapse];
        if ([self.delegate respondsToSelector:@selector(gameMenuSendKeycode)]) {
            [self.delegate gameMenuSendKeycode];
        }
        return;
    }

    if ([identifier isEqualToString:@"terracotta"]) {
        [self collapse];
        if ([self.delegate respondsToSelector:@selector(gameMenuOpenTerracotta)]) {
            [self.delegate gameMenuOpenTerracotta];
        }
        return;
    }

    if ([identifier isEqualToString:@"resize"]) {
        [self collapse];
        if ([self.delegate respondsToSelector:@selector(gameMenuRefreshWindowSize)]) {
            [self.delegate gameMenuRefreshWindowSize];
        }
        return;
    }

    if ([identifier isEqualToString:@"launcher"]) {
        [self collapse];
        if ([self.delegate respondsToSelector:@selector(gameMenuReturnToLauncher)]) {
            [self.delegate gameMenuReturnToLauncher];
        }
        return;
    }

    if ([identifier isEqualToString:@"exit"]) {
        [self confirmForceClose];
        return;
    }
}

- (void)toggleLogOutput {
    if ([self.delegate respondsToSelector:@selector(gameMenuToggleLog)]) {
        [self.delegate gameMenuToggleLog];
        return;
    }
    // 宿主兜底：PLLogOutputView -actionToggleLogOutput 就是游戏内日志面板的开关
    // （PLLogOutputView.m:147）。宿主没有设 delegate 时这条路径仍然可用。
    id host = A2GameMenuHostInstance();
    id logView = A2GameMenuGetObject(host, @"logOutputView");
    if (!A2GameMenuInvokeVoid(logView, @"actionToggleLogOutput")) {
        NSLog(@"[A2GameMenuOverlay] 日志面板不可用：host=%@ logView=%@",
              NSStringFromClass([host class]), NSStringFromClass([logView class]));
    }
}

- (void)confirmForceClose {
    [self collapse];

    void (^perform)(void) = ^{
        if ([self.delegate respondsToSelector:@selector(gameMenuForceClose)]) {
            [self.delegate gameMenuForceClose];
        }
    };

    UIViewController *host = A2GameMenuHostController(self);
    if (!host) {
        perform();
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"退出游戏"
                                            message:@"当前游戏进度会丢失，确定要退出吗？"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"退出"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        perform();
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 菜单行工厂

- (UIView *)makeSectionLabel:(NSString *)text {
    UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
    box.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [box addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [box.heightAnchor constraintEqualToConstant:30],
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
        [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2],
    ]];
    return box;
}

- (UIView *)makeSwitchRowWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                                on:(BOOL)on
                            action:(SEL)action {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:17
                                                        weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
                                                                   withConfiguration:config]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = scheme.cOnSurfaceVariant;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = scheme.cOnSurface;
    [row addSubview:label];

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.onTintColor = scheme.cPrimary;
    toggle.on = on;
    toggle.accessibilityLabel = title;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:toggle];
    toggle.transform = CGAffineTransformMakeScale(0.82, 0.82);

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:50],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-8],
        [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (UIView *)makeSliderRowWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                           minimum:(CGFloat)minimum
                           maximum:(CGFloat)maximum
                             value:(CGFloat)value
                         valueText:(NSString *)valueText
                            action:(SEL)action
                     valueLabelOut:(UILabel *__strong *)valueLabelOut {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:16
                                                        weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
                                                                   withConfiguration:config]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = scheme.cOnSurfaceVariant;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = scheme.cOnSurface;
    [row addSubview:label];

    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = valueText;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    valueLabel.textColor = scheme.cOnSurfaceVariant;
    valueLabel.textAlignment = NSTextAlignmentRight;
    [row addSubview:valueLabel];
    if (valueLabelOut) *valueLabelOut = valueLabel;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = (float)minimum;
    slider.maximumValue = (float)maximum;
    slider.value = (float)value;
    slider.minimumTrackTintColor = scheme.cPrimary;
    slider.maximumTrackTintColor = scheme.cOutlineVariant;
    slider.accessibilityLabel = title;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:74],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:valueLabel.leadingAnchor constant:-8],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [valueLabel.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [slider.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
    ]];
    return row;
}

- (UIView *)makeInfoRowWithTitle:(NSString *)title value:(NSString *)value {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    titleLabel.textColor = scheme.cOnSurfaceVariant;
    [row addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    valueLabel.textColor = scheme.cOnSurface;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:40],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (NSString *)currentResolutionDescription {
    CGSize size = CGSizeZero;
    CGFloat scale = UIScreen.mainScreen.scale;

    if (self.gameLayer && self.gameLayer.bounds.size.width > 0) {
        size = self.gameLayer.bounds.size;
        if (self.gameLayer.contentsScale > 0) scale = self.gameLayer.contentsScale;
    } else {
        UIWindow *window = self.window ?: UIApplication.sharedApplication.windows.firstObject;
        size = window ? window.bounds.size : UIScreen.mainScreen.bounds.size;
    }

    if (size.width <= 0 || size.height <= 0) return @"未知";
    return [NSString stringWithFormat:@"%.0f × %.0f @%.0fx",
            size.width * scale, size.height * scale, scale];
}

#pragma mark - 开关 / 滑杆

- (void)handleFPSSwitch:(UISwitch *)sender {
    self.showsFPS = sender.isOn;
    if ([self.delegate respondsToSelector:@selector(gameMenuSetFPSDisplayMode:)]) {
        [self.delegate gameMenuSetFPSDisplayMode:
            (sender.isOn ? A2FPSDisplayModeAlways : A2FPSDisplayModeOff)];
    }
}

- (void)handleMemorySwitch:(UISwitch *)sender {
    self.showsMemory = sender.isOn;
    if ([self.delegate respondsToSelector:@selector(gameMenuSetShowMemory:)]) {
        [self.delegate gameMenuSetShowMemory:sender.isOn];
    }
}

- (void)handleOpacitySlider:(UISlider *)sender {
    self.ballOpacity = sender.value;
    self.opacityValueLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100.0];
}

- (void)handleDiameterSlider:(UISlider *)sender {
    self.ballDiameter = sender.value;
    self.diameterValueLabel.text = [NSString stringWithFormat:@"%.0f pt", sender.value];
}

#pragma mark - 触摸吞噬（关键）

// SurfaceViewController 在 -touchesBegan:withEvent: 里把所有冒上来的触摸
// 转成 ACTION_DOWN 发给游戏（SurfaceViewController.m:3377）。而 UIView 对
// 未实现的触摸方法是「沿响应链上抛」的，所以浮球/面板里的普通 UIView
// 即使 hitTest 命中了，也会把触摸冒泡到 VC，游戏仍然会收到一次点击。
//
// 这里把这四个方法截断，不调用 super：触摸到浮球/统计文字/面板/遮罩
// 就到此为止；没命中这些区域的触摸根本不会 hitTest 到本视图（返回 nil），
// 仍由下层 ctrlView / touchView 正常接收。效果与 ZL2 的
// PointerEventPass / consume 等价。
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // pan 手势要移动超过系统 slop 才会 Began，纯轻点只能靠这里判定。
    for (UITouch *touch in touches) {
        if (touch.view != _ball) continue;
        self.ballTouchStart = [touch locationInView:self];
        self.ballTouchTracking = YES;
        self.ballTouchMoved = NO;
        self.longPressConsumed = NO;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.ballTouchTracking) return;
    for (UITouch *touch in touches) {
        if (touch.view != _ball) continue;
        CGPoint point = [touch locationInView:self];
        if (hypot(point.x - self.ballTouchStart.x,
                  point.y - self.ballTouchStart.y) > kA2TapDistance) {
            self.ballTouchMoved = YES;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL shouldToggle = NO;
    for (UITouch *touch in touches) {
        if (touch.view != _ball) continue;
        if (self.ballTouchTracking && !self.ballTouchMoved && !self.longPressConsumed) {
            shouldToggle = YES;
        }
    }

    self.ballTouchTracking = NO;
    self.ballTouchMoved = NO;
    if (shouldToggle) [self toggle];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 被 pan / long press 抢走后 UIKit 会取消 view 上的触摸：
    // 这里只清状态，绝不能再 toggle（否则拖动结束会误开关菜单）。
    self.ballTouchTracking = NO;
    self.ballTouchMoved = NO;
}

#pragma mark - 命中测试（穿透规则）

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isUserInteractionEnabled || self.isHidden || self.alpha < 0.01) {
        return nil;
    }

    // 注意：浮球在展开动画里带 1.06 的 scale，UIView.frame 在非单位变换下
    // 语义不确定；命中区一律用 center + bounds 现算。
    BOOL ballHit = NO;
    if (_ball && !_ball.hidden) {
        CGRect hit = CGRectMake(_ball.center.x - _ball.bounds.size.width / 2.0 - 8.0,
                                _ball.center.y - _ball.bounds.size.height / 2.0 - 8.0,
                                _ball.bounds.size.width + 16.0,
                                _ball.bounds.size.height + 16.0);
        ballHit = CGRectContainsPoint(hit, point);
    }

    if (self.expanded) {
        // 球：命中区放大 8pt，方便手指按
        if (ballHit) return _ball;
        // 面板：交给 UIKit 继续找具体按钮（同样避开 transform 下的 frame）
        CGRect panelRect = CGRectMake(_panel.center.x - _panel.bounds.size.width / 2.0,
                                      _panel.center.y - _panel.bounds.size.height / 2.0,
                                      _panel.bounds.size.width,
                                      _panel.bounds.size.height);
        if (_panel && !_panel.hidden && CGRectContainsPoint(panelRect, point)) {
            CGPoint local = [self convertPoint:point toView:_panel];
            UIView *hit = [_panel hitTest:local withEvent:event];
            return hit ?: _panel;
        }
        // 其余区域：遮罩吞掉（点空白处收起），绝不能漏给游戏
        if (_scrim && !_scrim.hidden) return _scrim;
        return nil;
    }

    // 收起状态：只有球与统计文字吃触摸。
    // 与旧实现一致：其余点返回 nil，触摸继续下发到 ctrlView / touchView。
    if (ballHit) return _ball;
    if (_statsLabel && !_statsLabel.hidden) {
        CGRect hit = CGRectInset(_statsLabel.frame, -6.0, -6.0);
        if (CGRectContainsPoint(hit, point)) return _statsLabel;
    }
    return nil;
}

#pragma mark - 显示与统计

- (void)setVisible:(BOOL)visible {
    _visible = visible;
    self.userInteractionEnabled = visible;
    if (!visible) [self collapse];
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = visible ? 1.0 : 0.0;
    }];
}

- (void)updateFPS:(double)fps memoryUsageMB:(double)memoryMB {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateFPS:fps memoryUsageMB:memoryMB];
        });
        return;
    }

    self.lastFPS = MAX(0.0, fps);
    self.lastMemoryMB = MAX(0.0, memoryMB);
    [self refreshStatsLabel];
}

- (void)refreshStatsLabel {
    BOOL showFPS = self.showsFPS && self.lastFPS > 0.0;
    BOOL showMemory = self.showsMemory && self.lastMemoryMB > 0.0;

    NSMutableString *text = [NSMutableString string];
    if (showFPS) [text appendFormat:@"%.0f FPS", self.lastFPS];
    if (showMemory) {
        if (text.length) [text appendString:@"  ·  "];
        [text appendFormat:@"%.0f MB", self.lastMemoryMB];
    }

    _statsLabel.hidden = (text.length == 0);
    _statsLabel.text = text;
    [self positionStatsLabel];
}

#pragma mark - 属性

- (CGFloat)ballDiameter {
    return _storedDiameter;
}

- (void)setBallDiameter:(CGFloat)ballDiameter {
    CGFloat clamped = MAX(kA2BallMinDiameter, MIN(kA2BallMaxDiameter, ballDiameter));
    if (fabs(clamped - _storedDiameter) < 0.5) return;

    _storedDiameter = clamped;
    [self refreshBallGeometry];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self setBallIconExpanded:self.expanded animated:NO];
    [self persistPreferences];
}

- (CGFloat)ballOpacity {
    return _storedOpacity;
}

- (void)setBallOpacity:(CGFloat)ballOpacity {
    CGFloat clamped = MAX(0.2, MIN(1.0, ballOpacity));
    _storedOpacity = clamped;
    _ball.alpha = clamped;
    [self persistPreferences];
}

- (BOOL)showsFPS {
    return _storedShowsFPS;
}

- (void)setShowsFPS:(BOOL)showsFPS {
    if (_storedShowsFPS == showsFPS) return;
    _storedShowsFPS = showsFPS;
    [self refreshStatsLabel];
    [self persistPreferences];
}

- (BOOL)showsMemory {
    return _storedShowsMemory;
}

- (void)setShowsMemory:(BOOL)showsMemory {
    if (_storedShowsMemory == showsMemory) return;
    _storedShowsMemory = showsMemory;
    [self refreshStatsLabel];
    [self persistPreferences];
}

- (BOOL)pinnedToRightEdge {
    return _sideIsRight;
}

#pragma mark - 偏好

- (void)loadPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    // 默认落在右上角：x=1（右边缘安全区），y=0（顶部安全区）。
    _normalizedX = 1.0;
    _normalizedY = 0.0;

    id position = [defaults objectForKey:kA2BallPositionKey];
    if ([position isKindOfClass:NSString.class]) {
        NSArray<NSString *> *parts =
            [(NSString *)position componentsSeparatedByString:@","];
        if (parts.count >= 2) {
            double x = [parts[0] doubleValue];
            double y = [parts[1] doubleValue];
            _normalizedX = MAX(0.0, MIN(1.0, x));
            _normalizedY = MAX(0.0, MIN(1.0, y));
        }
    }

    id diameter = [defaults objectForKey:kA2BallDiameterKey];
    _storedDiameter = diameter
        ? MAX(kA2BallMinDiameter, MIN(kA2BallMaxDiameter, [diameter doubleValue]))
        : kA2BallDefaultDiameter;

    id opacity = [defaults objectForKey:kA2BallOpacityKey];
    _storedOpacity = opacity ? MAX(0.2, MIN(1.0, [opacity doubleValue])) : 0.9;

    id showsFPS = [defaults objectForKey:kA2BallShowsFPSKey];
    _storedShowsFPS = showsFPS ? [showsFPS boolValue] : YES;

    id showsMemory = [defaults objectForKey:kA2BallShowsMemoryKey];
    _storedShowsMemory = showsMemory ? [showsMemory boolValue] : YES;

    // 只按当前分辨率推导左/右，不持久化 side —— 旋转后由 layout 现算。
    _sideIsRight = _normalizedX >= 0.5;

    if (_ball) _ball.alpha = _storedOpacity;
}

- (void)persistPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *position = [NSString stringWithFormat:@"%.6f,%.6f",
                          MAX(0.0, MIN(1.0, _normalizedX)),
                          MAX(0.0, MIN(1.0, _normalizedY))];
    [defaults setObject:position forKey:kA2BallPositionKey];
    [defaults setDouble:_storedDiameter forKey:kA2BallDiameterKey];
    [defaults setDouble:_storedOpacity forKey:kA2BallOpacityKey];
    [defaults setBool:_storedShowsFPS forKey:kA2BallShowsFPSKey];
    [defaults setBool:_storedShowsMemory forKey:kA2BallShowsMemoryKey];
}

- (void)reloadPreferences {
    [self loadPreferences];
    if (_ball) {
        _ball.alpha = _storedOpacity;
        _ball.bounds = CGRectMake(0, 0, _storedDiameter, _storedDiameter);
        [self refreshBallGeometry];
    }
    [self setBallIconExpanded:self.expanded animated:NO];
    [self refreshStatsLabel];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)resetBallPosition {
    _normalizedX = 1.0;
    _normalizedY = 0.0;
    _sideIsRight = YES;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self persistPreferences];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    // 浮球：半透明主色圆 + 细描边，盖在游戏画面上不刺眼
    _ball.backgroundColor = [scheme.cPrimary colorWithAlphaComponent:0.92];
    _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    _ballIcon.tintColor = scheme.cOnPrimary;

    // 统计文字：游戏画面什么颜色都可能，白色 + 阴影最稳
    _statsLabel.textColor = UIColor.whiteColor;

    // 面板：MD3 surfaceContainerHigh，接近不透明保证可读
    _panel.backgroundColor = [scheme.cSurfaceContainerHigh colorWithAlphaComponent:0.96];
    _panel.layer.borderColor = [scheme.cOutlineVariant colorWithAlphaComponent:0.55].CGColor;
    _panelTitleLabel.textColor = scheme.cOnSurface;
    _panelSubtitleLabel.textColor = scheme.cOnSurfaceVariant;
    _panelCloseButton.tintColor = scheme.cOnSurfaceVariant;

    _scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];

    if (self.expanded) [self rebuildPanelContent];
}

- (void)handleThemeChanged:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyTheme];
        });
        return;
    }
    [self applyTheme];
}

@end
