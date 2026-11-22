//
//  A2ControlFormatFCL.m
//  Air2
//
//  FCL 控件格式的解析与序列化。见 .h 的说明。
//

#import "A2ControlFormatFCL.h"
#import "A2ControlInput.h"
#import "A2KeyCodeMap.h"
#import "A2Logger.h"

const NSInteger A2FCLControllerVersion = 21;

/// FCL 用 411dp 作为「设计基准屏高」（与 CcGeometry/CcConstants 里的假设一致）
static const CGFloat A2FCLReferenceScreenHeightDp = 411.0;

#pragma mark - 小工具

static double FCLNum(id v, double fallback) {
    if ([v isKindOfClass:NSNumber.class]) return [v doubleValue];
    if ([v isKindOfClass:NSString.class]) return [v doubleValue];
    return fallback;
}

static NSString *FCLStr(id v) {
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}

static BOOL FCLBool(id v, BOOL fallback) {
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    if ([v isKindOfClass:NSString.class]) return [v boolValue];
    return fallback;
}

static NSArray *FCLArray(id v) {
    return [v isKindOfClass:NSArray.class] ? v : @[];
}

static NSDictionary *FCLDict(id v) {
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

/// FCL 的 visibilityType → 内部可见性
static A2ControlVisibility FCLVisibility(NSString *v) {
    if ([v isEqualToString:@"IN_GAME"]) return A2ControlVisibilityInGame;
    if ([v isEqualToString:@"MENU"]) return A2ControlVisibilityInMenu;
    return A2ControlVisibilityAlways;
}

static NSString *FCLVisibilityName(A2ControlVisibility v) {
    switch (v) {
        case A2ControlVisibilityInGame: return @"IN_GAME";
        case A2ControlVisibilityInMenu: return @"MENU";
        default: return @"ALWAYS";
    }
}

@implementation A2ControlFormatFCL

+ (BOOL)sniff:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    if ([json[@"viewGroups"] isKindOfClass:NSArray.class]) return YES;
    return json[@"controllerVersion"] != nil;
}

#pragma mark - 导入

/// FCL 的一个事件对象 → 内部事件数组（有损：四种触发时机被压平）
+ (void)appendEventsFromFCL:(NSDictionary *)event
                    buttonText:(NSString *)text
                        into:(NSMutableArray<A2ControlEvent *> *)out {
    if (![event isKindOfClass:NSDictionary.class]) return;

    NSArray *keycodes = FCLArray(event[@"outputKeycodes"]);
    for (id kc in keycodes) {
        NSInteger fclCode = (NSInteger)FCLNum(kc, -1);
        NSInteger glfw = [A2KeyCodeMap glfwCodeForFCLCode:fclCode];
        if (glfw < 0) {
            // FCL 有、GLFW 没有的键（KEY_KPCOMMA 之类）—— 跳过并留个痕迹
            [A2Logger warning:@"A2ControlFormatFCL"
                      message:[NSString stringWithFormat:
                               @"跳过无法映射的键码 %ld（按钮「%@」）",
                               (long)fclCode, text ?: @""]];
            continue;
        }
        if (fclCode >= 1000) {
            // 鼠标 / 滚轮
            if (fclCode == A2FCLScrollUp || fclCode == A2FCLScrollDown) {
                [out addObject:[A2ControlEvent eventFromJSON:@{
                    @"type": @"launcher_event",
                    @"key": fclCode == A2FCLScrollUp
                        ? @"launcher.event.scroll_up.single"
                        : @"launcher.event.scroll_down.single",
                }]];
            } else {
                [out addObject:[A2ControlEvent eventFromJSON:@{
                    @"type": @"key",
                    @"key": [NSString stringWithFormat:@"%ld", (long)glfw],
                }]];
            }
        } else {
            [out addObject:[A2ControlEvent keyEventWithCode:
                        [NSString stringWithFormat:@"%ld", (long)glfw]]];
        }
    }

    // ---- 语义开关 → 启动器事件 ----
    // 映射策略与官方 CcEvents.fclEventToZlEvents 保持一致（含它的降级取舍）
    if (FCLBool(event[@"input"], NO) || FCLBool(event[@"quickInput"], NO)) {
        [out addObject:[A2ControlEvent launcherEvent:@"launcher.event.switch_ime"]];
    }
    if (FCLBool(event[@"openMenu"], NO) || FCLBool(event[@"switchTouchMode"], NO)) {
        [out addObject:[A2ControlEvent launcherEvent:@"launcher.event.switch_menu"]];
    }
    if (FCLBool(event[@"switchMouseMode"], NO)) {
        [out addObject:[A2ControlEvent launcherEvent:@"launcher.event.switch_mouse"]];
    }
    NSString *outputText = FCLStr(event[@"outputText"]);
    if (outputText.length) {
        A2ControlEvent *e = [A2ControlEvent new];
        e.type = A2ControlEventTypeSendText;
        e.key = outputText;
        [out addObject:e];
    }
    for (id gid in FCLArray(event[@"bindViewGroup"])) {
        NSString *groupId = FCLStr(gid);
        if (groupId.length == 0) continue;
        A2ControlEvent *e = [A2ControlEvent new];
        e.type = A2ControlEventTypeSwitchLayer;
        e.key = groupId;
        [out addObject:e];
    }
}

