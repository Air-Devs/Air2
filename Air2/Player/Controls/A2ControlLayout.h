//
//  A2ControlLayout.h
//  Air2
//
//  控件系统的数据模型 —— **直接兼容 FCL / ZL2 / Air1 三家的原生格式**。
//
//  ## 三家的格式（实证自源码）
//
//    ZL2   { editorVersion, layers: [{ normalButtons, joystickButtons, textBoxes }] }
//    FCL   { controllerVersion, viewGroups: [{ ... }] }
//    Air1  与 Android 同构（ControlButton.h 注释里写明）
//
//  ## ZL2 的完整数据规格（LayerController 模块）
//
//    ClickEvent.Type（6 种）：
//      "key"             按键
//      "launcher_event"  启动器事件（切菜单/切鼠标等）
//      "switch_layer"    切换控件层可见性
//      "show_layer"      强制显示层
//      "hide_layer"      强制隐藏层
//      "send_text"       发送聊天消息
//
//    VisibilityType：  "always" / "in_game" / "in_menu"
//    ButtonShape：     topStart / topEnd / bottomEnd / bottomStart（四角独立圆角 0~100）
//    ButtonSize.Type： "dp" / "percentage"
//
//  ## 兼容策略（不做格式转换）
//
//  按优先级依次尝试多个键名 —— 三家字段名重合度很高：
//    position: {x,y} / {percentageX,percentageY}
//    size:     buttonSize / size
//  写回时【沿用原始 JSON 的键名】，且保留 rawJSON，
//  不认识的新字段原样带回。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 事件

/// 点击事件的类型（对齐 ZL2 的 ClickEvent.Type）
///
/// ⚠️ 枚举值只允许【追加】，不允许插入/重排 —— A2ControlRenderer 与
/// SurfaceViewController 都按数值比较（Notification 的 userInfo 里也传 NSNumber）。
typedef NS_ENUM(NSInteger, A2ControlEventType) {
    A2ControlEventTypeKey = 0,          ///< "key"            按键
    A2ControlEventTypeLauncherEvent,    ///< "launcher_event" 启动器事件
    A2ControlEventTypeSwitchLayer,      ///< "switch_layer"   切换层
    A2ControlEventTypeShowLayer,        ///< "show_layer"     显示层
    A2ControlEventTypeHideLayer,        ///< "hide_layer"     隐藏层
    A2ControlEventTypeSendText,         ///< "send_text"      发送文本
    A2ControlEventTypeUnknown,
    /// 鼠标键（ZL2 写成 "key" + "GLFW_MOUSE_BUTTON_LEFT"；本层规范化后单独一类）
    A2ControlEventTypeMouseButton,
    /// 滚轮（ZL2 的 launcher.event.scroll_up(.single)）
    A2ControlEventTypeScroll,
};

@interface A2ControlEvent : NSObject
@property (nonatomic, assign) A2ControlEventType type;
/// 按键码（Key）或事件名（LauncherEvent）/ 层 ID（Layer 类）/ 文本（SendText）
@property (nonatomic, copy, nullable) NSString *key;
/// 原始类型字符串 —— 未知类型原样写回
@property (nonatomic, copy, nullable) NSString *rawType;
+ (nullable instancetype)eventFromJSON:(NSDictionary *)json;
- (NSDictionary *)toJSON;
/// Air1/FCL 风格：{"type": "SendKey", "key": "87"}
+ (instancetype)keyEventWithCode:(NSString *)code;
+ (instancetype)launcherEvent:(NSString *)name;
@end

#pragma mark - 可见性

typedef NS_ENUM(NSInteger, A2ControlVisibility) {
    A2ControlVisibilityAlways = 0,   ///< "always"
    A2ControlVisibilityInGame,       ///< "in_game"  仅游戏内（未打开菜单）
    A2ControlVisibilityInMenu,       ///< "in_menu"  仅菜单内
};

#pragma mark - 坐标换算

