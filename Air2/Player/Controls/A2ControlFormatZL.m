//
//  A2ControlFormatZL.m
//  Air2
//
//  ZL2 原生控件格式的解析与序列化。见 .h 的说明。
//

#import "A2ControlFormatZL.h"
#import "A2ControlInput.h"
#import "A2KeyCodeMap.h"
#import "A2Logger.h"

/// ZL2 里以屏幕高为参考边的摇杆尺寸百分比（0~10000）
static NSString *const kZLScreenHeightRef = @"screen_height";
static NSString *const kZLScreenWidthRef  = @"screen_width";

/// 误写容差：ZL2 的布尔字段有 true / "true" / 1 三种写法
static BOOL ZLBool(id v, BOOL fallback) {
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    if ([v isKindOfClass:NSString.class]) return [v boolValue];
    return fallback;
}

static double ZLNum(id v, double fallback) {
    if ([v isKindOfClass:NSNumber.class]) return [v doubleValue];
    if ([v isKindOfClass:NSString.class]) return [v doubleValue];
    return fallback;
}

static NSString *ZLStr(id v) {
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}

@implementation A2ControlFormatZL

+ (NSArray<NSString *> *)extensionKeys {
    return @[@"gamepadButtons", @"gyroscopeButtons", @"hotbarButtons"];
}

#pragma mark - 导入：几何

