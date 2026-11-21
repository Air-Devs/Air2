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
typedef NS_ENUM(NSInteger, A2ControlEventType) {
    A2ControlEventTypeKey = 0,          ///< "key"            按键
    A2ControlEventTypeLauncherEvent,    ///< "launcher_event" 启动器事件
    A2ControlEventTypeSwitchLayer,      ///< "switch_layer"   切换层
    A2ControlEventTypeShowLayer,        ///< "show_layer"     显示层
    A2ControlEventTypeHideLayer,        ///< "hide_layer"     隐藏层
    A2ControlEventTypeSendText,         ///< "send_text"      发送文本
    A2ControlEventTypeUnknown,
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

#pragma mark - 控件

typedef NS_ENUM(NSInteger, A2ControlWidgetType) {
    A2ControlWidgetTypeButton = 0,   ///< normalButtons
    A2ControlWidgetTypeJoystick,     ///< joystickButtons
    A2ControlWidgetTypeTextBox,      ///< textBoxes
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

/// ZL2 的 ButtonSize.Type："dp" 或 "percentage"
@property (nonatomic, copy, nullable) NSString *sizeType;

// ---- 外观 ----
/// 四角独立圆角（0~100，对应 ZL2 的 ButtonShape）
@property (nonatomic, assign) CGFloat cornerTopStart;
@property (nonatomic, assign) CGFloat cornerTopEnd;
@property (nonatomic, assign) CGFloat cornerBottomEnd;
@property (nonatomic, assign) CGFloat cornerBottomStart;
@property (nonatomic, copy, nullable) NSString *buttonStyle;

// ---- 行为 ----
@property (nonatomic, assign) BOOL isSwipple;      ///< 可与周围按钮联动
@property (nonatomic, assign) BOOL isPenetrable;   ///< 触摸穿透
@property (nonatomic, assign) BOOL isToggleable;   ///< 开关式
@property (nonatomic, assign) A2ControlVisibility visibility;

/// 所属层 ID（ZL2 的 layers[].id）
@property (nonatomic, copy, nullable) NSString *layerID;

@property (nonatomic, copy) NSArray<A2ControlEvent *> *clickEvents;

/// **保留原始 JSON**，保存时以它为基础只改有变动的字段
@property (nonatomic, copy, nullable) NSDictionary *rawJSON;

+ (nullable instancetype)widgetFromJSON:(NSDictionary *)json
                                   type:(A2ControlWidgetType)type
                                layerID:(nullable NSString *)layerID;
- (NSDictionary *)toJSON;

/// 新建一个空白控件（编辑器用）
+ (instancetype)newButtonAtX:(CGFloat)x y:(CGFloat)y;

@end

#pragma mark - 层

/// 一个控件层（ZL2 的 layer）
@interface A2ControlLayer : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL visibleByDefault;
/// ⚠️ 必须是 strong，不能用 copy ——
/// copy 会把 NSMutableArray 复制成不可变的 NSArray，
/// 之后 addObject: 直接崩 unrecognized selector。
@property (nonatomic, strong) NSMutableArray<A2ControlWidget *> *widgets;
@property (nonatomic, copy, nullable) NSDictionary *rawJSON;
- (NSDictionary *)toJSON;
@end

#pragma mark - 布局

@interface A2ControlLayout : NSObject

@property (nonatomic, copy, readonly) NSString *sourceFormat;   // zl2 / fcl / air1
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *author;

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

@end

NS_ASSUME_NONNULL_END