/// FCL 按钮 → 内部控件
+ (A2ControlWidget *)widgetFromFCLButton:(NSDictionary *)button
                                  layer:(A2ControlLayer *)layer
                                 aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    A2ControlWidget *w = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeButton];
    w.identifier = FCLStr(button[@"id"]) ?: [[NSUUID UUID] UUIDString];
    w.text = FCLStr(button[@"text"]) ?: @"";
    w.buttonStyle = FCLStr(button[@"style"]);
    w.layerID = layer.identifier;
    w.rawJSON = button;

    NSDictionary *base = FCLDict(button[@"baseInfo"]);
    w.visibility = FCLVisibility(FCLStr(base[@"visibilityType"]));
    w.widthReference = @"screen_width";
    w.heightReference = @"screen_width";

    CGFloat widthPercent = 0;
    CGFloat heightPercent = 0;
    CGFloat widthDp = 0;
    CGFloat heightDp = 0;
    NSString *sizeType = FCLStr(base[@"sizeType"]) ?: @"PERCENTAGE";

    if ([sizeType isEqualToString:@"ABSOLUTE"]) {
        widthDp = MAX(5.0, FCLNum(base[@"absoluteWidth"], 50));
        heightDp = MAX(5.0, FCLNum(base[@"absoluteHeight"], 50));
        heightPercent = heightDp / A2FCLReferenceScreenHeightDp * 100.0;
        widthPercent = widthDp / (A2FCLReferenceScreenHeightDp * aspect) * 100.0;
        w.sizeType = @"dp";
    } else {
        NSDictionary *pw = FCLDict(base[@"percentageWidth"]);
        NSDictionary *ph = FCLDict(base[@"percentageHeight"]);
        CGFloat rawW = FCLNum(pw[@"size"], 50) / 10.0;   // 0~1000 → 0~100
        CGFloat rawH = FCLNum(ph[@"size"], 50) / 10.0;
        BOOL wRefH = [FCLStr(pw[@"reference"]) isEqualToString:@"SCREEN_HEIGHT"];
        BOOL hRefH = [FCLStr(ph[@"reference"]) isEqualToString:@"SCREEN_HEIGHT"];
        widthPercent = A2ControlSizeToScreenPercent(rawW, wRefH, YES, aspect);
        heightPercent = A2ControlSizeToScreenPercent(rawH, hRefH, NO, aspect);
        widthDp = FCLNum(base[@"absoluteWidth"], 50);
        heightDp = FCLNum(base[@"absoluteHeight"], 50);
        w.sizeType = @"percentage";
        w.widthReference = wRefH ? @"screen_height" : @"screen_width";
        w.heightReference = hRefH ? @"screen_height" : @"screen_width";
    }
    w.widthPercent = widthPercent;
    w.heightPercent = heightPercent;
    w.widthDp = widthDp;
    w.heightDp = heightDp;

    CGFloat xAnchor = FCLNum(base[@"xPosition"], 0) / 1000.0;
    CGFloat yAnchor = FCLNum(base[@"yPosition"], 0) / 1000.0;
    w.xPercent = A2ControlAnchorToPercent(xAnchor, widthPercent);
    w.yPercent = A2ControlAnchorToPercent(yAnchor, heightPercent);

    // ---- 事件 ----
    NSDictionary *eventRoot = FCLDict(button[@"event"]);
    NSMutableArray<A2ControlEvent *> *events = [NSMutableArray array];
    NSArray<NSString *> *eventNames = @[@"pressEvent", @"clickEvent",
                                        @"longPressEvent", @"doubleClickEvent"];
    BOOL pressHasPayload = NO;
    for (NSString *name in eventNames) {
        NSDictionary *ev = FCLDict(eventRoot[name]);
        NSUInteger before = events.count;
        [self appendEventsFromFCL:ev buttonText:w.text into:events];
        if ([name isEqualToString:@"pressEvent"] && events.count > before) pressHasPayload = YES;
    }
    w.clickEvents = events;

    w.isSwipple = FCLBool(eventRoot[@"swipable"], NO);
    w.isPenetrable = NO;
    // FCL 的 autoKeep 只在「单个按下事件 + 有键码」时等价于 Air2 的开关式按钮
    NSDictionary *press = FCLDict(eventRoot[@"pressEvent"]);
    w.isToggleable = FCLBool(press[@"autoKeep"], NO) && pressHasPayload;

    // FCL 有、Air2 没有等价语义的两个标记：保留在 rawJSON 里（导出时原样带回）
    return w;
}

