//
//  A2ControlLayout.m
//  Air2
//

#import "A2ControlLayout.h"
#import "A2ControlInput.h"
#import "A2ControlFormat.h"
#import "A2Logger.h"

#pragma mark - 坐标换算

CGFloat A2ControlAnchorToPercent(CGFloat anchor, CGFloat sizePercent) {
    CGFloat remain = 100.0 - MAX(0.0, MIN(99.0, sizePercent));
    return MAX(0.0, MIN(100.0, anchor)) * remain;
}

CGFloat A2ControlPercentToAnchor(CGFloat percent, CGFloat sizePercent) {
    CGFloat remain = 100.0 - MAX(0.0, MIN(99.0, sizePercent));
    if (remain < 0.5) return 0;
    return MAX(0.0, MIN(1.0, percent / remain));
}

CGFloat A2ControlSizeToScreenPercent(CGFloat rawPercent, BOOL refIsHeight,
                                     BOOL isWidth, CGFloat aspect) {
    if (!isfinite(aspect) || aspect <= 0.05) aspect = 16.0 / 9.0;
    if (refIsHeight) return isWidth ? rawPercent / aspect : rawPercent;
    return isWidth ? rawPercent : rawPercent * aspect;
}

CGFloat A2ControlScreenPercentToSize(CGFloat percent, BOOL refIsHeight,
                                     BOOL isWidth, CGFloat aspect) {
    if (!isfinite(aspect) || aspect <= 0.05) aspect = 16.0 / 9.0;
    if (refIsHeight) return isWidth ? percent * aspect : percent;
    return isWidth ? percent : percent / aspect;
}

#pragma mark - 工具

/// 从多个可能的键里取第一个存在的值。
/// 这是直接兼容三家格式的核心手段 —— 同一语义在不同家的字段名不一样。
static id A2First(id json, NSArray<NSString *> *keys) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *k in keys) {
        id v = json[k];
        if (v && v != NSNull.null) return v;
    }
    return nil;
}

static NSString *A2Str(id json, NSArray<NSString *> *keys) {
    id v = A2First(json, keys);
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}

static double A2Num(id json, NSArray<NSString *> *keys, double fallback) {
    id v = A2First(json, keys);
    if ([v isKindOfClass:NSNumber.class]) return [v doubleValue];
    if ([v isKindOfClass:NSString.class]) return [v doubleValue];
    return fallback;
}

static BOOL A2Bool(id json, NSArray<NSString *> *keys, BOOL fallback) {
    id v = A2First(json, keys);
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    if ([v isKindOfClass:NSString.class]) return [v boolValue];
    return fallback;
}

/// 把 ZL2 的 clickEvents 数组解析成事件对象数组
static NSArray<A2ControlEvent *> *A2EventsFromArray(id arr) {
    NSMutableArray<A2ControlEvent *> *out = [NSMutableArray array];
    if (![arr isKindOfClass:NSArray.class]) return out;
    for (id e in (NSArray *)arr) {
        A2ControlEvent *ev = [A2ControlEvent eventFromJSON:e];
        if (ev) [out addObject:ev];
    }
    return out;
}

/// ZL2 的 directionEvents：@{@"north": @[{type,key}], ...}
static NSDictionary<NSString *, NSArray<A2ControlEvent *> *> *A2DirectionEventsFromJSON(id obj) {
    if (![obj isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *dir in (NSDictionary *)obj) {
        out[dir] = A2EventsFromArray(((NSDictionary *)obj)[dir]);
    }
    return out.count ? out : nil;
}

#pragma mark - 事件

@implementation A2ControlEvent

/// ZL2 的类型名映射（含 FCL / Air1 的变体）
+ (NSDictionary<NSString *, NSNumber *> *)typeMap {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // ZL2
            @"key":            @(A2ControlEventTypeKey),
            @"launcher_event": @(A2ControlEventTypeLauncherEvent),
            @"switch_layer":   @(A2ControlEventTypeSwitchLayer),
            @"show_layer":     @(A2ControlEventTypeShowLayer),
            @"hide_layer":     @(A2ControlEventTypeHideLayer),
            @"send_text":      @(A2ControlEventTypeSendText),
            // FCL（event 字段用大写驼峰）
            @"Key":            @(A2ControlEventTypeKey),
            @"SendKey":        @(A2ControlEventTypeKey),
            @"LauncherEvent":  @(A2ControlEventTypeLauncherEvent),
            @"SwitchLayer":    @(A2ControlEventTypeSwitchLayer),
            @"ShowLayer":      @(A2ControlEventTypeShowLayer),
            @"HideLayer":      @(A2ControlEventTypeHideLayer),
            @"SendText":       @(A2ControlEventTypeSendText),
            // Air1（与 SendKey 同族）
            @"MouseWheel":     @(A2ControlEventTypeLauncherEvent),
            @"MouseMove":      @(A2ControlEventTypeLauncherEvent),
            @"ToggleGui":      @(A2ControlEventTypeLauncherEvent),
            @"ToggleKeyboard": @(A2ControlEventTypeLauncherEvent),
            @"SwitchMouse":    @(A2ControlEventTypeLauncherEvent),
        };
    });
    return map;
}

+ (instancetype)eventFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ControlEvent *e = [A2ControlEvent new];

    // ZL2 用 "type"，FCL 用 "event" —— 这个差异之前漏了
    NSString *typeName = A2Str(json, @[@"type", @"event", @"Type", @"Event"]);
    e.rawType = typeName;

    NSNumber *mapped = [self typeMap][typeName ?: @""];
    e.type = mapped ? (A2ControlEventType)mapped.integerValue : A2ControlEventTypeUnknown;

    // 键值：ZL2 用 "key"，FCL 用 "eventArgs"
    e.key = A2Str(json, @[@"key", @"eventArgs", @"value", @"Key"]);

    // ---- 按「键值」纠正事件类型 ----
    // 两家的鼠标/滚轮都写在 "key" 里：
    //   ZL2  {"type":"key","key":"GLFW_MOUSE_BUTTON_LEFT"}
    //   ZL2  {"type":"launcher_event","key":"launcher.event.scroll_up.single"}
    // 如果只信 type 字段，鼠标键会被当成键盘键下发（宿主那边 code<=0 会被丢弃）。
    NSInteger code = -1;
    A2ControlInputKind kind = [A2ControlEventKey kindForRawKey:e.key outCode:&code];
    switch (kind) {
        case A2ControlInputKindMouseButton:
            e.type = A2ControlEventTypeMouseButton;
            e.key = [NSString stringWithFormat:@"%ld", (long)code];
            break;
        case A2ControlInputKindScroll:
            e.type = A2ControlEventTypeScroll;
            e.key = [NSString stringWithFormat:@"scroll:%ld",
                     (long)[A2ControlEventKey scrollDirectionForRawKey:e.key]];
            break;
        case A2ControlInputKindLauncher:
            // "launcher_event" 写成了 Key 的，纠正过来
            if (e.type == A2ControlEventTypeKey) e.type = A2ControlEventTypeLauncherEvent;
            break;
        case A2ControlInputKindKey: {
            // ZL2 名称写法 → 数字（运行时只认数字）
            NSString *normalized = [A2ControlEventKey normalizedKey:e.key];
            if (normalized.length) e.key = normalized;
            break;
        }
        default:
            break;
    }
    return e;
}