/// 把一条 ZL2 原生控件 JSON 换算成内部通用 JSON（position/buttonSize 用屏幕百分比）。
/// 其余字段原样保留，交给 A2ControlWidget 的通用解析。
+ (NSMutableDictionary *)genericFromZLJSON:(NSDictionary *)json
                                      type:(A2ControlWidgetType)type
                                    aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    NSMutableDictionary *g = [json mutableCopy] ?: [NSMutableDictionary dictionary];

    CGFloat widthPercent = 0;
    CGFloat heightPercent = 0;
    NSString *sizeType = nil;
    CGFloat widthDp = 0;
    CGFloat heightDp = 0;

    if (type == A2ControlWidgetTypeJoystick) {
        // 摇杆：sizeType / sizeDp / sizePercentage（相对屏幕高）
        sizeType = ZLStr(json[@"sizeType"]) ?: @"percentage";
        BOOL isDp = [sizeType isEqualToString:@"dp"] ||
                    [sizeType isEqualToString:@"dip"] ||
                    [sizeType isEqualToString:@"absolute"];
        if (isDp) {
            // 与 CcConstants 一致的 411dp 基准高（16:9 时宽 730.7dp）
            widthDp = MAX(5.0, ZLNum(json[@"sizeDp"], 50));
            heightDp = widthDp;
            heightPercent = heightDp / 411.0 * 100.0;
            widthPercent = widthDp / (411.0 * aspect) * 100.0;
        } else {
            CGFloat sp = ZLNum(json[@"sizePercentage"], 0);
            if (sp <= 0) sp = 2500;                 // 默认 25%
            heightPercent = sp / 100.0;
            widthPercent = heightPercent / aspect;  // 方形控件，换到宽度基准
        }
    } else {
        NSDictionary *size = [json[@"buttonSize"] isKindOfClass:NSDictionary.class]
            ? json[@"buttonSize"]
            : ([json[@"size"] isKindOfClass:NSDictionary.class] ? json[@"size"] : @{});
        sizeType = ZLStr(size[@"type"]) ?: @"percentage";
        widthDp = MAX(5.0, ZLNum(size[@"widthDp"], 50));
        heightDp = MAX(5.0, ZLNum(size[@"heightDp"], 50));

        if ([sizeType isEqualToString:@"dp"]) {
            heightPercent = heightDp / 411.0 * 100.0;
            widthPercent = widthDp / (411.0 * aspect) * 100.0;
        } else if ([sizeType isEqualToString:@"wrap_content"]) {
            // ZL2 的 wrap_content 没有精确等价 —— 按文字长度估一个 dp（对齐
            // CcUtils.estimateWrapContentDp 的思路，但不追求逐像素一致）
            // ZL2 的 text 可能是 TranslatableString，这里只按 default 估宽度
            NSString *text = ZLStr(json[@"text"]);
            if (text.length == 0 && [json[@"text"] isKindOfClass:NSDictionary.class]) {
                text = ZLStr(((NSDictionary *)json[@"text"])[@"default"]);
            }
            if (text.length == 0) text = @"";
            CGFloat perChar = 9.0;
            CGFloat wdp = MAX(40.0, text.length * perChar + 16.0);
            CGFloat hdp = 40.0;
            widthDp = wdp;
            heightDp = hdp;
            heightPercent = heightDp / 411.0 * 100.0;
            widthPercent = widthDp / (411.0 * aspect) * 100.0;
        } else {
            CGFloat rawW = ZLNum(size[@"widthPercentage"], 500) / 100.0;
            CGFloat rawH = ZLNum(size[@"heightPercentage"], 500) / 100.0;
            BOOL wRefH = [ZLStr(size[@"widthReference"]) isEqualToString:kZLScreenHeightRef];
            BOOL hRefH = [ZLStr(size[@"heightReference"]) isEqualToString:kZLScreenHeightRef];
            widthPercent = A2ControlSizeToScreenPercent(rawW, wRefH, YES, aspect);
            heightPercent = A2ControlSizeToScreenPercent(rawH, hRefH, NO, aspect);
        }
    }

    // ---- 位置：可用空间比例 → 屏幕百分比 ----
    NSDictionary *pos = [json[@"position"] isKindOfClass:NSDictionary.class]
        ? json[@"position"] : @{};
    CGFloat xAnchor = ZLNum(pos[@"x"], 0) / 10000.0;
    CGFloat yAnchor = ZLNum(pos[@"y"], 0) / 10000.0;

    g[@"position"] = @{
        @"x": @(A2ControlAnchorToPercent(xAnchor, widthPercent)),
        @"y": @(A2ControlAnchorToPercent(yAnchor, heightPercent)),
    };
    g[@"buttonSize"] = @{
        @"width": @(widthPercent),
        @"height": @(heightPercent),
        @"type": sizeType ?: @"percentage",
        @"widthDp": @(widthDp),
        @"heightDp": @(heightDp),
        @"widthReference": ZLStr(json[@"widthReference"]) ?: (type == A2ControlWidgetTypeJoystick
                              ? kZLScreenHeightRef : kZLScreenWidthRef),
    };

    // 参考边对摇杆固定是屏幕高；按钮沿用原值
    if (type != A2ControlWidgetTypeJoystick) {
        NSDictionary *size = [json[@"buttonSize"] isKindOfClass:NSDictionary.class]
            ? json[@"buttonSize"]
            : ([json[@"size"] isKindOfClass:NSDictionary.class] ? json[@"size"] : @{});
        g[@"widthReference"] = ZLStr(size[@"widthReference"]) ?: kZLScreenWidthRef;
        g[@"heightReference"] = ZLStr(size[@"heightReference"]) ?: kZLScreenWidthRef;
    } else {
        g[@"widthReference"] = kZLScreenHeightRef;
        g[@"heightReference"] = kZLScreenHeightRef;
    }
    g[@"widthDp"] = @(widthDp);
    g[@"heightDp"] = @(heightDp);

    // 摇杆的 deadZone/阈值在 ZL 里已是 0~1，直接沿用
    return g;
}

#pragma mark - 导入：主流程