/// FCL 方向控件 → 内部摇杆
+ (A2ControlWidget *)widgetFromFCLDirection:(NSDictionary *)direction
                                     layer:(A2ControlLayer *)layer
                                    aspect:(CGFloat)aspect
                             directionStyle:(NSDictionary *)directionStyle {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    A2ControlWidget *w = [A2ControlWidget newWidgetOfType:A2ControlWidgetTypeJoystick];
    w.identifier = FCLStr(direction[@"id"]) ?: [[NSUUID UUID] UUIDString];
    w.text = @"";
    w.buttonStyle = FCLStr(direction[@"style"]);
    w.layerID = layer.identifier;
    w.rawJSON = direction;

    NSDictionary *base = FCLDict(direction[@"baseInfo"]);
    w.visibility = FCLVisibility(FCLStr(base[@"visibilityType"]));

    // 方向控件是方形：以 FCL 的 percentageWidth 为准
    CGFloat heightPercent = 0;
    CGFloat widthPercent = 0;
    CGFloat widthDp = 50;
    NSString *sizeType = FCLStr(base[@"sizeType"]) ?: @"PERCENTAGE";
    if ([sizeType isEqualToString:@"ABSOLUTE"]) {
        widthDp = MAX(5.0, FCLNum(base[@"absoluteWidth"], 50));
        heightPercent = widthDp / A2FCLReferenceScreenHeightDp * 100.0;
        widthPercent = widthDp / (A2FCLReferenceScreenHeightDp * aspect) * 100.0;
        w.sizeType = @"dp";
        w.widthReference = @"screen_height";
        w.heightReference = @"screen_height";
    } else {
        NSDictionary *pw = FCLDict(base[@"percentageWidth"]);
        CGFloat raw = FCLNum(pw[@"size"], 300) / 10.0;
        BOOL refH = [FCLStr(pw[@"reference"]) isEqualToString:@"SCREEN_HEIGHT"];
        // FCL 的方向控件尺寸按「参考边」算，缺省按 CcDirection 的假设取屏幕高
        heightPercent = A2ControlSizeToScreenPercent(raw, YES, NO, aspect);
        widthPercent = A2ControlSizeToScreenPercent(raw, YES, YES, aspect);
        w.sizeType = @"percentage";
        w.widthReference = refH ? @"screen_height" : @"screen_width";
        w.heightReference = w.widthReference;
        widthDp = 200;
    }
    w.widthPercent = widthPercent;
    w.heightPercent = heightPercent;
    w.widthDp = widthDp;
    w.heightDp = widthDp;

    CGFloat xAnchor = FCLNum(base[@"xPosition"], 0) / 1000.0;
    CGFloat yAnchor = FCLNum(base[@"yPosition"], 0) / 1000.0;
    w.xPercent = A2ControlAnchorToPercent(xAnchor, widthPercent);
    w.yPercent = A2ControlAnchorToPercent(yAnchor, heightPercent);

    // ---- 方向键 ----
    NSDictionary *event = FCLDict(direction[@"event"]);
    NSMutableArray<A2ControlEvent *> *up = [NSMutableArray array];
    NSMutableArray<A2ControlEvent *> *down = [NSMutableArray array];
    NSMutableArray<A2ControlEvent *> *left = [NSMutableArray array];
    NSMutableArray<A2ControlEvent *> *right = [NSMutableArray array];

    void (^collect)(NSString *, NSMutableArray *) = ^(NSString *key, NSMutableArray *dst) {
        for (id kc in FCLArray(event[key])) {
            NSInteger fclCode = (NSInteger)FCLNum(kc, -1);
            NSInteger glfw = [A2KeyCodeMap glfwCodeForFCLCode:fclCode];
            if (glfw < 0) continue;
            [dst addObject:[A2ControlEvent keyEventWithCode:
                        [NSString stringWithFormat:@"%ld", (long)glfw]]];
        }
    };
    collect(@"upKeycode", up);
    collect(@"downKeycode", down);
    collect(@"leftKeycode", left);
    collect(@"rightKeycode", right);

    // 缺省 WASD（与 ZL2 一致）
    if (up.count == 0)    [up addObject:[A2ControlEvent keyEventWithCode:@"87"]];
    if (down.count == 0)  [down addObject:[A2ControlEvent keyEventWithCode:@"83"]];
    if (left.count == 0)  [left addObject:[A2ControlEvent keyEventWithCode:@"65"]];
    if (right.count == 0) [right addObject:[A2ControlEvent keyEventWithCode:@"68"]];

    NSMutableDictionary *dirs = [NSMutableDictionary dictionary];
    dirs[@"north"] = up;
    dirs[@"south"] = down;
    dirs[@"west"] = left;
    dirs[@"east"] = right;
    dirs[@"north_east"] = [up arrayByAddingObjectsFromArray:right];
    dirs[@"north_west"] = [up arrayByAddingObjectsFromArray:left];
    dirs[@"south_east"] = [down arrayByAddingObjectsFromArray:right];
    dirs[@"south_west"] = [down arrayByAddingObjectsFromArray:left];
    w.directionEvents = dirs;

    // FCL 的 deadZone 是百分比 ×100 存储（0~90），内部用 0~1
    w.deadZone = MAX(0.0, MIN(0.9, FCLNum(event[@"deadZone"], 50) / 100.0));
    w.lockThreshold = MAX(0.0, MIN(1.0, FCLNum(event[@"lockThreshold"], 30) / 100.0));
    w.canLock = FCLBool(event[@"canLock"], NO);
    w.lockEvents = @[];

    NSString *styleType = FCLStr(directionStyle[@"styleType"]);
    w.styleType = styleType;
    w.triggerMode = [styleType isEqualToString:@"ROCKER"]
        ? A2JoystickTriggerModeRocker : A2JoystickTriggerModeDirection;
    return w;
}