+ (instancetype)keyEventWithCode:(NSString *)code {
    A2ControlEvent *e = [A2ControlEvent new];
    e.type = A2ControlEventTypeKey;
    e.key = code;
    return e;
}

+ (instancetype)launcherEvent:(NSString *)name {
    A2ControlEvent *e = [A2ControlEvent new];
    e.type = A2ControlEventTypeLauncherEvent;
    e.key = name;
    return e;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // 未知类型原样写回 —— 我们可能还没支持某些新事件类型
    NSString *typeName = self.rawType;
    if (!typeName.length) typeName = [self defaultTypeName];

    d[@"type"] = typeName;
    if (self.key.length) d[@"key"] = self.key;
    return d;
}

- (NSString *)defaultTypeName {
    switch (self.type) {
        case A2ControlEventTypeKey:           return @"key";
        case A2ControlEventTypeLauncherEvent: return @"launcher_event";
        case A2ControlEventTypeSwitchLayer:   return @"switch_layer";
        case A2ControlEventTypeShowLayer:     return @"show_layer";
        case A2ControlEventTypeHideLayer:     return @"hide_layer";
        case A2ControlEventTypeSendText:      return @"send_text";
        // 鼠标键与滚轮在 ZL2 里就是 key / launcher_event 的两种特例
        case A2ControlEventTypeMouseButton:   return @"key";
        case A2ControlEventTypeScroll:        return @"launcher_event";
        default:                              return @"key";
    }
}

@end

#pragma mark - 控件

@implementation A2ControlWidget

+ (instancetype)newButtonAtX:(CGFloat)x y:(CGFloat)y {
    A2ControlWidget *w = [A2ControlWidget new];
    w.type = A2ControlWidgetTypeButton;
    w.identifier = [[NSUUID UUID] UUIDString];
    w.text = @"按钮";
    w.xPercent = x;
    w.yPercent = y;
    w.widthPercent = 12;
    w.heightPercent = 12;
    w.isSwipple = YES;
    w.isPenetrable = NO;
    w.isToggleable = NO;
    w.visibility = A2ControlVisibilityAlways;
    w.cornerTopStart = w.cornerTopEnd = w.cornerBottomEnd = w.cornerBottomStart = 20;
    w.clickEvents = @[];
    w.deadZone = 0.15;
    w.lockThreshold = 0.3;
    w.gyroscopeSensitivity = 1.0;
    w.gyroscopeSmoothingWindow = 4;
    w.gyroscopeThreshold = 0.02;
    w.hotbarSlotCount = 9;
    w.mouseSensitivity = 100;
    // ---- Air2 扩展默认值（新控件先给可用的值，避免新建出来是"空"的）----
    w.opacity = 1.0;
    w.viewScale = 1.0;
    w.viewShowsBorder = YES;
    w.mouseMode = @"slide";
    w.scrollStep = 18.0;
    w.scrollInverted = NO;
    w.scrollHorizontal = NO;
    return w;
}

/// 摇杆默认八方向事件（WASD，与三家默认布局一致）
static NSDictionary<NSString *, NSArray<A2ControlEvent *> *> *A2DefaultDirectionEvents(void) {
    A2ControlEvent *w = [A2ControlEvent keyEventWithCode:@"87"];
    A2ControlEvent *a = [A2ControlEvent keyEventWithCode:@"65"];
    A2ControlEvent *s = [A2ControlEvent keyEventWithCode:@"83"];
    A2ControlEvent *d = [A2ControlEvent keyEventWithCode:@"68"];
    return @{
        @"north":      @[w],
        @"north_east": @[w, d],
        @"east":       @[d],
        @"south_east": @[s, d],
        @"south":      @[s],
        @"south_west": @[s, a],
        @"west":       @[a],
        @"north_west": @[w, a],
    };
}

/// 手柄默认映射（逐条对照 ZL2 gamepad/GamepadMap.kt 的 defaultKeysInGame）
static NSDictionary<NSString *, NSString *> *A2DefaultGamepadMapping(void) {
    return @{
        @"a": @"32",          // BUTTON_A  → GLFW_KEY_SPACE
        @"b": @"340",         // BUTTON_B  → GLFW_KEY_LEFT_SHIFT
        @"x": @"290",         // BUTTON_X  → GLFW_KEY_F1
        @"y": @"69",          // BUTTON_Y  → GLFW_KEY_E
        @"start": @"256",     // BUTTON_START → GLFW_KEY_ESCAPE
        @"select": @"2",      // BUTTON_SELECT → 鼠标中键
        @"lb": @"scroll:1",   // BUTTON_LB → 滚轮上（单次）
        @"rb": @"scroll:-1",  // BUTTON_RB → 滚轮下（单次）
        @"lt": @"1",          // BUTTON_LT → 鼠标右键
        @"rt": @"0",          // BUTTON_RT → 鼠标左键
        @"dpad_up": @"294",   // DPAD_UP   → GLFW_KEY_F5
        @"dpad_left": @"70",  // DPAD_LEFT → GLFW_KEY_F
        @"dpad_down": @"81",  // DPAD_DOWN → GLFW_KEY_Q
        @"dpad_right": @"84", // DPAD_RIGHT→ GLFW_KEY_T
        @"stick_left_click": @"341",  // LEFT_CONTROL
        @"stick_right_click": @"",
    };
}