+ (A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error {
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"A2ControlFormatZL" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"不是 JSON 对象"}];
        return nil;
    }

    A2ControlLayout *layout = [A2ControlLayout emptyLayout];
    layout.sourceFormat = @"zl2";
    layout.version = (NSInteger)ZLNum(json[@"editorVersion"], 12);
    layout.aspectRatio = 16.0 / 9.0;
    layout.rawRoot = json;
    [layout.layers removeAllObjects];

    NSDictionary *info = [json[@"info"] isKindOfClass:NSDictionary.class] ? json[@"info"] : @{};
    layout.name = ZLStr(info[@"name"]) ?: ZLStr(json[@"name"]) ?: @"ZL2 布局";
    layout.author = ZLStr(info[@"author"]) ?: ZLStr(json[@"author"]);

    NSArray *layers = [json[@"layers"] isKindOfClass:NSArray.class] ? json[@"layers"] : @[];
    for (NSUInteger i = 0; i < layers.count; i++) {
        NSDictionary *lj = layers[i];
        if (![lj isKindOfClass:NSDictionary.class]) continue;

        A2ControlLayer *layer = [A2ControlLayer new];
        layer.identifier = ZLStr(lj[@"uuid"]) ?: ZLStr(lj[@"id"])
            ?: [NSString stringWithFormat:@"layer%lu", (unsigned long)i];
        layer.name = ZLStr(lj[@"name"]) ?: layer.identifier;
        layer.visibleByDefault = !ZLBool(lj[@"hide"], NO);
        // ZL2 的层可见性开关（CcFclToZl.normalizeZlLayout 的默认值）
        layer.hideWhenMouse = ZLBool(lj[@"hideWhenMouse"], YES);
        layer.hideWhenGamepad = ZLBool(lj[@"hideWhenGamepad"], YES);
        layer.hideWhenJoystick = ZLBool(lj[@"hideWhenJoystick"], NO);
        layer.rawJSON = lj;

        // 六组控件：前三种是 ZL2 原生，后三种是 Air2 扩展键
        NSArray<NSArray *> *buckets = @[
            [self arrayOrEmpty:lj[@"normalButtons"]],
            [self arrayOrEmpty:lj[@"joystickButtons"]],
            [self arrayOrEmpty:lj[@"textBoxes"]],
            [self arrayOrEmpty:lj[@"gamepadButtons"]],
            [self arrayOrEmpty:lj[@"gyroscopeButtons"]],
            [self arrayOrEmpty:lj[@"hotbarButtons"]],
            // Air2 扩展：视角区 / 滚轮（ZL2 没有这两种类型，
            // 作为未知键写回时 ZL2 会原样保留，再导回 Air2 能恢复）
            [self arrayOrEmpty:lj[@"viewAreas"]],
            [self arrayOrEmpty:lj[@"scrollButtons"]],
        ];
        A2ControlWidgetType types[8] = {
            A2ControlWidgetTypeButton,
            A2ControlWidgetTypeJoystick,
            A2ControlWidgetTypeTextBox,
            A2ControlWidgetTypeGamepad,
            A2ControlWidgetTypeGyroscope,
            A2ControlWidgetTypeHotbar,
            A2ControlWidgetTypeView,
            A2ControlWidgetTypeScroll,
        };
        for (NSUInteger b = 0; b < buckets.count; b++) {
            for (NSDictionary *wj in buckets[b]) {
                if (![wj isKindOfClass:NSDictionary.class]) continue;
                NSMutableDictionary *generic =
                    [self genericFromZLJSON:wj type:types[b] aspect:layout.aspectRatio];
                A2ControlWidget *w = [A2ControlWidget widgetFromJSON:generic
                                                                type:types[b]
                                                             layerID:layer.identifier];
                if (w) {
                    w.rawJSON = wj;   // 保留原始 JSON，写回时优先用它
                    [layer.widgets addObject:w];
                }
            }
        }

        [layout.layers addObject:layer];
    }

    // ---- 样式表 ----
    for (NSString *key in @[@"styles", @"buttonStyles"]) {
        id styles = json[key];
        if ([styles isKindOfClass:NSArray.class]) {
            for (NSDictionary *s in styles) {
                if (![s isKindOfClass:NSDictionary.class]) continue;
                NSString *sid = ZLStr(s[@"uuid"]) ?: ZLStr(s[@"id"]) ?: ZLStr(s[@"name"]);
                if (sid.length) layout.buttonStyles[sid] = s;
            }
        } else if ([styles isKindOfClass:NSDictionary.class]) {
            [layout.buttonStyles addEntriesFromDictionary:styles];
        }
    }
    if ([json[@"joystickStyles"] isKindOfClass:NSArray.class]) {
        for (NSDictionary *s in json[@"joystickStyles"]) {
            if (![s isKindOfClass:NSDictionary.class]) continue;
            NSString *sid = ZLStr(s[@"uuid"]) ?: ZLStr(s[@"name"]);
            if (sid.length) layout.joystickStyles[sid] = s;
        }
    }

    [A2Logger info:@"A2ControlFormatZL"
           message:[NSString stringWithFormat:@"导入 ZL2 布局「%@」：%lu 层 %lu 控件",
                    layout.name, (unsigned long)layout.layers.count,
                    (unsigned long)layout.allWidgets.count]];
    return layout;
}

+ (NSArray *)arrayOrEmpty:(id)v {
    return [v isKindOfClass:NSArray.class] ? v : @[];
}

#pragma mark - 导出

