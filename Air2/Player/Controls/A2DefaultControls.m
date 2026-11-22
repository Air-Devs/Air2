//
//  A2DefaultControls.m
//  Air2
//
//  默认布局实现。坐标说明见 .h。
//

#import "A2DefaultControls.h"
#import "A2ControlStore.h"
#import "A2Logger.h"

/// GLFW 键码（与 input_bridge_v3.m 的映射一致）
static NSString *const kKeySpace     = @"32";
static NSString *const kKeyShift     = @"340";   // 潜行
static NSString *const kKeyCtrl      = @"341";   // 疾跑
static NSString *const kKeyE         = @"69";
static NSString *const kKeyEsc       = @"256";
static NSString *const kKeyMouseLeft = @"0";
static NSString *const kKeyMouseRight= @"1";

@implementation A2DefaultControls

#pragma mark - 构件

/// 造一个按钮控件（点击事件 0 个或多个）
static A2ControlWidget *A2MakeButton(NSString *ident, NSString *text,
                                     CGFloat x, CGFloat y, CGFloat w, CGFloat h,
                                     NSArray<NSString *> *keyCodes) {
    A2ControlWidget *widget = [A2ControlWidget newButtonAtX:x y:y];
    widget.identifier = ident;
    widget.text = text ?: @"";
    widget.widthPercent = w;
    widget.heightPercent = h;
    widget.visibility = A2ControlVisibilityAlways;
    widget.isSwipple = YES;
    widget.isPenetrable = NO;
    widget.isToggleable = NO;
    widget.opacity = 1.0;

    NSMutableArray<A2ControlEvent *> *events = [NSMutableArray array];
    for (NSString *code in keyCodes) {
        if (code.length) [events addObject:[A2ControlEvent keyEventWithCode:code]];
    }
    widget.clickEvents = events;
    return widget;
}

/// 造一个文本控件（穿透，不挡触摸；用于顶部状态条）
static A2ControlWidget *A2MakeText(NSString *ident, NSString *text,
                                   CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    A2ControlWidget *widget = [A2ControlWidget newButtonAtX:x y:y];
    widget.type = A2ControlWidgetTypeTextBox;
    widget.identifier = ident;
    widget.text = text ?: @"";
    widget.xPercent = x;
    widget.yPercent = y;
    widget.widthPercent = w;
    widget.heightPercent = h;
    widget.isPenetrable = YES;
    widget.isSwipple = NO;
    widget.clickEvents = @[];
    widget.opacity = 0.85;
    widget.visibility = A2ControlVisibilityAlways;
    return widget;
}