+ (instancetype)newWidgetOfType:(A2ControlWidgetType)type {
    A2ControlWidget *w = [self newButtonAtX:30 y:50];
    w.type = type;

    switch (type) {
        case A2ControlWidgetTypeButton:
            break;

        case A2ControlWidgetTypeTextBox:
            w.text = @"文本";
            w.isPenetrable = YES;
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeJoystick:
            w.identifier = @"air2.joystick";
            w.text = @"";
            w.xPercent = 6;
            w.yPercent = 58;
            w.widthPercent = 22;
            w.heightPercent = 30;
            w.triggerMode = A2JoystickTriggerModeDirection;
            w.deadZone = 0.15;
            w.lockThreshold = 0.3;
            w.canLock = NO;
            w.directionEvents = A2DefaultDirectionEvents();
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeGamepad:
            w.identifier = @"air2.gamepad";
            w.text = @"";
            w.xPercent = 4;
            w.yPercent = 46;
            w.widthPercent = 30;
            w.heightPercent = 26;
            w.gamepadMapping = A2DefaultGamepadMapping();
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeGyroscope:
            w.identifier = @"air2.gyroscope";
            w.text = @"陀螺仪";
            w.xPercent = 86;
            w.yPercent = 30;
            w.widthPercent = 11;
            w.heightPercent = 11;
            w.isToggleable = YES;
            w.gyroscopeEnabled = NO;
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeHotbar:
            w.identifier = @"air2.hotbar";
            w.text = @"";
            w.xPercent = 24;
            w.yPercent = 88;
            w.widthPercent = 52;
            w.heightPercent = 8;
            w.hotbarSlotCount = 9;
            {
                NSMutableArray<NSString *> *keys = [NSMutableArray array];
                // GLFW 数字键 1~9 的键码是 49~57，与 ZL2 Hotbar.kt 的 hotbarList 一致
                for (NSInteger i = 0; i < 9; i++) {
                    [keys addObject:[NSString stringWithFormat:@"%ld", (long)(49 + i)]];
                }
                w.hotbarKeys = keys;
            }
            w.hotbarSwapKey = @"70";   // F：切换副手（ZL2 双键）
            w.hotbarDropKey = @"81";   // Q：丢弃（ZL2 长按）
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeView:
            // 视角区：右侧大半屏，透明（0.02 是为了编辑器里还能看见/点中）
            w.identifier = @"air2.look";
            w.text = @"";
            w.xPercent = 30;
            w.yPercent = 0;
            w.widthPercent = 70;
            w.heightPercent = 100;
            w.opacity = 0.02;
            w.isSwipple = NO;
            w.isPenetrable = NO;      // 必须接触摸，否则转不了视角
            w.mouseMode = @"slide";
            w.mouseSensitivity = 100;
            w.viewScale = 1.0;
            w.viewShowsBorder = YES;
            w.clickEvents = @[];
            break;

        case A2ControlWidgetTypeScroll:
            // 滚轮：竖条，默认 18pt = 一格
            w.identifier = @"air2.scroll";
            w.text = @"滚轮";
            w.xPercent = 90;
            w.yPercent = 40;
            w.widthPercent = 7;
            w.heightPercent = 18;
            w.isSwipple = NO;
            w.scrollStep = 18;
            w.scrollInverted = NO;
            w.scrollHorizontal = NO;
            w.clickEvents = @[];
            break;
    }

    return w;
}