/// 内部事件 → ZL2 的 clickEvent
+ (NSDictionary *)zlEventFromWidgetEvent:(A2ControlEvent *)e {
    NSString *key = e.key;

    switch (e.type) {
        case A2ControlEventTypeKey: {
            NSInteger code = key.integerValue;
            NSString *name = [A2KeyCodeMap nameForGLFWCode:code];
            return @{@"type": @"key", @"key": name ?: (key ?: @"")};
        }
        case A2ControlEventTypeMouseButton: {
            NSString *name = [A2KeyCodeMap nameForGLFWCode:key.integerValue];
            return @{@"type": @"key", @"key": name ?: (key ?: @"")};
        }
        case A2ControlEventTypeScroll: {
            NSInteger dir = [A2ControlEventKey scrollDirectionForRawKey:key];
            // 内部 "scroll:1" 不是事件名，先把方向翻译回 ZL2 的事件名
            if (dir == 0) dir = key.integerValue >= 0 ? 1 : -1;
            return @{@"type": @"launcher_event",
                     @"key": dir > 0 ? @"launcher.event.scroll_up.single"
                                     : @"launcher.event.scroll_down.single"};
        }
        case A2ControlEventTypeSwitchLayer:
            return @{@"type": @"switch_layer", @"key": key ?: @""};
        case A2ControlEventTypeShowLayer:
            return @{@"type": @"show_layer", @"key": key ?: @""};
        case A2ControlEventTypeHideLayer:
            return @{@"type": @"hide_layer", @"key": key ?: @""};
        case A2ControlEventTypeSendText:
            return @{@"type": @"send_text", @"key": key ?: @""};
        case A2ControlEventTypeLauncherEvent:
        default:
            return @{@"type": @"launcher_event", @"key": key ?: @""};
    }
}

+ (NSArray<NSDictionary *> *)zlEventsFromList:(NSArray<A2ControlEvent *> *)events {
    NSMutableArray *out = [NSMutableArray array];
    for (A2ControlEvent *e in events) [out addObject:[self zlEventFromWidgetEvent:e]];
    return out;
}

/// 内部百分比 → ZL2 的「可用空间比例」万分比
+ (NSInteger)zlPositionFromPercent:(CGFloat)percent sizePercent:(CGFloat)sizePercent {
    CGFloat anchor = A2ControlPercentToAnchor(percent, sizePercent);
    NSInteger v = (NSInteger)llround(anchor * 10000.0);
    return MAX(0, MIN(10000, v));
}