+ (A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error {
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"A2ControlFormatFCL" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"不是 JSON 对象"}];
        return nil;
    }

    A2ControlLayout *layout = [A2ControlLayout emptyLayout];
    layout.sourceFormat = @"fcl";
    layout.version = (NSInteger)FCLNum(json[@"controllerVersion"], A2FCLControllerVersion);
    layout.aspectRatio = 16.0 / 9.0;
    layout.rawRoot = json;
    layout.name = FCLStr(json[@"name"]) ?: @"FCL 布局";
    layout.author = FCLStr(json[@"author"]);
    [layout.layers removeAllObjects];

    // ---- 样式：按名字索引，方向控件要用 styleType 判断 ROCKER ----
    NSMutableDictionary<NSString *, NSDictionary *> *directionStyles = [NSMutableDictionary dictionary];
    for (NSDictionary *s in FCLArray(json[@"directionStyles"])) {
        if (![s isKindOfClass:NSDictionary.class]) continue;
        NSString *name = FCLStr(s[@"name"]);
        if (name.length) directionStyles[name] = s;
    }
    for (NSDictionary *s in FCLArray(json[@"buttonStyles"])) {
        if (![s isKindOfClass:NSDictionary.class]) continue;
        NSString *name = FCLStr(s[@"name"]);
        if (name.length) layout.buttonStyles[name] = s;
    }

    for (NSUInteger i = 0; i < FCLArray(json[@"viewGroups"]).count; i++) {
        NSDictionary *gj = FCLArray(json[@"viewGroups"])[i];
        if (![gj isKindOfClass:NSDictionary.class]) continue;

        A2ControlLayer *layer = [A2ControlLayer new];
        layer.identifier = FCLStr(gj[@"id"]) ?: [NSString stringWithFormat:@"group%lu", (unsigned long)i];
        layer.name = FCLStr(gj[@"name"]) ?: layer.identifier;
        layer.visibleByDefault = ![FCLStr(gj[@"visibility"]) isEqualToString:@"INVISIBLE"];
        layer.rawJSON = gj;

        NSDictionary *viewData = FCLDict(gj[@"viewData"]);
        for (NSDictionary *bj in FCLArray(viewData[@"buttonList"])) {
            if (![bj isKindOfClass:NSDictionary.class]) continue;
            A2ControlWidget *w = [self widgetFromFCLButton:bj layer:layer aspect:layout.aspectRatio];
            if (w) [layer.widgets addObject:w];
        }
        for (NSDictionary *dj in FCLArray(viewData[@"directionList"])) {
            if (![dj isKindOfClass:NSDictionary.class]) continue;
            NSString *styleName = FCLStr(dj[@"style"]);
            NSDictionary *style = styleName.length ? directionStyles[styleName] : nil;
            A2ControlWidget *w = [self widgetFromFCLDirection:dj
                                                       layer:layer
                                                      aspect:layout.aspectRatio
                                              directionStyle:style];
            if (w) [layer.widgets addObject:w];
        }

        [layout.layers addObject:layer];
    }

    [A2Logger info:@"A2ControlFormatFCL"
           message:[NSString stringWithFormat:@"导入 FCL 布局「%@」：v%ld，%lu 组 %lu 控件",
                    layout.name, (long)layout.version,
                    (unsigned long)layout.layers.count,
                    (unsigned long)layout.allWidgets.count]];
    return layout;
}