+ (instancetype)widgetFromJSON:(NSDictionary *)json
                          type:(A2ControlWidgetType)type
                       layerID:(NSString *)layerID {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ControlWidget *w = [A2ControlWidget new];
    w.type = type;
    w.layerID = layerID;
    w.rawJSON = json;

    // ---- 标识 ----
    w.identifier = A2Str(json, @[@"uuid", @"id", @"name"]) ?: [[NSUUID UUID] UUIDString];

    // ---- 文字 ----
    // 三家可能给字符串，也可能给 {"zh": "...", "en": "..."} 多语言字典
    id textVal = A2First(json, @[@"text", @"name", @"title", @"displayText"]);
    if ([textVal isKindOfClass:NSString.class]) {
        w.text = textVal;
    } else if ([textVal isKindOfClass:NSDictionary.class]) {
        NSDictionary *t = textVal;
        // ZL2 的 TranslatableString 是 {"default": "...", "matchQueue": [...]}；
        // FCL/老数据可能给 {"zh": "...", "en": "..."}。
        w.text = t[@"default"] ?: t[@"zh"] ?: t[@"zh_CN"] ?: t[@"zh-Hans"] ?: t[@"en"]
               ?: t.allValues.firstObject;
    }

    // ---- 位置 ----
    // ZL2/FCL 新版：position:{x,y}；FCL 老版：顶层 x/y 或 xPosition/yPosition
    id pos = A2First(json, @[@"position", @"pos"]);
    if (pos) {
        w.xPercent = A2Num(pos, @[@"x", @"percentageX", @"percentX"], 0);
        w.yPercent = A2Num(pos, @[@"y", @"percentageY", @"percentY"], 0);
    } else {
        w.xPercent = A2Num(json, @[@"x", @"xPosition", @"percentageX"], 0);
        w.yPercent = A2Num(json, @[@"y", @"yPosition", @"percentageY"], 0);
    }

    // ---- 尺寸 ----
    id size = A2First(json, @[@"buttonSize", @"size"]);
    if (size) {
        w.widthPercent  = A2Num(size, @[@"width", @"percentageWidth", @"widthPercentage"], 0);
        w.heightPercent = A2Num(size, @[@"height", @"percentageHeight", @"heightPercentage"], 0);
        w.sizeType = A2Str(size, @[@"type"]);
    }
    if (w.widthPercent <= 0) {
        w.widthPercent = A2Num(json, @[@"widthPercentage", @"percentageWidth",
                                       @"width", @"absoluteWidth"], 0);
    }
    if (w.heightPercent <= 0) {
        w.heightPercent = A2Num(json, @[@"heightPercentage", @"percentageHeight",
                                        @"height", @"absoluteHeight"], 0);
    }
    if (!w.sizeType.length) w.sizeType = A2Str(json, @[@"sizeType"]);

    // ---- 圆角 ----
    // ZL2：buttonShape{topStart,topEnd,bottomEnd,bottomStart}
    // FCL：cornerRadius（单值）
    id shape = A2First(json, @[@"buttonShape", @"shape"]);
    if (shape) {
        w.cornerTopStart    = A2Num(shape, @[@"topStart"], 20);
        w.cornerTopEnd      = A2Num(shape, @[@"topEnd"], 20);
        w.cornerBottomEnd   = A2Num(shape, @[@"bottomEnd"], 20);
        w.cornerBottomStart = A2Num(shape, @[@"bottomStart"], 20);
    } else {
        double r = A2Num(json, @[@"cornerRadius", @"borderRadius"], 20);
        w.cornerTopStart = w.cornerTopEnd = w.cornerBottomEnd = w.cornerBottomStart = r;
    }

    // ---- 外观 ----
    w.buttonStyle = A2Str(json, @[@"buttonStyle", @"style", @"styleId"]);

    // 不透明度：内部格式写 opacity；ZL2/FCL 导出时写 air2Opacity（扩展键）
    w.opacity = A2Num(json, @[@"opacity", @"alpha", @"air2Opacity"], 1.0);
    if (!isfinite(w.opacity)) w.opacity = 1.0;
    w.opacity = MAX(0.0, MIN(1.0, w.opacity));

    // ---- 行为 ----
    w.isSwipple    = A2Bool(json, @[@"isSwipple", @"swipple", @"isSwipeable"], NO);
    w.isPenetrable = A2Bool(json, @[@"isPenetrable", @"penetrable"], NO);
    w.isToggleable = A2Bool(json, @[@"isToggleable", @"toggleable"], NO);

    // ---- 可见性 ----
    NSString *vis = A2Str(json, @[@"visibilityType", @"visibility"]);
    if ([vis isEqualToString:@"in_game"]) w.visibility = A2ControlVisibilityInGame;
    else if ([vis isEqualToString:@"in_menu"]) w.visibility = A2ControlVisibilityInMenu;
    else w.visibility = A2ControlVisibilityAlways;

    // ---- 尺寸参考边 / dp 尺寸（ZL2 原生字段）----
    w.widthReference = A2Str(json, @[@"widthReference"]) ?: A2Str(size, @[@"widthReference"]);
    w.heightReference = A2Str(json, @[@"heightReference"]) ?: A2Str(size, @[@"heightReference"]);
    w.widthDp = A2Num(json, @[@"widthDp"], A2Num(size, @[@"widthDp"], 0));
    w.heightDp = A2Num(json, @[@"heightDp"], A2Num(size, @[@"heightDp"], 0));
    w.styleType = A2Str(json, @[@"styleType"]);

    // ---- 点击事件 ----
    w.clickEvents = A2EventsFromArray(A2First(json, @[@"clickEvents", @"events", @"actions"]));

    // ---- 摇杆参数（对照 ZL2 JoystickData / FCL DirectionEventData）----
    NSString *triggerMode = A2Str(json, @[@"triggerMode"]);
    BOOL rocker = [triggerMode isEqualToString:@"rocker"] ||
                  [triggerMode isEqualToString:@"ROCKER"] ||
                  [w.styleType isEqualToString:@"ROCKER"];
    w.triggerMode = rocker ? A2JoystickTriggerModeRocker : A2JoystickTriggerModeDirection;
    w.deadZone = A2Num(json, @[@"deadZoneRatio", @"deadZone"], 0.15);
    if (w.deadZone > 1.0) w.deadZone /= 100.0;      // FCL 存 0~90，ZL2 存 0~1
    if (!isfinite(w.deadZone) || w.deadZone < 0) w.deadZone = 0;
    if (w.deadZone > 0.9) w.deadZone = 0.9;
    w.canLock = A2Bool(json, @[@"canLock"], NO);
    w.lockThreshold = A2Num(json, @[@"lockThreshold"], 0.3);
    if (w.lockThreshold > 1.0) w.lockThreshold /= 100.0;
    w.directionEvents = A2DirectionEventsFromJSON(A2First(json, @[@"directionEvents"]));
    w.lockEvents = A2EventsFromArray(A2First(json, @[@"lockEvents"]));

    // ---- 陀螺仪参数（对照 ZL2 GyroscopeReader 的采样参数）----
    w.gyroscopeSensitivity = A2Num(json, @[@"gyroscopeSensitivity", @"sensitivity"], 1.0);
    w.gyroscopeSmoothingWindow = (NSInteger)A2Num(json, @[@"gyroscopeSmoothingWindow",
                                                          @"smoothingWindow"], 4);
    w.gyroscopeThreshold = A2Num(json, @[@"gyroscopeThreshold", @"threshold"], 0.02);
    w.gyroscopeEnabled = A2Bool(json, @[@"gyroscopeEnabled", @"enabled"], NO);

    // ---- 快捷栏参数（对照 ZL2 Hotbar.kt）----
    w.hotbarSlotCount = (NSInteger)A2Num(json, @[@"hotbarSlotCount", @"slotCount"], 9);
    if (w.hotbarSlotCount < 1) w.hotbarSlotCount = 9;
    if (w.hotbarSlotCount > 9) w.hotbarSlotCount = 9;   // Minecraft 只有 9 格
    id keysArr = A2First(json, @[@"hotbarKeys", @"slotKeys"]);
    if ([keysArr isKindOfClass:NSArray.class]) {
        NSMutableArray *keys = [NSMutableArray array];
        for (id k in (NSArray *)keysArr) {
            if ([k isKindOfClass:NSString.class]) [keys addObject:k];
            else if ([k isKindOfClass:NSNumber.class]) [keys addObject:[k stringValue]];
        }
        w.hotbarKeys = keys;
    }
    w.hotbarSwapKey = A2Str(json, @[@"hotbarSwapKey", @"swapKey"]) ?: @"70";   // F
    w.hotbarDropKey = A2Str(json, @[@"hotbarDropKey", @"dropKey"]) ?: @"81";   // Q

    // ---- 手柄映射（对照 ZL2 gamepad/GamepadMap.kt）----
    id mapping = A2First(json, @[@"gamepadMapping", @"buttonMapping"]);
    if ([mapping isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (id k in (NSDictionary *)mapping) {
            id v = ((NSDictionary *)mapping)[k];
            if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) {
                clean[k] = v;
            } else if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSNumber.class]) {
                clean[k] = [v stringValue];
            }
        }
        w.gamepadMapping = clean.count ? clean : nil;
    }

    // ---- 鼠标面板参数（对照 ZL2 MouseControlMode / cursorSensitivity）----
    w.mouseMode = A2Str(json, @[@"mouseMode", @"controlMode"]);
    w.mouseSensitivity = A2Num(json, @[@"mouseSensitivity", @"cursorSensitivity"], 100);

    // ---- 视角区参数（type == View）----
    w.viewScale = A2Num(json, @[@"viewScale"], 1.0);
    if (!isfinite(w.viewScale) || w.viewScale <= 0) w.viewScale = 1.0;
    w.viewShowsBorder = A2Bool(json, @[@"viewShowsBorder"], YES);
    if (!w.mouseMode.length && type == A2ControlWidgetTypeView) w.mouseMode = @"slide";

    // ---- 滚轮参数（type == Scroll）----
    w.scrollStep = A2Num(json, @[@"scrollStep"], 18.0);
    if (!isfinite(w.scrollStep) || w.scrollStep < 4) w.scrollStep = 18.0;
    w.scrollInverted = A2Bool(json, @[@"scrollInverted"], NO);
    w.scrollHorizontal = A2Bool(json, @[@"scrollHorizontal"], NO);

    return w;
}