//  三家的坐标基准差别（这是格式互转最容易出错的地方）：
//
//    Air2（内部模型，也就是渲染器用的）
//        xPercent / yPercent = 0~100，**相对屏幕宽/高**的左上角百分比。
//        渲染器直接 x = bounds.width * xPercent / 100。
//
//    FCL（BaseInfoData.xPosition）
//        0~1000，**相对「可用空间」的比例**：
//        x_px = (screenW - width) * xPosition / 1000
//        （实证：fcl/FCL/.../control/view/ControlButton.java:242）
//
//    ZL2（button 的 position.x）
//        0~10000，同样是相对「可用空间」：x_px = (screenW - w) * x / 10000
//
//  所以互转必须过一层「可用空间比例 → 屏幕百分比」：
//        percent = anchor * (100 - sizePercent)
//  直接照搬数值会导致按钮全部跑到屏幕外（原 A2ControlLayout 就有这个隐患，
//  见 A2ControlFormatZL.m 顶部的注释）。

/// 可用空间比例（0~1）→ 屏幕百分比（0~100）
FOUNDATION_EXPORT CGFloat A2ControlAnchorToPercent(CGFloat anchor, CGFloat sizePercent);

/// 屏幕百分比（0~100）→ 可用空间比例（0~1）
FOUNDATION_EXPORT CGFloat A2ControlPercentToAnchor(CGFloat percent, CGFloat sizePercent);

/// 参考边尺寸百分比 → 目标屏幕边百分比。
/// @param rawPercent  相对参考边（screen_width / screen_height）的百分比
/// @param refIsHeight 参考边是不是屏幕高（ZL2 的 widthReference == "screen_height"）
/// @param isWidth     目标边是不是宽
/// @param aspect      屏幕宽高比 W/H（未知时传 0，内部按 16:9）
FOUNDATION_EXPORT CGFloat A2ControlSizeToScreenPercent(CGFloat rawPercent,
                                                       BOOL refIsHeight,
                                                       BOOL isWidth,
                                                       CGFloat aspect);

/// 上面那个的逆运算
FOUNDATION_EXPORT CGFloat A2ControlScreenPercentToSize(CGFloat percent,
                                                       BOOL refIsHeight,
                                                       BOOL isWidth,
                                                       CGFloat aspect);

#pragma mark - 控件

typedef NS_ENUM(NSInteger, A2ControlWidgetType) {
    A2ControlWidgetTypeButton = 0,   ///< normalButtons
    A2ControlWidgetTypeJoystick,     ///< joystickButtons
    A2ControlWidgetTypeTextBox,      ///< textBoxes
    A2ControlWidgetTypeGamepad,      ///< gamepadButtons
    A2ControlWidgetTypeGyroscope,    ///< gyroscopeButtons
    A2ControlWidgetTypeHotbar,       ///< hotbarButtons
    /// 视角区（拖动即转视角）—— 对照：
    ///   zl2/.../ui/control/mouse/TouchInput.kt 的「拖动屏幕转视角」分支
    ///   fcl/.../control/FCLInput.java 的鼠标移动区域
    /// 两家的布局 JSON 都没有独立类型，Air2 用扩展键 viewAreas 保存。
    A2ControlWidgetTypeView,         ///< viewAreas
    /// 滚轮（上下滑 → 滚轮事件）—— 对照：
    ///   zl2/.../ui/control/event/Events.kt 的 LAUNCHER_EVENT_SCROLL_*
    ///   FCL 的 ButtonEventData.outputKeycodes 里的 1003/1004
    /// Air2 用扩展键 scrollButtons 保存。
    A2ControlWidgetTypeScroll,       ///< scrollButtons
};

/// 摇杆触发模式（对照 ZL2 的 JoystickTriggerMode / FCL 的 DirectionStyle.styleType）
typedef NS_ENUM(NSInteger, A2JoystickTriggerMode) {
    /// 方向键式：八方向 → 按下对应方向键（FCL 的 BUTTON、旧 Air2 行为）
    A2JoystickTriggerModeDirection = 0,
    /// 摇杆式：持续输出归一化偏移（FCL 的 ROCKER，用于视角/模拟量）
    A2JoystickTriggerModeRocker,
};

@interface A2ControlWidget : NSObject

@property (nonatomic, assign) A2ControlWidgetType type;
@property (nonatomic, copy) NSString *identifier;

/// 显示文字（三家可能给字符串或 {"zh": "…"} 字典）
@property (nonatomic, copy, nullable) NSString *text;

// ---- 位置与尺寸（百分比 0~100）----
// ZL2:      position {x,y} + buttonSize {width,height}
// FCL 新版:  position {x,y} + size {width,height}
// FCL 老版:  position {percentageX,percentageY}
@property (nonatomic, assign) CGFloat xPercent;
@property (nonatomic, assign) CGFloat yPercent;
@property (nonatomic, assign) CGFloat widthPercent;
@property (nonatomic, assign) CGFloat heightPercent;