#pragma mark - 导出

/// 内部事件 → FCL 的 outputKeycodes / 语义开关。
/// 返回是否「一次点击就发一次」（滚轮类需要 autoClick）
+ (BOOL)applyInternalEvents:(NSArray<A2ControlEvent *> *)events
                  toFCLDict:(NSMutableDictionary *)eventDict {
    NSMutableArray<NSNumber *> *keycodes = [NSMutableArray array];
    BOOL hasScroll = NO;

    for (A2ControlEvent *e in events) {
        switch (e.type) {
            case A2ControlEventTypeKey:
            case A2ControlEventTypeMouseButton: {
                NSInteger fclCode = [A2KeyCodeMap fclCodeForEventKey:e.key];
                if (fclCode >= 0) [keycodes addObject:@(fclCode)];
                break;
            }
            case A2ControlEventTypeScroll: {
                NSInteger dir = [A2ControlEventKey scrollDirectionForRawKey:e.key];
                if (dir == 0) dir = e.key.integerValue >= 0 ? 1 : -1;
                [keycodes addObject:@(dir > 0 ? A2FCLScrollUp : A2FCLScrollDown)];
                hasScroll = YES;
                break;
            }
            case A2ControlEventTypeLauncherEvent: {
                if ([e.key hasPrefix:@"launcher.event.scroll_"]) {
                    NSInteger dir = [A2ControlEventKey scrollDirectionForRawKey:e.key];
                    [keycodes addObject:@(dir > 0 ? A2FCLScrollUp : A2FCLScrollDown)];
                    hasScroll = YES;
                } else if ([e.key isEqualToString:@"launcher.event.switch_ime"]) {
                    eventDict[@"input"] = @YES;
                } else if ([e.key isEqualToString:@"launcher.event.switch_mouse"]) {
                    eventDict[@"switchMouseMode"] = @YES;
                } else {
                    // switch_menu 及其它启动器事件都降级为 openMenu
                    // （与官方 CcEvents 的处理一致；FCL 没有更细的等价语义）
                    eventDict[@"openMenu"] = @YES;
                }
                break;
            }
            case A2ControlEventTypeSendText:
                eventDict[@"outputText"] = e.key ?: @"";
                break;
            case A2ControlEventTypeSwitchLayer:
            case A2ControlEventTypeShowLayer:
            case A2ControlEventTypeHideLayer: {
                NSMutableArray *binds = [eventDict[@"bindViewGroup"] mutableCopy]
                    ?: [NSMutableArray array];
                if (e.key.length) [binds addObject:e.key];
                eventDict[@"bindViewGroup"] = binds;
                break;
            }
            default:
                break;
        }
    }

    eventDict[@"outputKeycodes"] = keycodes;
    return hasScroll;
}