- (NSDictionary *)toJSON {
    // 以原始 JSON 为底 —— 保留我们不认识的字段
    NSMutableDictionary *d = self.rawJSON
        ? [self.rawJSON mutableCopy] : [NSMutableDictionary dictionary];

    d[@"uuid"] = self.identifier;
    if (self.text.length) d[@"text"] = self.text;

    // 位置/尺寸：写回时【保持原来的键名】
    BOOL usesTopLevelXY = (d[@"position"] == nil &&
                           (d[@"x"] != nil || d[@"xPosition"] != nil));
    if (usesTopLevelXY) {
        d[@"x"] = @(self.xPercent);
        d[@"y"] = @(self.yPercent);
    } else {
        NSMutableDictionary *pos = [NSMutableDictionary dictionary];
        [pos addEntriesFromDictionary:[self dictOrEmpty:d[@"position"]]];
        if (pos[@"percentageX"] != nil) {
            pos[@"percentageX"] = @(self.xPercent);
            pos[@"percentageY"] = @(self.yPercent);
        } else {
            pos[@"x"] = @(self.xPercent);
            pos[@"y"] = @(self.yPercent);
        }
        d[@"position"] = pos;
    }

    NSString *sizeKey = @"buttonSize";
    if (d[@"size"] != nil && d[@"buttonSize"] == nil) sizeKey = @"size";
    NSMutableDictionary *size = [NSMutableDictionary dictionary];
    [size addEntriesFromDictionary:[self dictOrEmpty:d[sizeKey]]];
    size[@"width"] = @(self.widthPercent);
    size[@"height"] = @(self.heightPercent);
    if (self.sizeType.length) size[@"type"] = self.sizeType;
    d[sizeKey] = size;

    if (self.buttonStyle.length) d[@"buttonStyle"] = self.buttonStyle;

    d[@"isSwipple"] = @(self.isSwipple);
    d[@"isPenetrable"] = @(self.isPenetrable);
    d[@"isToggleable"] = @(self.isToggleable);

    switch (self.visibility) {
        case A2ControlVisibilityInGame: d[@"visibilityType"] = @"in_game"; break;
        case A2ControlVisibilityInMenu: d[@"visibilityType"] = @"in_menu"; break;
        default:                        d[@"visibilityType"] = @"always"; break;
    }

    NSMutableArray *events = [NSMutableArray array];
    for (A2ControlEvent *e in self.clickEvents) [events addObject:[e toJSON]];
    d[@"clickEvents"] = events;

    // ---- 尺寸参考边 / dp ----
    if (self.widthReference.length) d[@"widthReference"] = self.widthReference;
    if (self.heightReference.length) d[@"heightReference"] = self.heightReference;
    if (self.widthDp > 0) d[@"widthDp"] = @(self.widthDp);
    if (self.heightDp > 0) d[@"heightDp"] = @(self.heightDp);
    if (self.styleType.length) d[@"styleType"] = self.styleType;

    // ---- 按类型写回专有字段（不相关的不写，免得污染其他格式）----
    switch (self.type) {
        case A2ControlWidgetTypeJoystick: {
            d[@"triggerMode"] = (self.triggerMode == A2JoystickTriggerModeRocker)
                ? @"rocker" : @"drag";
            d[@"deadZoneRatio"] = @(self.deadZone);
            d[@"lockThreshold"] = @(self.lockThreshold);
            d[@"canLock"] = @(self.canLock);
            if (self.directionEvents) {
                NSMutableDictionary *dirs = [NSMutableDictionary dictionary];
                for (NSString *dir in self.directionEvents) {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (A2ControlEvent *e in self.directionEvents[dir]) [arr addObject:[e toJSON]];
                    dirs[dir] = arr;
                }
                d[@"directionEvents"] = dirs;
            }
            if (self.lockEvents) {
                NSMutableArray *arr = [NSMutableArray array];
                for (A2ControlEvent *e in self.lockEvents) [arr addObject:[e toJSON]];
                d[@"lockEvents"] = arr;
            }
            break;
        }

        case A2ControlWidgetTypeGamepad:
            if (self.gamepadMapping) d[@"gamepadMapping"] = self.gamepadMapping;
            break;

        case A2ControlWidgetTypeGyroscope:
            d[@"gyroscopeSensitivity"] = @(self.gyroscopeSensitivity);
            d[@"gyroscopeSmoothingWindow"] = @(self.gyroscopeSmoothingWindow);
            d[@"gyroscopeThreshold"] = @(self.gyroscopeThreshold);
            d[@"gyroscopeEnabled"] = @(self.gyroscopeEnabled);
            break;

        case A2ControlWidgetTypeHotbar:
            d[@"hotbarSlotCount"] = @(self.hotbarSlotCount);
            if (self.hotbarKeys) d[@"hotbarKeys"] = self.hotbarKeys;
            if (self.hotbarSwapKey.length) d[@"hotbarSwapKey"] = self.hotbarSwapKey;
            if (self.hotbarDropKey.length) d[@"hotbarDropKey"] = self.hotbarDropKey;
            break;

        default:
            break;
    }

    if (self.mouseMode.length) d[@"mouseMode"] = self.mouseMode;
    if (self.mouseSensitivity > 0) d[@"mouseSensitivity"] = @(self.mouseSensitivity);

    // ---- 不透明度 + 视角区 / 滚轮 ----
    // 这三个是 Air2 扩展。内部格式直接写；导出 ZL2/FCL 时由各自的
    // serializer 写 air2Opacity / viewScale 等扩展键（见 A2ControlFormatZL/FCL）。
    d[@"opacity"] = @(self.opacity);
    switch (self.type) {
        case A2ControlWidgetTypeView:
            d[@"viewScale"] = @(self.viewScale);
            d[@"viewShowsBorder"] = @(self.viewShowsBorder);
            break;
        case A2ControlWidgetTypeScroll:
            d[@"scrollStep"] = @(self.scrollStep);
            d[@"scrollInverted"] = @(self.scrollInverted);
            d[@"scrollHorizontal"] = @(self.scrollHorizontal);
            break;
        default:
            break;
    }

    return d;
}

- (A2ControlWidget *)duplicatedWidget {
    // 走一次"序列化 → 解析"：保证所有字段（含 rawJSON 里的未知键）都带上，
    // 以后加字段也不用改这里。identifier 必须换新的，否则渲染层两票同 id。
    NSDictionary *json = [self toJSON];
    A2ControlWidget *copy = [A2ControlWidget widgetFromJSON:json
                                                       type:self.type
                                                    layerID:self.layerID];
    copy.identifier = [[NSUUID UUID] UUIDString];
    copy.rawJSON = json;
    return copy;
}

- (NSDictionary *)dictOrEmpty:(id)v {
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

@end

#pragma mark - 层

@implementation A2ControlLayer

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _widgets = [NSMutableArray array];
    _visibleByDefault = YES;
    // 默认值对齐 CcFclToZl.normalizeZlLayout：
    //   hideWhenMouse = true、hideWhenGamepad = true、hideWhenJoystick = false
    _hideWhenMouse = YES;
    _hideWhenGamepad = YES;
    _hideWhenJoystick = NO;
    return self;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = self.rawJSON
        ? [self.rawJSON mutableCopy] : [NSMutableDictionary dictionary];

    // ZL2 层的 id 字段叫 uuid；老 Air1/Air2 数据是 id。
    // 以 rawJSON 的键名为准，两边都保留会互相覆盖。
    if (d[@"uuid"] != nil || d[@"id"] == nil) d[@"uuid"] = self.identifier;
    if (d[@"id"] != nil) d[@"id"] = self.identifier;
    if (self.name.length) d[@"name"] = self.name;

    d[@"hide"] = @(!self.visibleByDefault);
    d[@"hideWhenMouse"] = @(self.hideWhenMouse);
    d[@"hideWhenGamepad"] = @(self.hideWhenGamepad);
    d[@"hideWhenJoystick"] = @(self.hideWhenJoystick);

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *joysticks = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];
    NSMutableArray *gamepads = [NSMutableArray array];
    NSMutableArray *gyroscopes = [NSMutableArray array];
    NSMutableArray *hotbars = [NSMutableArray array];
    NSMutableArray *views = [NSMutableArray array];
    NSMutableArray *scrolls = [NSMutableArray array];

    for (A2ControlWidget *w in self.widgets) {
        NSDictionary *j = [w toJSON];
        switch (w.type) {
            case A2ControlWidgetTypeButton:    [buttons addObject:j]; break;
            case A2ControlWidgetTypeJoystick:  [joysticks addObject:j]; break;
            case A2ControlWidgetTypeTextBox:   [texts addObject:j]; break;
            case A2ControlWidgetTypeGamepad:   [gamepads addObject:j]; break;
            case A2ControlWidgetTypeGyroscope: [gyroscopes addObject:j]; break;
            case A2ControlWidgetTypeHotbar:    [hotbars addObject:j]; break;
            case A2ControlWidgetTypeView:      [views addObject:j]; break;
            case A2ControlWidgetTypeScroll:    [scrolls addObject:j]; break;
        }
    }

    // 沿用原有键名：ZL2 用 normalButtons，FCL 用 buttonList
    NSString *btnKey = (d[@"buttonList"] && !d[@"normalButtons"]) ? @"buttonList" : @"normalButtons";
    if (buttons.count || d[btnKey]) d[btnKey] = buttons;
    if (joysticks.count || d[@"joystickButtons"]) d[@"joystickButtons"] = joysticks;
    if (texts.count || d[@"textBoxes"]) d[@"textBoxes"] = texts;

    // 新增的三类是 Air2 的扩展键名：
    //   读 ZL2/FCL 时它们不存在，所以只有真的有时才写，避免产出对方不认识的文件。
    if (gamepads.count)   d[@"gamepadButtons"] = gamepads;
    if (gyroscopes.count) d[@"gyroscopeButtons"] = gyroscopes;
    if (hotbars.count)    d[@"hotbarButtons"] = hotbars;
    if (views.count)      d[@"viewAreas"] = views;
    if (scrolls.count)    d[@"scrollButtons"] = scrolls;

    return d;
}