+ (NSDictionary *)zlButtonJSONFromWidget:(A2ControlWidget *)w aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    NSString *widthRef = w.widthReference.length ? w.widthReference : kZLScreenWidthRef;
    NSString *heightRef = w.heightReference.length ? w.heightReference : kZLScreenWidthRef;
    BOOL wRefH = [widthRef isEqualToString:kZLScreenHeightRef];
    BOOL hRefH = [heightRef isEqualToString:kZLScreenHeightRef];

    CGFloat rawW = A2ControlScreenPercentToSize(w.widthPercent, wRefH, YES, aspect);
    CGFloat rawH = A2ControlScreenPercentToSize(w.heightPercent, hRefH, NO, aspect);

    NSString *sizeType = w.sizeType.length ? w.sizeType : @"percentage";
    if (![sizeType isEqualToString:@"dp"] && ![sizeType isEqualToString:@"wrap_content"]) {
        sizeType = @"percentage";
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"uuid"] = w.identifier ?: [[NSUUID UUID] UUIDString];
    d[@"text"] = @{@"default": w.text ?: @""};
    d[@"position"] = @{
        @"x": @([self zlPositionFromPercent:w.xPercent sizePercent:w.widthPercent]),
        @"y": @([self zlPositionFromPercent:w.yPercent sizePercent:w.heightPercent]),
    };
    d[@"buttonSize"] = @{
        @"type": sizeType,
        @"widthDp": @(w.widthDp > 0 ? w.widthDp : 50),
        @"heightDp": @(w.heightDp > 0 ? w.heightDp : 50),
        @"widthPercentage": @((NSInteger)llround(MAX(100, MIN(10000, rawW * 100.0)))),
        @"heightPercentage": @((NSInteger)llround(MAX(100, MIN(10000, rawH * 100.0)))),
        @"widthReference": widthRef,
        @"heightReference": heightRef,
    };
    if (w.buttonStyle.length) d[@"buttonStyle"] = w.buttonStyle;
    d[@"buttonShape"] = @{
        @"topStart": @(w.cornerTopStart),
        @"topEnd": @(w.cornerTopEnd),
        @"bottomEnd": @(w.cornerBottomEnd),
        @"bottomStart": @(w.cornerBottomStart),
    };
    d[@"textAlignment"] = @"Center";
    d[@"textBold"] = @NO;
    d[@"textItalic"] = @NO;
    d[@"textUnderline"] = @NO;
    switch (w.visibility) {
        case A2ControlVisibilityInGame: d[@"visibilityType"] = @"in_game"; break;
        case A2ControlVisibilityInMenu: d[@"visibilityType"] = @"in_menu"; break;
        default:                        d[@"visibilityType"] = @"always"; break;
    }
    d[@"clickEvents"] = [self zlEventsFromList:w.clickEvents ?: @[]];
    d[@"isSwipple"] = @(w.isSwipple);
    d[@"isPenetrable"] = @(w.isPenetrable);
    d[@"isToggleable"] = @(w.isToggleable);

    // ---- Air2 扩展字段 ----
    // ZL2 的 ButtonStyle 里才有 alpha，单控件没有不透明度字段；
    // 写 air2Opacity 让 ZL2 原样保留，回到 Air2 时恢复。
    if (w.opacity < 0.999) d[@"air2Opacity"] = @(w.opacity);
    switch (w.type) {
        case A2ControlWidgetTypeView:
            d[@"viewScale"] = @(w.viewScale);
            d[@"viewShowsBorder"] = @(w.viewShowsBorder);
            d[@"mouseMode"] = w.mouseMode ?: @"slide";
            d[@"mouseSensitivity"] = @(w.mouseSensitivity);
            break;
        case A2ControlWidgetTypeScroll:
            d[@"scrollStep"] = @(w.scrollStep);
            d[@"scrollInverted"] = @(w.scrollInverted);
            d[@"scrollHorizontal"] = @(w.scrollHorizontal);
            break;
        default:
            break;
    }
    return d;
}

+ (NSDictionary *)zlJoystickJSONFromWidget:(A2ControlWidget *)w aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = 16.0 / 9.0;

    // 摇杆尺寸以屏幕高为基准（CcDirection.kt 里的换算）
    CGFloat sizePercentOfHeight = w.heightPercent;
    NSInteger sizePercentage = (NSInteger)llround(MAX(2000, MIN(10000, sizePercentOfHeight * 100.0)));

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"uuid"] = w.identifier ?: [[NSUUID UUID] UUIDString];
    d[@"position"] = @{
        @"x": @([self zlPositionFromPercent:w.xPercent sizePercent:w.widthPercent]),
        @"y": @([self zlPositionFromPercent:w.yPercent sizePercent:w.heightPercent]),
    };
    d[@"sizeType"] = (w.sizeType.length ? w.sizeType : @"percentage");
    d[@"sizeDp"] = @(w.widthDp > 0 ? w.widthDp : 200);
    d[@"sizePercentage"] = @(sizePercentage);
    switch (w.visibility) {
        case A2ControlVisibilityInGame: d[@"visibilityType"] = @"in_game"; break;
        case A2ControlVisibilityInMenu: d[@"visibilityType"] = @"in_menu"; break;
        default:                        d[@"visibilityType"] = @"always"; break;
    }
    if (w.buttonStyle.length) d[@"joystickStyleId"] = w.buttonStyle;
    d[@"deadZoneRatio"] = @(MAX(0.0, MIN(0.9, w.deadZone)));
    d[@"lockThreshold"] = @(MAX(0.0, MIN(1.0, w.lockThreshold)));
    d[@"canLock"] = @(w.canLock);
    d[@"triggerMode"] = (w.triggerMode == A2JoystickTriggerModeRocker) ? @"rocker" : @"drag";

    NSMutableDictionary *dirs = [NSMutableDictionary dictionary];
    if (w.directionEvents) {
        for (NSString *dir in w.directionEvents) {
            dirs[dir] = [self zlEventsFromList:w.directionEvents[dir]];
        }
    }
    d[@"directionEvents"] = dirs;
    d[@"lockEvents"] = [self zlEventsFromList:w.lockEvents ?: @[]];
    if (w.opacity < 0.999) d[@"air2Opacity"] = @(w.opacity);
    return d;
}