+ (NSDictionary *)emptyFCLEvent {
    return [@{
        @"autoKeep": @NO,
        @"autoClick": @NO,
        @"openMenu": @NO,
        @"switchTouchMode": @NO,
        @"switchMouseMode": @NO,
        @"input": @NO,
        @"quickInput": @NO,
        @"outputText": @"",
        @"outputKeycodes": @[],
        @"bindViewGroup": @[],
    } mutableCopy];
}

/// 内部 baseInfo（屏幕百分比）→ FCL baseInfo（0~1000 可用空间 + 参考边）
+ (NSDictionary *)fclBaseInfoFromWidget:(A2ControlWidget *)w
                                isSquare:(BOOL)isSquare
                                  aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    NSMutableDictionary *base = [NSMutableDictionary dictionary];
    base[@"visibilityType"] = FCLVisibilityName(w.visibility);
    base[@"xPosition"] = @((NSInteger)llround(
        MAX(0.0, MIN(1.0, A2ControlPercentToAnchor(w.xPercent, w.widthPercent))) * 1000.0));
    base[@"yPosition"] = @((NSInteger)llround(
        MAX(0.0, MIN(1.0, A2ControlPercentToAnchor(w.yPercent, w.heightPercent))) * 1000.0));

    BOOL isDp = [w.sizeType isEqualToString:@"dp"];
    if (isDp) {
        base[@"sizeType"] = @"ABSOLUTE";
        base[@"absoluteWidth"] = @((NSInteger)llround(w.widthDp > 0 ? w.widthDp : 50));
        base[@"absoluteHeight"] = @((NSInteger)llround(w.heightDp > 0 ? w.heightDp : 50));
    } else {
        base[@"sizeType"] = @"PERCENTAGE";
        base[@"absoluteWidth"] = @((NSInteger)llround(w.widthDp > 0 ? w.widthDp : 50));
        base[@"absoluteHeight"] = @((NSInteger)llround(w.heightDp > 0 ? w.heightDp : 50));
    }

    // 百分比：内部是屏幕百分比，FCL 是「参考边百分比 ×10」
    BOOL wRefH = [w.widthReference isEqualToString:@"screen_height"];
    BOOL hRefH = [w.heightReference isEqualToString:@"screen_height"];
    CGFloat rawW = A2ControlScreenPercentToSize(w.widthPercent, wRefH, YES, aspect);
    CGFloat rawH = A2ControlScreenPercentToSize(w.heightPercent, hRefH, NO, aspect);

    if (isSquare) {
        // 方向控件只读 percentageWidth，统一用屏幕高作参考边
        rawW = w.heightPercent;
        wRefH = YES;
    }

    base[@"percentageWidth"] = @{
        @"reference": wRefH ? @"SCREEN_HEIGHT" : @"SCREEN_WIDTH",
        @"size": @((NSInteger)llround(MAX(10.0, MIN(1000.0, rawW * 10.0)))),
    };
    base[@"percentageHeight"] = @{
        @"reference": hRefH ? @"SCREEN_HEIGHT" : @"SCREEN_WIDTH",
        @"size": @((NSInteger)llround(MAX(10.0, MIN(1000.0, rawH * 10.0)))),
    };
    return base;
}