@end

#pragma mark - 布局

// sourceFormat 已在 A2ControlLayout.h 里声明为 readwrite
// （跨编译单元的解析器需要直接赋值），这里不再重复声明，
// 否则会报 illegal redeclaration。

@implementation A2ControlLayout

+ (instancetype)emptyLayout {
    A2ControlLayout *l = [A2ControlLayout new];
    l.sourceFormat = @"air2";
    l.version = 12;
    l.name = @"新布局";
    l.author = @"Air2";
    l.aspectRatio = 16.0 / 9.0;
    l.layers = [NSMutableArray array];

    A2ControlLayer *layer = [A2ControlLayer new];
    layer.identifier = @"default";
    layer.name = @"默认层";
    [l.layers addObject:layer];

    l.buttonStyles = [NSMutableDictionary dictionary];
    l.joystickStyles = [NSMutableDictionary dictionary];
    return l;
}

+ (instancetype)layoutFromJSON:(NSDictionary *)json error:(NSError **)error {
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [self errorWith:@"不是有效的 JSON 对象"];
        return nil;
    }

    // ---- 原生格式走格式层 ----
    // ZL2 / FCL 的 position 是「可用空间比例」、尺寸还可能以屏幕高为参考边，
    // 直接按 0~100 屏幕百分比读会整体错位（见 A2ControlLayout.h 的坐标换算说明）。
    // 所以这两种格式交给 A2ControlFormat 里的专用解析器，这里只保留 Air1 的通用路径。
    A2ControlFormatKind kind = [A2ControlFormat detectFormat:json];
    if (kind == A2ControlFormatKindFCL || kind == A2ControlFormatKindZL2) {
        return [A2ControlFormat layoutFromJSON:json error:error];
    }

    A2ControlLayout *layout = [A2ControlLayout new];
    layout.rawRoot = json;
    layout.layers = [NSMutableArray array];
    layout.buttonStyles = [NSMutableDictionary dictionary];
    layout.joystickStyles = [NSMutableDictionary dictionary];
    layout.aspectRatio = 16.0 / 9.0;

    // ---- 格式识别 ----
    // Air2 自己的内部格式带 air2Version / format=air2 标记。
    // 必须排在 layers 判断之前 —— 内部格式也用 layers[]，但坐标是
    // 屏幕百分比（0~100），被当成 ZL2 会错十倍。
    if (json[@"air2Version"] != nil ||
        [A2Str(json, @[@"format"]) isEqualToString:@"air2"]) {
        layout.sourceFormat = @"air2";
        layout.version = MAX([self currentFormatVersion], [json[@"air2Version"] integerValue]);
    } else if (json[@"layers"] != nil) {
        layout.sourceFormat = @"zl2";
        layout.version = [json[@"editorVersion"] integerValue];
    } else if (json[@"viewGroups"] != nil) {
        layout.sourceFormat = @"fcl";
        layout.version = [json[@"controllerVersion"] integerValue];
    } else {
        layout.sourceFormat = @"air1";
        layout.version = [json[@"editorVersion"] integerValue];
    }

    layout.name = A2Str(json, @[@"name", @"layoutName"]) ?: @"未命名布局";
    layout.author = A2Str(json, @[@"author"]);

    // ---- 层 ----
    // ZL2/Air1: layers[]；FCL: viewGroups[]{viewGroup}
    NSArray *containers = (layout.sourceFormat == @"fcl") ? json[@"viewGroups"] : json[@"layers"];
    if (![containers isKindOfClass:NSArray.class]) containers = @[json];

    for (NSUInteger i = 0; i < containers.count; i++) {
        NSDictionary *c = containers[i];
        if (![c isKindOfClass:NSDictionary.class]) continue;

        // FCL 的 viewGroup 可能再包一层
        NSDictionary *groupBody = [c[@"viewGroup"] isKindOfClass:NSDictionary.class]
            ? c[@"viewGroup"] : c;

        A2ControlLayer *layer = [A2ControlLayer new];
        layer.identifier = A2Str(groupBody, @[@"uuid", @"id", @"name"])
            ?: [NSString stringWithFormat:@"layer%lu", (unsigned long)i];
        layer.name = A2Str(groupBody, @[@"name", @"id"]) ?: layer.identifier;
        layer.visibleByDefault = !A2Bool(groupBody, @[@"hide"], NO);
        layer.hideWhenMouse = A2Bool(groupBody, @[@"hideWhenMouse"], YES);
        layer.hideWhenGamepad = A2Bool(groupBody, @[@"hideWhenGamepad"], YES);
        layer.hideWhenJoystick = A2Bool(groupBody, @[@"hideWhenJoystick"], NO);
        layer.rawJSON = groupBody;
        [layout collectWidgetsFrom:groupBody into:layer];
        [layout.layers addObject:layer];
    }

    // ---- 样式表 ----
    for (NSString *key in @[@"buttonStyles", @"styles"]) {
        id styles = json[key];
        if ([styles isKindOfClass:NSArray.class]) {
            for (NSDictionary *s in styles) {
                if (![s isKindOfClass:NSDictionary.class]) continue;
                NSString *sid = A2Str(s, @[@"id", @"uuid", @"name"]);
                if (sid.length) layout.buttonStyles[sid] = s;
            }
        } else if ([styles isKindOfClass:NSDictionary.class]) {
            [layout.buttonStyles addEntriesFromDictionary:styles];
        }
    }
    id joystickStyles = json[@"joystickStyles"];
    if ([joystickStyles isKindOfClass:NSArray.class]) {
        for (NSDictionary *s in (NSArray *)joystickStyles) {
            if (![s isKindOfClass:NSDictionary.class]) continue;
            NSString *sid = A2Str(s, @[@"id", @"uuid", @"name"]);
            if (sid.length) layout.joystickStyles[sid] = s;
        }
    } else if ([joystickStyles isKindOfClass:NSDictionary.class]) {
        [layout.joystickStyles addEntriesFromDictionary:(NSDictionary *)joystickStyles];
    }

    [layout normalize];

    [A2Logger info:@"A2ControlLayout"
           message:[NSString stringWithFormat:@"加载「%@」：格式=%@ 版本=%ld 层=%lu 控件=%lu",
                    layout.name, layout.sourceFormat, (long)layout.version,
                    (unsigned long)layout.layers.count,
                    (unsigned long)layout.allWidgets.count]];

    return layout;
}