/// ZL2 的 ButtonSize.Type："dp" / "percentage" / "wrap_content"
@property (nonatomic, copy, nullable) NSString *sizeType;

/// 尺寸的参考边（ZL2 的 widthReference / heightReference：
/// "screen_width" / "screen_height"）。nil 视作 screen_width。
/// 格式互转必须保留它，否则 ZL2 → FCL 的尺寸会错。
@property (nonatomic, copy, nullable) NSString *widthReference;
@property (nonatomic, copy, nullable) NSString *heightReference;

/// ZL2 的 dp 尺寸（sizeType == "dp" 时是权威值，百分比只是派生值）
@property (nonatomic, assign) CGFloat widthDp;
@property (nonatomic, assign) CGFloat heightDp;

// ---- 外观 ----
/// 控件不透明度（0~1，默认 1）。
/// ZL2 把 alpha 放在 ButtonStyle 里（StyleConfig.alpha），FCL 放在
/// ButtonStyles.fillColor 的 alpha 通道；两边都没有「单个控件」的
/// 不透明度字段，所以这是 Air2 的扩展：内部格式写 opacity，
/// 导出 ZL2/FCL 时写 air2Opacity（对方不认识但会原样保留）。
@property (nonatomic, assign) CGFloat opacity;

/// 四角独立圆角（0~100，对应 ZL2 的 ButtonShape）
@property (nonatomic, assign) CGFloat cornerTopStart;
@property (nonatomic, assign) CGFloat cornerTopEnd;
@property (nonatomic, assign) CGFloat cornerBottomEnd;
@property (nonatomic, assign) CGFloat cornerBottomStart;
@property (nonatomic, copy, nullable) NSString *buttonStyle;

/// ZL2 的 styleType 原始值："BUTTON" / "ROCKER"（FCL 方向控件带这个）
@property (nonatomic, copy, nullable) NSString *styleType;

// ---- 行为 ----
@property (nonatomic, assign) BOOL isSwipple;      ///< 可与周围按钮联动
@property (nonatomic, assign) BOOL isPenetrable;   ///< 触摸穿透
@property (nonatomic, assign) BOOL isToggleable;   ///< 开关式
@property (nonatomic, assign) A2ControlVisibility visibility;

/// 所属层 ID（ZL2 的 layers[].id）
@property (nonatomic, copy, nullable) NSString *layerID;

@property (nonatomic, copy) NSArray<A2ControlEvent *> *clickEvents;

// ---- 摇杆专用（type == Joystick）----
// 对照 ZL2 joystick 包 + FCL DirectionEventData：
//   deadZoneRatio / lockThreshold（ZL2 是 0~1，FCL 是 0~100）
//   canLock / triggerMode / directionEvents
/// 触发模式（方向键式 / 摇杆式）
@property (nonatomic, assign) A2JoystickTriggerMode triggerMode;
/// 死区比例（0~1）。0.15 表示中心 15% 半径内不输出。
@property (nonatomic, assign) CGFloat deadZone;
/// 是否允许「前进锁」（ZL2 的 canLock）
@property (nonatomic, assign) BOOL canLock;

/// 双击摇杆中心触发潜行。
///
/// 来源 FCL DirectionEventData.java:119 的 `sneak`，**默认值是 true**
/// （不是 false）—— 缺字段时必须按 YES 处理，否则从 FCL 导入的摇杆
/// 会静默失去双击潜行。
@property (nonatomic, assign) BOOL sneakOnDoubleTap;
/// 潜行时按下的键码（FCL 的 sneakKeycode，默认 42 = KEY_LEFTSHIFT）
@property (nonatomic, assign) NSInteger sneakKeyCode;
/// 锁定阈值（0~1）
@property (nonatomic, assign) CGFloat lockThreshold;
/// 八方向事件：@{@"north": @[A2ControlEvent], ..., @"south_west": @[...]}
/// 用 ZL2 的键名（north / north_east / east / south_east /
/// south / south_west / west / north_west）。
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSArray<A2ControlEvent *> *> *directionEvents;
/// 锁定后触发的事件（ZL2 的 lockEvents）
@property (nonatomic, copy, nullable) NSArray<A2ControlEvent *> *lockEvents;