+ (NSDictionary *)fclButtonJSONFromWidget:(A2ControlWidget *)w
                                includeEvents:(BOOL)includeEvents
                                       aspect:(CGFloat)aspect {
    NSMutableDictionary *event = [[self emptyFCLEvent] mutableCopy];
    BOOL hasScroll = includeEvents
        ? [self applyInternalEvents:w.clickEvents ?: @[] toFCLDict:event]
        : NO;
    if (hasScroll) event[@"autoClick"] = @YES;
    if (w.isToggleable) event[@"autoKeep"] = @YES;

    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"pointerFollow"] = @NO;
    root[@"Movable"] = @NO;
    root[@"swipable"] = @(w.isSwipple);
    root[@"pressEvent"] = event;
    root[@"longPressEvent"] = [self emptyFCLEvent];
    root[@"clickEvent"] = [self emptyFCLEvent];
    root[@"doubleClickEvent"] = [self emptyFCLEvent];

    NSMutableDictionary *button = [NSMutableDictionary dictionary];
    button[@"id"] = w.identifier ?: [[NSUUID UUID] UUIDString];
    button[@"text"] = w.text ?: @"";
    button[@"style"] = w.buttonStyle.length ? w.buttonStyle : @"Air2 Default";
    button[@"baseInfo"] = [self fclBaseInfoFromWidget:w isSquare:NO aspect:aspect];
    button[@"event"] = root;
    return button;
}

+ (NSDictionary *)fclDirectionJSONFromWidget:(A2ControlWidget *)w
                                    styleName:(NSString *)styleName
                                       aspect:(CGFloat)aspect {
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"upKeycode"] = [self fclCodesFromEvents:w.directionEvents[@"north"]];
    event[@"downKeycode"] = [self fclCodesFromEvents:w.directionEvents[@"south"]];
    event[@"leftKeycode"] = [self fclCodesFromEvents:w.directionEvents[@"west"]];
    event[@"rightKeycode"] = [self fclCodesFromEvents:w.directionEvents[@"east"]];
    event[@"followOption"] = @"CENTER_FOLLOW";
    event[@"sneak"] = @NO;
    event[@"sneakKeycode"] = @0;
    // 内部 0~1 → FCL 百分比 ×100（0~90 / 0~100）
    event[@"deadZone"] = @((NSInteger)llround(MAX(0.0, MIN(0.9, w.deadZone)) * 100.0));
    event[@"canLock"] = @(w.canLock);
    event[@"lockThreshold"] = @((NSInteger)llround(MAX(0.0, MIN(1.0, w.lockThreshold)) * 100.0));

    NSMutableDictionary *direction = [NSMutableDictionary dictionary];
    direction[@"id"] = w.identifier ?: [[NSUUID UUID] UUIDString];
    direction[@"style"] = styleName ?: @"Air2 Direction";
    direction[@"baseInfo"] = [self fclBaseInfoFromWidget:w isSquare:YES aspect:aspect];
    direction[@"event"] = event;
    return direction;
}

+ (NSArray<NSNumber *> *)fclCodesFromEvents:(NSArray<A2ControlEvent *> *)events {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (A2ControlEvent *e in events) {
        NSInteger code = [A2KeyCodeMap fclCodeForEventKey:e.key];
        if (code >= 0) [out addObject:@(code)];
    }
    return out;
}

/// FCL 默认按钮样式（cc 的 defaultFclStyle，颜色是 ARGB 有符号 int）
+ (NSDictionary *)defaultButtonStyle {
    return @{
        @"name": @"Air2 Default",
        @"textColor": @(-1),
        @"textSize": @14,
        @"strokeColor": @(-1),
        @"strokeWidth": @0,
        @"cornerRadius": @100,
        @"fillColor": @(-2147483648),
        @"textColorPressed": @(-1),
        @"textSizePressed": @14,
        @"strokeColorPressed": @(-1),
        @"strokeWidthPressed": @0,
        @"cornerRadiusPressed": @100,
        @"fillColorPressed": @(-1282897784),
    };
}