/// 从一个容器里收集控件。
/// 三家键名不同：normalButtons/buttonList、joystickButtons/directionList...
- (void)collectWidgetsFrom:(NSDictionary *)container into:(A2ControlLayer *)layer {
    struct {
        NSArray *keys;
        A2ControlWidgetType type;
    } groups[] = {
        { @[@"normalButtons", @"buttonList", @"buttons"], A2ControlWidgetTypeButton },
        { @[@"joystickButtons", @"directionList", @"stockButtons"], A2ControlWidgetTypeJoystick },
        { @[@"textBoxes", @"textButtons"], A2ControlWidgetTypeTextBox },
        // Air2 扩展的三类（读到就收，读不到不影响老布局）
        { @[@"gamepadButtons", @"gamepads"], A2ControlWidgetTypeGamepad },
        { @[@"gyroscopeButtons", @"gyroscopes"], A2ControlWidgetTypeGyroscope },
        { @[@"hotbarButtons", @"hotbars"], A2ControlWidgetTypeHotbar },
        // Air2 扩展的「视角区 / 滚轮」（ZL2/FCL 没有对应类型）
        { @[@"viewAreas", @"viewAreaButtons"], A2ControlWidgetTypeView },
        { @[@"scrollButtons", @"scrollAreas"], A2ControlWidgetTypeScroll },
    };

    for (size_t i = 0; i < sizeof(groups) / sizeof(groups[0]); i++) {
        NSArray *list = nil;
        for (NSString *k in groups[i].keys) {
            id v = container[k];
            if ([v isKindOfClass:NSArray.class]) { list = v; break; }
        }
        if (!list) continue;

        for (NSDictionary *j in list) {
            A2ControlWidget *w = [A2ControlWidget widgetFromJSON:j
                                                            type:groups[i].type
                                                         layerID:layer.identifier];
            if (w) [layer.widgets addObject:w];
        }
    }
}

- (NSArray<A2ControlWidget *> *)allWidgets {
    NSMutableArray *out = [NSMutableArray array];
    for (A2ControlLayer *l in self.layers) {
        [out addObjectsFromArray:l.widgets];
    }
    return out;
}

+ (instancetype)layoutFromFile:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [self errorWith:@"不是 JSON 对象"];
        return nil;
    }
    return [self layoutFromJSON:json error:error];
}

- (BOOL)writeToFile:(NSString *)path error:(NSError **)error {
    // 按来源格式写回 —— 导入的 FCL 文件仍然能被 FCL 读，
    // 导入的 ZL2 文件仍然能被 ZL2 读。这是「原生支持」的另一半。
    A2ControlFormatKind kind = [A2ControlFormat kindForName:self.sourceFormat];
    NSDictionary *root = nil;
    switch (kind) {
        case A2ControlFormatKindFCL:
            root = [A2ControlFormat jsonFromLayout:self format:kind];
            break;
        case A2ControlFormatKindZL2:
            root = [A2ControlFormat jsonFromLayout:self format:kind];
            break;
        default:
            root = [self genericJSON];
            break;
    }
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error) *error = [A2ControlLayout errorWith:@"序列化失败"];
        return NO;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

/// Air1 / Air2 通用格式（layers[] + normalButtons/joystickButtons/textBoxes）
- (NSDictionary *)genericJSON {
    NSMutableDictionary *root = self.rawRoot
        ? [self.rawRoot mutableCopy] : [NSMutableDictionary dictionary];

    NSMutableArray *containers = [NSMutableArray array];
    for (A2ControlLayer *layer in self.layers) {
        [containers addObject:[layer toJSON]];
    }

    root[@"layers"] = containers;
    if (!root[@"editorVersion"]) {
        root[@"editorVersion"] = @(MAX(12, self.version));
    }
    if (!root[@"name"]) root[@"name"] = self.name;
    return root;
}

+ (NSInteger)currentFormatVersion {
    // 1 = layers[] + 屏幕百分比 + opacity/viewAreas/scrollButtons 扩展键
    //     （旧的 Air1 数据没有版本号，normalize 时按 1 处理并补齐字段）
    return 1;
}

#pragma mark - 归一化 / 迁移