// ---- 手柄专用（type == Gamepad）----
/// 按键名 → 键码/事件：@{@"a": @"32", @"b": @"340", ...}
/// 键名对齐 ZL2 gamepad/GamepadMap.kt 的 identifier 小写形式
/// （a/b/x/y/start/select/lb/rb/lt/rt/dpad_up/dpad_down/dpad_left/dpad_right/
///   stick_left_click/stick_right_click）。
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *gamepadMapping;

// ---- 陀螺仪专用（type == Gyroscope）----
/// 灵敏度倍数（默认 1.0）
@property (nonatomic, assign) CGFloat gyroscopeSensitivity;
/// 平滑窗口（采样点数，默认 4，对应 ZL2 的 smoothingWindow）
@property (nonatomic, assign) NSInteger gyroscopeSmoothingWindow;
/// 低通阈值（rad/s，默认 0.02，对应 ZL2 的 threshold）
@property (nonatomic, assign) CGFloat gyroscopeThreshold;
/// 是否默认开启
@property (nonatomic, assign) BOOL gyroscopeEnabled;

// ---- 快捷栏专用（type == Hotbar）----
/// 格数（默认 9，ZL2 固定 9 格，但留成可配以免硬编码）
@property (nonatomic, assign) NSInteger hotbarSlotCount;
/// 每格绑定的键码（默认 "49"~"57"，即数字 1~9）
@property (nonatomic, copy, nullable) NSArray<NSString *> *hotbarKeys;
/// 双击（切换副手）键，默认 70 = F
@property (nonatomic, copy, nullable) NSString *hotbarSwapKey;
/// 长按（丢弃）键，默认 81 = Q
@property (nonatomic, copy, nullable) NSString *hotbarDropKey;

// ---- 鼠标面板专用（type == TextBox 之外的扩展；仅编辑器/宿主主动创建时用）----
/// 鼠标模式："slide" / "click"（对照 ZL2 的 MouseControlMode）
@property (nonatomic, copy, nullable) NSString *mouseMode;
/// 指针灵敏度百分比（100 = 1:1，对照 ZL2 的 cursorSensitivity）
@property (nonatomic, assign) CGFloat mouseSensitivity;

// ---- 视角区专用（type == View）----
// 复用 mouseMode / mouseSensitivity：
//   slide  拖动时持续发送鼠标位移（默认，对照 ZL2 TouchInput 的拖动）
//   click  单指点击 = 左键单击（对照 ZL2 的点击模式）
/// 转视角的像素倍率（1.0 = 手指划过 1pt 转 1px）
@property (nonatomic, assign) CGFloat viewScale;
/// 是否显示淡淡的边框（给玩家提示「这里是视角区」；游戏内通常关掉）
@property (nonatomic, assign) BOOL viewShowsBorder;

// ---- 滚轮专用（type == Scroll）----
/// 多少 pt 的滑动算一格滚轮（越小越灵敏；默认 18）
@property (nonatomic, assign) CGFloat scrollStep;
/// 滚动方向是否反转（对应系统「自然滚动」开关）
@property (nonatomic, assign) BOOL scrollInverted;
/// 是否同时支持左右滚轮（默认 NO，只做上下）
@property (nonatomic, assign) BOOL scrollHorizontal;

/// **保留原始 JSON**，保存时以它为基础只改有变动的字段
@property (nonatomic, copy, nullable) NSDictionary *rawJSON;

+ (nullable instancetype)widgetFromJSON:(NSDictionary *)json
                                   type:(A2ControlWidgetType)type
                                layerID:(nullable NSString *)layerID;
- (NSDictionary *)toJSON;

/// 复制一个控件（编辑器「复制/粘贴」用）。
/// 新控件有独立 identifier，其余字段深拷贝。
- (A2ControlWidget *)duplicatedWidget;

/// 新建一个空白控件（编辑器用）
+ (instancetype)newButtonAtX:(CGFloat)x y:(CGFloat)y;

/// 新建指定类型的控件（编辑器 / 格式转换用）。
/// 数值型的默认值都对齐 ZL2 / FCL 的默认布局，避免新建出来是"空"的。
+ (instancetype)newWidgetOfType:(A2ControlWidgetType)type;

@end

#pragma mark - 层

/// 一个控件层（ZL2 的 layer）
@interface A2ControlLayer : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL visibleByDefault;