+ (A2ControlLayout *)builtInLayout {
    A2ControlLayout *layout = [A2ControlLayout emptyLayout];
    layout.sourceFormat = @"air2";
    layout.version = [A2ControlLayout currentFormatVersion];
    layout.name = @"默认布局";
    layout.author = @"Air2";
    layout.aspectRatio = 16.0 / 9.0;
    [layout.layers removeAllObjects];

    // ============ 底层：视角区 ============
    // 必须最先加（z 序最底），否则它会挡住上面的按钮。
    A2ControlLayer *lookLayer = [A2ControlLayer new];
    lookLayer.identifier = @"look";
    lookLayer.name = @"视角";
    {
        A2ControlWidget *view = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeView];
        view.identifier = @"air2.look";
        view.xPercent = 0;
        view.yPercent = 0;
        view.widthPercent = 100;
        view.heightPercent = 100;
        view.opacity = 0.02;          // 游戏内几乎不可见；编辑器里能选中
        view.viewShowsBorder = NO;
        view.mouseMode = @"slide";
        view.mouseSensitivity = 100;
        view.viewScale = 1.0;
        view.visibility = A2ControlVisibilityAlways;
        [lookLayer.widgets addObject:view];
    }
    [layout.layers addObject:lookLayer];

    // ============ 中层：操作区 ============
    A2ControlLayer *main = [A2ControlLayer new];
    main.identifier = @"main";
    main.name = @"操作";
    main.hideWhenMouse = YES;
    main.hideWhenGamepad = YES;
    main.hideWhenJoystick = NO;

    // 左摇杆（八方向 WASD；斜向两键由 A2JoystickView 内部合成）
    {
        A2ControlWidget *joystick = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeJoystick];
        joystick.identifier = @"air2.joystick";
        joystick.xPercent = 3;
        joystick.yPercent = 46;
        joystick.widthPercent = 26;
        joystick.heightPercent = 42;
        joystick.deadZone = 0.15;
        joystick.visibility = A2ControlVisibilityAlways;
        [main.widgets addObject:joystick];
    }

    // 右侧拇指区：攻击 / 使用 / 跳跃 / 潜行 / 疾跑
    [main.widgets addObject:A2MakeButton(@"air2.attack", @"攻",
                                        86, 62, 11, 17, @[kKeyMouseLeft])];
    [main.widgets addObject:A2MakeButton(@"air2.use", @"用",
                                        86, 81, 11, 17, @[kKeyMouseRight])];
    [main.widgets addObject:A2MakeButton(@"air2.jump", @"跳",
                                        72, 80, 12, 17, @[kKeySpace])];
    [main.widgets addObject:A2MakeButton(@"air2.sneak", @"潜",
                                        72, 62, 11, 16, @[kKeyShift])];
    [main.widgets addObject:A2MakeButton(@"air2.sprint", @"跑",
                                        72, 44, 10, 14, @[kKeyCtrl])];

    // 顶部：背包 / 菜单
    [main.widgets addObject:A2MakeButton(@"air2.inventory", @"包",
                                        86, 42, 10, 15, @[kKeyE])];
    [main.widgets addObject:A2MakeButton(@"air2.menu", @"≡",
                                        3, 8, 7, 13, @[kKeyEsc])];

    // 九格快捷栏（单控件判定：ZL2 Hotbar.kt 的语义）
    {
        A2ControlWidget *hotbar = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeHotbar];
        hotbar.identifier = @"air2.hotbar";
        hotbar.xPercent = 26;
        hotbar.yPercent = 88;
        hotbar.widthPercent = 48;
        hotbar.heightPercent = 10;
        hotbar.visibility = A2ControlVisibilityAlways;
        [main.widgets addObject:hotbar];
    }

    // 滚轮（右边缘竖条）
    {
        A2ControlWidget *scroll = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeScroll];
        scroll.identifier = @"air2.scroll";
        scroll.xPercent = 93;
        scroll.yPercent = 30;
        scroll.widthPercent = 5;
        scroll.heightPercent = 26;
        scroll.scrollStep = 18;
        scroll.visibility = A2ControlVisibilityAlways;
        [main.widgets addObject:scroll];
    }

    [layout.layers addObject:main];

    // ============ 顶层：顶部状态 ============
    // 纯文本、可穿透，不挡触摸；后续宿主可以把它绑定到坐标/FPS 显示。
    A2ControlLayer *status = [A2ControlLayer new];
    status.identifier = @"status";
    status.name = @"状态";
    status.hideWhenMouse = NO;
    status.hideWhenGamepad = NO;
    [status.widgets addObject:A2MakeText(@"air2.status", @"Air2 · 触屏控制", 2, 2, 40, 5)];
    [layout.layers addObject:status];

    [layout normalize];
    return layout;
}

+ (A2ControlLayout *)makeLayout {
    NSError *err = nil;
    A2ControlLayout *saved = [A2ControlStore loadUserLayoutWithError:&err];
    if (saved) {
        return saved;
    }
    if (err) {
        // 用户文件坏了：保留原文件（不覆盖），回退内置布局
        [A2Logger warning:@"A2DefaultControls"
                  message:[NSString stringWithFormat:@"用户布局读取失败：%@，回退内置布局",
                           err.localizedDescription ?: @""]];
    }

    A2ControlLayout *layout = [self builtInLayout];
    NSError *saveErr = nil;
    if (![A2ControlStore saveUserLayout:layout error:&saveErr]) {
        [A2Logger warning:@"A2DefaultControls"
                  message:[NSString stringWithFormat:@"默认布局落盘失败：%@",
                           saveErr.localizedDescription ?: @""]];
    }
    return layout;
}

+ (BOOL)installDefaultLayoutToPath:(NSString *)path error:(NSError **)error {
    A2ControlLayout *layout = [self builtInLayout];
    return [A2ControlStore saveLayout:layout toPath:path error:error];
}

+ (BOOL)installIfNeededAtPath:(NSString *)path error:(NSError **)error {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    return [self installDefaultLayoutToPath:path error:error];
}

+ (BOOL)restoreDefaultLayoutWithError:(NSError **)error {
    return [A2ControlStore saveUserLayout:[self builtInLayout] error:error];
}

@end