+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout aspect:(CGFloat)aspect {
    if (aspect <= 0.05) aspect = layout.aspectRatio > 0.05 ? layout.aspectRatio : 16.0 / 9.0;

    NSMutableArray *layers = [NSMutableArray array];
    // 按原文件顺序写回（ZL2 用 layers[0] 在底层）
    for (A2ControlLayer *layer in layout.layers) {
        NSMutableArray *buttons = [NSMutableArray array];
        NSMutableArray *joysticks = [NSMutableArray array];
        NSMutableArray *texts = [NSMutableArray array];
        NSMutableArray *gamepads = [NSMutableArray array];
        NSMutableArray *gyros = [NSMutableArray array];
        NSMutableArray *hotbars = [NSMutableArray array];
        NSMutableArray *views = [NSMutableArray array];
        NSMutableArray *scrolls = [NSMutableArray array];

        for (A2ControlWidget *w in layer.widgets) {
            switch (w.type) {
                case A2ControlWidgetTypeButton:
                    [buttons addObject:[self zlButtonJSONFromWidget:w aspect:aspect]];
                    break;
                case A2ControlWidgetTypeJoystick:
                    [joysticks addObject:[self zlJoystickJSONFromWidget:w aspect:aspect]];
                    break;
                case A2ControlWidgetTypeTextBox: {
                    NSDictionary *d = [self zlButtonJSONFromWidget:w aspect:aspect];
                    [texts addObject:d];
                    break;
                }
                case A2ControlWidgetTypeGamepad:
                case A2ControlWidgetTypeGyroscope:
                case A2ControlWidgetTypeHotbar:
                case A2ControlWidgetTypeView:
                case A2ControlWidgetTypeScroll: {
                    // Air2 扩展类型：写进扩展键，ZL2 读不懂但会原样保留
                    NSMutableDictionary *d = [[self zlButtonJSONFromWidget:w aspect:aspect] mutableCopy];
                    d[@"air2Type"] = @(w.type);
                    if (w.type == A2ControlWidgetTypeGamepad) [gamepads addObject:d];
                    else if (w.type == A2ControlWidgetTypeGyroscope) [gyros addObject:d];
                    else if (w.type == A2ControlWidgetTypeHotbar) [hotbars addObject:d];
                    else if (w.type == A2ControlWidgetTypeView) [views addObject:d];
                    else [scrolls addObject:d];
                    break;
                }
            }
        }

        NSMutableDictionary *lj = [NSMutableDictionary dictionary];
        lj[@"uuid"] = layer.identifier ?: [[NSUUID UUID] UUIDString];
        lj[@"name"] = layer.name ?: layer.identifier ?: @"Layer";
        lj[@"hide"] = @(!layer.visibleByDefault);
        lj[@"hideWhenMouse"] = @(layer.hideWhenMouse);
        lj[@"hideWhenGamepad"] = @(layer.hideWhenGamepad);
        lj[@"hideWhenJoystick"] = @(layer.hideWhenJoystick);
        lj[@"normalButtons"] = buttons;
        lj[@"joystickButtons"] = joysticks;
        lj[@"textBoxes"] = texts;
        if (gamepads.count) lj[@"gamepadButtons"] = gamepads;
        if (gyros.count) lj[@"gyroscopeButtons"] = gyros;
        if (hotbars.count) lj[@"hotbarButtons"] = hotbars;
        if (views.count) lj[@"viewAreas"] = views;
        if (scrolls.count) lj[@"scrollButtons"] = scrolls;
        [layers addObject:lj];
    }

    NSMutableArray *styles = [NSMutableArray array];
    for (NSDictionary *s in layout.buttonStyles.allValues) {
        if ([s isKindOfClass:NSDictionary.class]) [styles addObject:s];
    }
    NSMutableArray *joystickStyles = [NSMutableArray array];
    for (NSDictionary *s in layout.joystickStyles.allValues) {
        if ([s isKindOfClass:NSDictionary.class]) [joystickStyles addObject:s];
    }

    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"editorVersion"] = @(MAX(12, layout.version));
    root[@"info"] = @{
        @"name": layout.name ?: @"Air2 布局",
        @"author": layout.author ?: @"Air2",
    };
    root[@"layers"] = layers;
    root[@"styles"] = styles;
    root[@"joystickStyles"] = joystickStyles;
    return root;
}

@end