// ---- ZL2 原生的层可见性开关（对照 CcFclToZl.kt / CcZlToFcl.kt 里
//      layer 上的 hideWhenMouse / hideWhenGamepad / hideWhenJoystick）----
/// 接了鼠标时隐藏本层（ZL2 默认 true —— 有鼠标就不挡着）
@property (nonatomic, assign) BOOL hideWhenMouse;
/// 接了手柄时隐藏本层（ZL2 默认 true）
@property (nonatomic, assign) BOOL hideWhenGamepad;
/// 接了手柄摇杆时隐藏本层（ZL2 默认 false）
@property (nonatomic, assign) BOOL hideWhenJoystick;

/// 层的可见时机（ZL2 layer.visibilityType：always / in_game / in_menu）。
/// 与控件的 visibility 不是一回事：层是整体开关，控件是单个。
@property (nonatomic, copy) NSString *visibilityType;

/// ⚠️ 必须是 strong，不能用 copy ——
/// copy 会把 NSMutableArray 复制成不可变的 NSArray，
/// 之后 addObject: 直接崩 unrecognized selector。
@property (nonatomic, strong) NSMutableArray<A2ControlWidget *> *widgets;
@property (nonatomic, copy, nullable) NSDictionary *rawJSON;
- (NSDictionary *)toJSON;
@end

#pragma mark - 布局

@interface A2ControlLayout : NSObject

/// 布局来源格式：zl2 / fcl / air1 / air2。
///
/// 注意这里是 readwrite 而不是 readonly：各格式解析器（A2ControlFormatZL.m、
/// A2ControlFormatFCL.m …）在**另一个编译单元**里给这个属性赋值，看不到
/// A2ControlLayout.m 里的类扩展重声明，只能靠头文件。
/// 写成 readonly 会直接编译失败：
///   A2ControlFormatZL.m:162:25: error: assignment to readonly property
@property (nonatomic, copy) NSString *sourceFormat;
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *author;

/// 设计时的屏幕宽高比（W/H）。ZL2/FCL 的坐标是「可用空间比例」，
/// 尺寸百分比还可能以屏幕高为参考边 —— 这两件事都是宽高比相关的，
/// 所以解析时把当时的比例记下来，导出时用同一个值才能往返一致。
/// 源文件没写时取 16:9（两家的默认设计比例）。
@property (nonatomic, assign) CGFloat aspectRatio;

/// 所有层（ZL2 的 layers）
/// 同上：可变数组必须 strong
@property (nonatomic, strong) NSMutableArray<A2ControlLayer *> *layers;

/// 扁平化后的全部控件（渲染与编辑器用）
@property (nonatomic, readonly) NSArray<A2ControlWidget *> *allWidgets;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *buttonStyles;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *joystickStyles;
@property (nonatomic, copy, nullable) NSDictionary *rawRoot;

+ (nullable instancetype)layoutFromJSON:(NSDictionary *)json error:(NSError **)error;
+ (nullable instancetype)layoutFromFile:(NSString *)path error:(NSError **)error;
- (BOOL)writeToFile:(NSString *)path error:(NSError **)error;

/// 新建一份空白布局（编辑器用，只有一层）
+ (instancetype)emptyLayout;

/// Air2 内部快照（撤销/重做、复制粘贴、持久化用）。
///
/// 为什么不复用 ZL2 / FCL 的 JSON：那两家的 position 是「可用空间比例」
/// （0~10000 / 0~1000），内部模型是屏幕百分比（0~100）。拿对方的 JSON
/// 当快照，再解析回来会走在对方的坐标换算上，来回一次就漂移。
/// 所以快照用内部单位，并且带 format 标记，不会被 detectFormat 认成 ZL2。
- (NSDictionary *)snapshotJSON;

/// 从快照重建（与 snapshotJSON 配对）。失败返回 nil。
+ (nullable instancetype)layoutFromSnapshot:(nullable NSDictionary *)snapshot;

/// 数据自检 + 迁移：补齐旧版本缺失的字段、夹紧越界值、
/// 修复空 identifier / 空层 / widget.layerID 不同步。
/// 任何来源（文件、快照、导入）解析后都应调用一次。
- (void)normalize;

/// 当前内部格式版本（见 A2ControlStore 的迁移逻辑）
@property (class, nonatomic, readonly) NSInteger currentFormatVersion;

@end

NS_ASSUME_NONNULL_END