- (void)normalize {
    if (![self.layers isKindOfClass:NSMutableArray.class]) {
        self.layers = [NSMutableArray arrayWithArray:self.layers ?: @[]];
    }
    if (![self.buttonStyles isKindOfClass:NSMutableDictionary.class]) {
        self.buttonStyles = [NSMutableDictionary dictionary];
    }
    if (![self.joystickStyles isKindOfClass:NSMutableDictionary.class]) {
        self.joystickStyles = [NSMutableDictionary dictionary];
    }
    if (!isfinite(self.aspectRatio) || self.aspectRatio <= 0.05) {
        self.aspectRatio = 16.0 / 9.0;
    }
    if (!self.name.length) self.name = @"未命名布局";
    if (!self.sourceFormat.length) self.sourceFormat = @"air2";

    // 至少一层 —— 渲染层与编辑器都假设 layers[0] 存在
    if (self.layers.count == 0) {
        A2ControlLayer *layer = [A2ControlLayer new];
        layer.identifier = @"default";
        layer.name = @"默认层";
        [self.layers addObject:layer];
    }

    NSMutableSet<NSString *> *usedLayerIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *usedWidgetIDs = [NSMutableSet set];

    for (A2ControlLayer *layer in self.layers) {
        if (!layer.identifier.length) {
            layer.identifier = [[NSUUID UUID] UUIDString];
        }
        // 层 id 去重（重复 id 会让 switch_layer 事件指向不确定的层）
        if ([usedLayerIDs containsObject:layer.identifier]) {
            layer.identifier = [[NSUUID UUID] UUIDString];
        }
        [usedLayerIDs addObject:layer.identifier];
        if (!layer.name.length) layer.name = layer.identifier;
        if (![layer.widgets isKindOfClass:NSMutableArray.class]) {
            layer.widgets = [NSMutableArray arrayWithArray:layer.widgets ?: @[]];
        }

        for (A2ControlWidget *w in layer.widgets) {
            if (!w.identifier.length) w.identifier = [[NSUUID UUID] UUIDString];
            if ([usedWidgetIDs containsObject:w.identifier]) {
                w.identifier = [[NSUUID UUID] UUIDString];
            }
            [usedWidgetIDs addObject:w.identifier];
            w.layerID = layer.identifier;
            if (!w.clickEvents) w.clickEvents = @[];

            // 坐标/尺寸夹紧。0 尺寸的控件渲染层会给默认值，但数据里
            // 也应该收成有效值，否则导出到 ZL2/FCL 会被对方判成非法。
            if (!isfinite(w.xPercent)) w.xPercent = 0;
            if (!isfinite(w.yPercent)) w.yPercent = 0;
            if (!isfinite(w.widthPercent)) w.widthPercent = 0;
            if (!isfinite(w.heightPercent)) w.heightPercent = 0;
            if (w.widthPercent <= 0) w.widthPercent = 12;
            if (w.heightPercent <= 0) w.heightPercent = 12;
            w.widthPercent = MAX(1.0, MIN(100.0, w.widthPercent));
            w.heightPercent = MAX(1.0, MIN(100.0, w.heightPercent));
            w.xPercent = MAX(0.0, MIN(100.0 - w.widthPercent, w.xPercent));
            w.yPercent = MAX(0.0, MIN(100.0 - w.heightPercent, w.yPercent));

            if (!isfinite(w.opacity)) w.opacity = 1;
            w.opacity = MAX(0.0, MIN(1.0, w.opacity));
            w.cornerTopStart = MAX(0, MIN(100, w.cornerTopStart));
            w.cornerTopEnd = MAX(0, MIN(100, w.cornerTopEnd));
            w.cornerBottomEnd = MAX(0, MIN(100, w.cornerBottomEnd));
            w.cornerBottomStart = MAX(0, MIN(100, w.cornerBottomStart));

            if (!isfinite(w.deadZone)) w.deadZone = 0.15;
            w.deadZone = MAX(0, MIN(0.9, w.deadZone));
            if (!isfinite(w.lockThreshold)) w.lockThreshold = 0.3;
            w.lockThreshold = MAX(0, MIN(1, w.lockThreshold));

            if (w.type == A2ControlWidgetTypeJoystick &&
                !w.directionEvents && w.clickEvents.count == 0) {
                w.directionEvents = A2DefaultDirectionEvents();
            }
            if (w.type == A2ControlWidgetTypeView) {
                if (!w.mouseMode.length) w.mouseMode = @"slide";
                if (!isfinite(w.viewScale) || w.viewScale <= 0) w.viewScale = 1.0;
            }
            if (w.type == A2ControlWidgetTypeScroll) {
                if (!isfinite(w.scrollStep) || w.scrollStep < 4) w.scrollStep = 18;
            }
            if (w.type == A2ControlWidgetTypeGyroscope) {
                if (!isfinite(w.gyroscopeSensitivity) || w.gyroscopeSensitivity <= 0) {
                    w.gyroscopeSensitivity = 1.0;
                }
                if (w.gyroscopeSmoothingWindow < 1) w.gyroscopeSmoothingWindow = 4;
                if (!isfinite(w.gyroscopeThreshold)) w.gyroscopeThreshold = 0.02;
            }
        }
    }

    // 版本号：Air1 老数据没有版本号，这里补成当前内部版本；
    // ZL2/FCL 的源版本号（editorVersion/controllerVersion）在各自 parser
    // 里已经记下，不在这里覆盖，避免导出时版本倒退。
    if (self.version <= 0) self.version = [A2ControlLayout currentFormatVersion];
}

#pragma mark - 快照

- (NSDictionary *)snapshotJSON {
    NSMutableArray *layers = [NSMutableArray array];
    for (A2ControlLayer *layer in self.layers) {
        NSMutableArray *widgets = [NSMutableArray array];
        for (A2ControlWidget *w in layer.widgets) {
            [widgets addObject:@{
                @"type": @(w.type),
                @"json": [w toJSON],
            }];
        }
        [layers addObject:@{
            @"id": layer.identifier ?: @"",
            @"name": layer.name ?: @"",
            @"visible": @(layer.visibleByDefault),
            @"hideWhenMouse": @(layer.hideWhenMouse),
            @"hideWhenGamepad": @(layer.hideWhenGamepad),
            @"hideWhenJoystick": @(layer.hideWhenJoystick),
            @"widgets": widgets,
        }];
    }
    return @{
        @"format": @"air2-snapshot",
        @"air2Version": @([A2ControlLayout currentFormatVersion]),
        @"name": self.name ?: @"",
        @"author": self.author ?: @"",
        @"aspectRatio": @(self.aspectRatio),
        @"sourceFormat": self.sourceFormat ?: @"air2",
        @"layers": layers,
    };
}

+ (instancetype)layoutFromSnapshot:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:NSDictionary.class]) return nil;

    A2ControlLayout *layout = [A2ControlLayout new];
    layout.sourceFormat = A2Str(snapshot, @[@"sourceFormat"]) ?: @"air2";
    layout.version = (NSInteger)A2Num(snapshot, @[@"air2Version"], 1);
    layout.name = A2Str(snapshot, @[@"name"]) ?: @"未命名布局";
    layout.author = A2Str(snapshot, @[@"author"]);
    layout.aspectRatio = A2Num(snapshot, @[@"aspectRatio"], 16.0 / 9.0);
    layout.layers = [NSMutableArray array];
    layout.buttonStyles = [NSMutableDictionary dictionary];
    layout.joystickStyles = [NSMutableDictionary dictionary];

    NSArray *layers = [snapshot[@"layers"] isKindOfClass:NSArray.class]
        ? snapshot[@"layers"] : @[];
    for (NSDictionary *lj in layers) {
        if (![lj isKindOfClass:NSDictionary.class]) continue;
        A2ControlLayer *layer = [A2ControlLayer new];
        layer.identifier = A2Str(lj, @[@"id"]) ?: [[NSUUID UUID] UUIDString];
        layer.name = A2Str(lj, @[@"name"]) ?: layer.identifier;
        layer.visibleByDefault = A2Bool(lj, @[@"visible"], YES);
        layer.hideWhenMouse = A2Bool(lj, @[@"hideWhenMouse"], YES);
        layer.hideWhenGamepad = A2Bool(lj, @[@"hideWhenGamepad"], YES);
        layer.hideWhenJoystick = A2Bool(lj, @[@"hideWhenJoystick"], NO);

        NSArray *widgets = [lj[@"widgets"] isKindOfClass:NSArray.class]
            ? lj[@"widgets"] : @[];
        for (NSDictionary *entry in widgets) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSNumber *typeNum = entry[@"type"];
            NSDictionary *json = entry[@"json"];
            if (![typeNum isKindOfClass:NSNumber.class] ||
                ![json isKindOfClass:NSDictionary.class]) continue;
            A2ControlWidget *w = [A2ControlWidget widgetFromJSON:json
                                                            type:(A2ControlWidgetType)typeNum.integerValue
                                                         layerID:layer.identifier];
            if (w) [layer.widgets addObject:w];
        }
        [layout.layers addObject:layer];
    }

    [layout normalize];
    return layout;
}

+ (NSError *)errorWith:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ControlLayout" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