+ (NSDictionary *)defaultDirectionStyleNamed:(NSString *)name rocker:(BOOL)rocker {
    NSDictionary *buttonStyle = @{
        @"interval": @50,
        @"textColor": @(-1),
        @"textSize": @12,
        @"strokeColor": @(-12303292),
        @"strokeWidth": @10,
        @"cornerRadius": @100,
        @"fillColor": @0,
        @"textColorPressed": @(-1),
        @"textSizePressed": @12,
        @"strokeColorPressed": @(-12303292),
        @"strokeWidthPressed": @10,
        @"cornerRadiusPressed": @100,
        @"fillColorPressed": @(-3355444),
    };
    NSDictionary *rockerStyle = @{
        @"rockerSize": @400,
        @"bgCornerRadius": @500,
        @"bgStrokeWidth": @20,
        @"bgStrokeColor": @(-12303292),
        @"bgFillColor": @0,
        @"rockerCornerRadius": @500,
        @"rockerStrokeWidth": @10,
        @"rockerStrokeColor": @(-12303292),
        @"rockerFillColor": @(-7829368),
    };
    return @{
        @"name": name,
        @"styleType": rocker ? @"ROCKER" : @"BUTTON",
        @"buttonStyle": buttonStyle,
        @"rockerStyle": rockerStyle,
    };
}

+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = layout.aspectRatio > 0.05 ? layout.aspectRatio : 16.0 / 9.0;

    NSMutableArray *groups = [NSMutableArray array];

    for (A2ControlLayer *layer in layout.layers) {
        NSMutableArray *buttons = [NSMutableArray array];
        NSMutableArray *directions = [NSMutableArray array];

        for (A2ControlWidget *w in layer.widgets) {
            switch (w.type) {
                case A2ControlWidgetTypeButton:
                case A2ControlWidgetTypeTextBox:
                    [buttons addObject:[self fclButtonJSONFromWidget:w
                                                      includeEvents:YES
                                                             aspect:aspect]];
                    break;

                case A2ControlWidgetTypeJoystick: {
                    BOOL rocker = (w.triggerMode == A2JoystickTriggerModeRocker);
                    NSString *styleName = rocker ? @"Air2 Rocker" : @"Air2 Direction";
                    [directions addObject:[self fclDirectionJSONFromWidget:w
                                                                styleName:styleName
                                                                   aspect:aspect]];
                    break;
                }

                // Air2 扩展类型在 FCL 里没有对应控件：
                // 用「装饰按钮」占位（无事件），文字保留，至少位置与观感不丢。
                // 真值保存在 rawJSON → 由 A2ControlFormat 的扩展键继续携带。
                case A2ControlWidgetTypeGamepad:
                case A2ControlWidgetTypeGyroscope:
                case A2ControlWidgetTypeHotbar: {
                    // 装饰性占位：不带事件，避免 FCL 里出现一个「点了会乱发键」的按钮
                    [buttons addObject:[self fclButtonJSONFromWidget:w
                                                      includeEvents:NO
                                                             aspect:aspect]];
                    break;
                }
            }
        }

        NSMutableDictionary *group = [NSMutableDictionary dictionary];
        group[@"id"] = layer.identifier ?: [[NSUUID UUID] UUIDString];
        group[@"name"] = layer.name ?: layer.identifier ?: @"Layer";
        group[@"visibility"] = layer.visibleByDefault ? @"VISIBLE" : @"INVISIBLE";
        group[@"viewData"] = @{
            @"buttonList": buttons,
            @"directionList": directions,
        };
        [groups addObject:group];
    }

    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"controllerVersion"] = @(A2FCLControllerVersion);
    root[@"name"] = layout.name ?: @"Air2 布局";
    root[@"author"] = layout.author ?: @"Air2";
    root[@"buttonStyles"] = @[[self defaultButtonStyle]];
    root[@"directionStyles"] = @[
        [self defaultDirectionStyleNamed:@"Air2 Direction" rocker:NO],
        [self defaultDirectionStyleNamed:@"Air2 Rocker" rocker:YES],
    ];
    root[@"viewGroups"] = groups;
    return root;
}

@end
