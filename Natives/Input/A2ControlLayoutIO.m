//
//  A2ControlLayoutIO.m
//  Air2
//

#import "A2ControlLayoutIO.h"
#import "A2KeyCodeMap.h"
#import "a2_log.h"

#include <math.h>

// 名义参考屏幕（iPhone 12/13 横屏 pt）。只用于把「参考屏幕高」「dp」「剩余空间百分比」
// 折算成 0..1 的兜底值；精确值在 wPct/wRef/wPt 与 xPct/yPct 里。
static const double kA2NominalScreenWidth  = 844.0;
static const double kA2NominalScreenHeight = 390.0;

// FCL/ZL2 的方向盘是一个整体，Air2 是 4 个独立按钮 + 中间潜行。
// 按钮边长占盘面 30%，四个方向中心落在盘面 18% / 82% 处，互不重叠。
static const double kA2PadButtonScale = 0.30;
static const double kA2PadEdgeOffset  = 0.18;

#pragma mark - 小工具

static double A2Clamp(double v, double lo, double hi) {
    if (!isfinite(v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}

/// JSON 里的数字/字符串都接受；其他类型走 fallback。
static double A2NumberValue(id value, double fallback) {
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *) value doubleValue];
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *) value];
        double parsed = 0;
        if ([scanner scanDouble:&parsed]) return parsed;
    }
    return fallback;
}

static NSDictionary *A2Dictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? (NSDictionary *) value : nil;
}

/// 「左上角占剩余空间的百分比」→ 中心点归一化坐标。
static double A2CenterFromPosition(double position, double sizeFraction) {
    double p = A2Clamp(position, 0, 1);
    return A2Clamp(p + sizeFraction * (0.5 - p), 0, 1);
}

/// FCL 的 outputKeycodes 是 evdev，必须换算，不能直接透传。
/// 兼容标量与数组两种写法（部分版本 sneakKeycode 给的是单个数字）。
static NSArray<NSNumber *> *A2GlfwKeysFromFCLKeycodes(id list) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    if (list == nil) return out;
    NSArray *items = [list isKindOfClass:NSArray.class] ? (NSArray *) list : @[ list ];
    for (id item in items) {
        NSInteger evdev = (NSInteger) A2NumberValue(item, 0);
        NSInteger code = [A2KeyCodeMap keyCodeFromFCLKeycode:evdev];
        if (code != 0 && ![out containsObject:@(code)]) [out addObject:@(code)];
    }
    return out;
}

/// FCL 一个按钮有四种事件；按「按住 → 点击 → 长按 → 双击」取第一组非空按键。
static NSArray<NSNumber *> *A2FirstFCLKeyList(id event) {
    NSDictionary *ev = A2Dictionary(event);
    if (ev == nil) return @[];
    NSArray<NSString *> *order = @[ @"pressEvent", @"clickEvent",
                                    @"longPressEvent", @"doubleClickEvent" ];
    for (NSString *name in order) {
        NSDictionary *sub = A2Dictionary(ev[name]);
        if (sub == nil) continue;
        NSArray<NSNumber *> *keys = A2GlfwKeysFromFCLKeycodes(sub[@"outputKeycodes"]);
        if (keys.count) return keys;
    }
    return @[];
}

/// ZL2 的 key 是字符串名（"GLFW_KEY_W" / "GLFW_MOUSE_BUTTON_LEFT"），只取 type=key。
static NSArray<NSNumber *> *A2GlfwKeysFromZL2Events(id events) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    if (![events isKindOfClass:NSArray.class]) return out;
    for (id item in (NSArray *) events) {
        NSDictionary *event = A2Dictionary(item);
        if (event == nil) continue;
        if (![[event[@"type"] description] isEqualToString:@"key"]) continue;
        id keyName = event[@"key"];
        if (![keyName isKindOfClass:NSString.class]) continue;
        NSInteger code = [A2KeyCodeMap keyCodeFromName:(NSString *) keyName];
        if (code != 0 && ![out containsObject:@(code)]) [out addObject:@(code)];
    }
    return out;
}

/// FCL baseInfo → 兜底 w/h + 精确尺寸字段。
static NSDictionary<NSString *, id> *A2FCLSize(id baseInfo) {
    NSDictionary *base = A2Dictionary(baseInfo) ?: @{};
    NSMutableDictionary<NSString *, id> *size = [NSMutableDictionary dictionary];
    NSString *type = [base[@"sizeType"] description] ?: @"PERCENTAGE";

    if ([type isEqualToString:@"ABSOLUTE"]) {
        double wPt = A2NumberValue(base[@"absoluteWidth"], 50);
        double hPt = A2NumberValue(base[@"absoluteHeight"], 50);
        size[@"wPt"] = @(wPt);
        size[@"hPt"] = @(hPt);
        size[@"w"] = @(A2Clamp(wPt / kA2NominalScreenWidth, 0.01, 1));
        size[@"h"] = @(A2Clamp(hPt / kA2NominalScreenHeight, 0.01, 1));
        return size;
    }

    NSDictionary *pw = A2Dictionary(base[@"percentageWidth"]) ?: @{};
    NSDictionary *ph = A2Dictionary(base[@"percentageHeight"]) ?: @{};
    // FCL 的 size 是千分比（50 ⇒ 5%），统一成万分比保存。
    double wPct = A2Clamp(A2NumberValue(pw[@"size"], 50) * 10.0, 0, 10000);
    double hPct = A2Clamp(A2NumberValue(ph[@"size"], 50) * 10.0, 0, 10000);
    BOOL wRefHeight = [[pw[@"reference"] description] isEqualToString:@"SCREEN_HEIGHT"];
    BOOL hRefWidth  = [[ph[@"reference"] description] isEqualToString:@"SCREEN_WIDTH"];

    size[@"wPct"] = @(wPct);
    size[@"hPct"] = @(hPct);
    size[@"wRef"] = wRefHeight ? @"h" : @"w";
    size[@"hRef"] = hRefWidth ? @"w" : @"h";

    double wFraction = wRefHeight
        ? (kA2NominalScreenHeight / kA2NominalScreenWidth) * (wPct / 10000.0)
        : (wPct / 10000.0);
    double hFraction = hRefWidth
        ? (kA2NominalScreenWidth / kA2NominalScreenHeight) * (hPct / 10000.0)
        : (hPct / 10000.0);
    size[@"w"] = @(A2Clamp(wFraction, 0.01, 1));
    size[@"h"] = @(A2Clamp(hFraction, 0.01, 1));
    return size;
}

/// ZL2 buttonSize → 兜底 w/h + 精确尺寸字段。
static NSDictionary<NSString *, id> *A2ZL2Size(id buttonSize) {
    NSDictionary *size = A2Dictionary(buttonSize) ?: @{};
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    NSString *type = [size[@"type"] description] ?: @"percentage";

    if ([type isEqualToString:@"dp"]) {
        double wPt = A2NumberValue(size[@"widthDp"], 50);
        double hPt = A2NumberValue(size[@"heightDp"], 50);
        out[@"wPt"] = @(wPt);
        out[@"hPt"] = @(hPt);
        out[@"w"] = @(A2Clamp(wPt / kA2NominalScreenWidth, 0.01, 1));
        out[@"h"] = @(A2Clamp(hPt / kA2NominalScreenHeight, 0.01, 1));
        return out;
    }
    if ([type isEqualToString:@"wrap_content"]) {
        out[@"wrap"] = @YES;
        out[@"w"] = @0.10;
        out[@"h"] = @0.18;
        return out;
    }

    double wPct = A2Clamp(A2NumberValue(size[@"widthPercentage"], 1400), 0, 10000);
    double hPct = A2Clamp(A2NumberValue(size[@"heightPercentage"], 1400), 0, 10000);
    BOOL wRefHeight = [[size[@"widthReference"] description] isEqualToString:@"screen_height"];
    BOOL hRefWidth  = [[size[@"heightReference"] description] isEqualToString:@"screen_width"];

    out[@"wPct"] = @(wPct);
    out[@"hPct"] = @(hPct);
    out[@"wRef"] = wRefHeight ? @"h" : @"w";
    out[@"hRef"] = hRefWidth ? @"w" : @"h";

    double wFraction = wRefHeight
        ? (kA2NominalScreenHeight / kA2NominalScreenWidth) * (wPct / 10000.0)
        : (wPct / 10000.0);
    double hFraction = hRefWidth
        ? (kA2NominalScreenWidth / kA2NominalScreenHeight) * (hPct / 10000.0)
        : (hPct / 10000.0);
    out[@"w"] = @(A2Clamp(wFraction, 0.01, 1));
    out[@"h"] = @(A2Clamp(hFraction, 0.01, 1));
    return out;
}

#pragma mark -

@implementation A2ControlLayoutIO

#pragma mark 格式识别

+ (A2ControlLayoutFormat)detectFormat:(id)json {
    NSDictionary *root = A2Dictionary(json);
    if (root == nil) return A2ControlLayoutFormatA2;
    if ([root[@"layers"] isKindOfClass:NSArray.class]) return A2ControlLayoutFormatZL2;
    if ([root[@"viewGroups"] isKindOfClass:NSArray.class] || root[@"controllerVersion"] != nil) {
        return A2ControlLayoutFormatFCL;
    }
    return A2ControlLayoutFormatA2;
}

#pragma mark 解析入口

+ (nullable NSArray<NSDictionary *> *)parseJSON:(id)json format:(A2ControlLayoutFormat)format {
    if (A2Dictionary(json) == nil) {
        a2_log_f(@"[A2-CONTROLS] 布局解析失败：根节点不是对象（格式=%ld）", (long) format);
        return nil;
    }
    switch (format) {
        case A2ControlLayoutFormatFCL: return [self a2_parseFCL:json];
        case A2ControlLayoutFormatZL2: return [self a2_parseZL2:json];
        default:                       return [self a2_parseA2:json];
    }
}

#pragma mark A2

+ (nullable NSArray<NSDictionary *> *)a2_parseA2:(id)json {
    NSDictionary *root = A2Dictionary(json);
    NSArray *arr = root[@"controls"];
    if (![arr isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in arr) {
        NSDictionary *control = A2Dictionary(item);
        if (control == nil) continue;
        id rawID = control[@"id"];
        // NSNull / 数组等不能当 id（description 会产出 "<null>" 之类，后续会变成脏 id）。
        if (![rawID isKindOfClass:NSString.class] && ![rawID isKindOfClass:NSNumber.class]) continue;
        NSString *cid = [rawID description];
        if (cid.length == 0) continue;
        if (control[@"x"] == nil || control[@"y"] == nil ||
            control[@"w"] == nil || control[@"h"] == nil) {
            continue;
        }
        [out addObject:control];
    }
    if (out.count == 0) {
        a2_log_f(@"[A2-CONTROLS] A2 布局里没有可用控件（原始 %lu 项）", (unsigned long) arr.count);
        return nil;
    }
    return out;
}

#pragma mark FCL

+ (nullable NSArray<NSDictionary *> *)a2_parseFCL:(id)json {
    NSDictionary *root = A2Dictionary(json);
    NSArray *groups = root[@"viewGroups"];
    if (![groups isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSUInteger groupIndex = 0;
    for (id item in groups) {
        NSDictionary *group = A2Dictionary(item);
        NSDictionary *viewData = A2Dictionary(group[@"viewData"]);
        if (viewData == nil) { groupIndex++; continue; }
        NSString *groupID = [group[@"id"] description] ?: [NSString stringWithFormat:@"group%lu", (unsigned long) groupIndex];

        NSArray *buttons = viewData[@"buttonList"];
        if ([buttons isKindOfClass:NSArray.class]) {
            NSUInteger index = 0;
            for (id element in buttons) {
                NSDictionary *button = A2Dictionary(element);
                NSDictionary *base = A2Dictionary(button[@"baseInfo"]);
                if (base == nil) { index++; continue; }

                NSMutableDictionary<NSString *, id> *control = [NSMutableDictionary dictionary];
                [control addEntriesFromDictionary:A2FCLSize(base)];

                NSString *cid = [button[@"id"] description];
                if (cid.length == 0) {
                    cid = [NSString stringWithFormat:@"fcl-%@-%lu", groupID, (unsigned long) index];
                }
                NSArray<NSNumber *> *keys = A2FirstFCLKeyList(button[@"event"]);
                double xPct = A2Clamp(A2NumberValue(base[@"xPosition"], 0) / 1000.0, 0, 1);
                double yPct = A2Clamp(A2NumberValue(base[@"yPosition"], 0) / 1000.0, 0, 1);

                control[@"id"] = cid;
                control[@"xPct"] = @(xPct * 10000.0);
                control[@"yPct"] = @(yPct * 10000.0);
                control[@"x"] = @(A2CenterFromPosition(xPct, [control[@"w"] doubleValue]));
                control[@"y"] = @(A2CenterFromPosition(yPct, [control[@"h"] doubleValue]));
                control[@"a"] = @1.0;
                control[@"keys"] = keys;
                control[@"key"] = keys.firstObject ?: @0;
                id text = button[@"text"];
                control[@"label"] = [text isKindOfClass:NSString.class] ? text : @"";

                [out addObject:control];
                index++;
            }
        }

        NSArray *directions = viewData[@"directionList"];
        if ([directions isKindOfClass:NSArray.class]) {
            NSUInteger index = 0;
            for (id element in directions) {
                NSDictionary *direction = A2Dictionary(element);
                NSDictionary *base = A2Dictionary(direction[@"baseInfo"]);
                if (base == nil) { index++; continue; }
                [out addObjectsFromArray:[self a2_controlsFromFCLDirection:direction
                                                                     base:base
                                                                     index:index]];
                index++;
            }
        }
        groupIndex++;
    }

    if (out.count == 0) {
        a2_log_f(@"[A2-CONTROLS] FCL 布局里没有可用控件（viewGroups=%lu）", (unsigned long) groups.count);
        return nil;
    }
    return out;
}

/// 方向盘 → 4 个方向按钮（+ 中间潜行）。位置用名义屏幕像素算，再归一化。
+ (NSArray<NSDictionary *> *)a2_controlsFromFCLDirection:(NSDictionary *)direction
                                                   base:(NSDictionary *)base
                                                  index:(NSUInteger)index {
    NSDictionary *event = A2Dictionary(direction[@"event"]) ?: @{};
    NSString *directionID = [direction[@"id"] description];
    if (directionID.length == 0) {
        directionID = [NSString stringWithFormat:@"dir%lu", (unsigned long) index];
    }

    // 盘面边长：绝对尺寸取 absoluteWidth，百分比取 percentageWidth。
    double padPx = 0;
    NSString *type = [base[@"sizeType"] description] ?: @"PERCENTAGE";
    if ([type isEqualToString:@"ABSOLUTE"]) {
        padPx = A2NumberValue(base[@"absoluteWidth"], 50);
    } else {
        NSDictionary *pw = A2Dictionary(base[@"percentageWidth"]) ?: @{};
        double fraction = A2NumberValue(pw[@"size"], 50) / 1000.0;
        BOOL refHeight = [[pw[@"reference"] description] isEqualToString:@"SCREEN_HEIGHT"];
        padPx = (refHeight ? kA2NominalScreenHeight : kA2NominalScreenWidth) * fraction;
    }
    padPx = A2Clamp(padPx, 24.0, MIN(kA2NominalScreenWidth, kA2NominalScreenHeight));

    double xPct = A2Clamp(A2NumberValue(base[@"xPosition"], 0) / 1000.0, 0, 1);
    double yPct = A2Clamp(A2NumberValue(base[@"yPosition"], 0) / 1000.0, 0, 1);
    double originX = (kA2NominalScreenWidth - padPx) * xPct;
    double originY = (kA2NominalScreenHeight - padPx) * yPct;
    double centerX = originX + padPx * 0.5;
    double centerY = originY + padPx * 0.5;
    double buttonPx = padPx * kA2PadButtonScale;

    // 方向键默认 W/A/S/D（evdev 17/31/30/32），潜行默认左 Shift（evdev 42）。
    NSArray<NSString *> *roles = @[ @"up", @"down", @"left", @"right" ];
    NSDictionary<NSString *, NSString *> *keyFields = @{
        @"up": @"upKeycode", @"down": @"downKeycode",
        @"left": @"leftKeycode", @"right": @"rightKeycode",
    };
    NSDictionary<NSString *, NSNumber *> *defaultKeys = @{
        @"up": @87, @"down": @83, @"left": @65, @"right": @68,
    };
    NSDictionary<NSString *, NSArray<NSNumber *> *> *centers = @{
        @"up":    @[ @(centerX), @(originY + padPx * kA2PadEdgeOffset) ],
        @"down":  @[ @(centerX), @(originY + padPx * (1.0 - kA2PadEdgeOffset)) ],
        @"left":  @[ @(originX + padPx * kA2PadEdgeOffset), @(centerY) ],
        @"right": @[ @(originX + padPx * (1.0 - kA2PadEdgeOffset)), @(centerY) ],
    };
    NSDictionary<NSString *, NSString *> *defaultLabels = @{
        @"up": @"W", @"down": @"S", @"left": @"A", @"right": @"D",
    };

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *role in roles) {
        NSArray<NSNumber *> *keys = A2GlfwKeysFromFCLKeycodes(event[keyFields[role]]);
        if (keys.count == 0) keys = @[ defaultKeys[role] ];
        NSArray<NSNumber *> *center = centers[role];

        [out addObject:@{
            @"id": [NSString stringWithFormat:@"%@-%@", directionID, role],
            @"role": role,
            @"x": @(A2Clamp(center[0].doubleValue / kA2NominalScreenWidth, 0, 1)),
            @"y": @(A2Clamp(center[1].doubleValue / kA2NominalScreenHeight, 0, 1)),
            @"w": @(buttonPx / kA2NominalScreenWidth),
            @"h": @(buttonPx / kA2NominalScreenHeight),
            @"a": @1.0,
            @"keys": keys,
            @"key": keys.firstObject,
            @"label": defaultLabels[role],
        }];
    }

    BOOL sneak = A2NumberValue(event[@"sneak"], 1) != 0;
    if (sneak) {
        id sneakValue = event[@"sneakKeycode"];
        NSArray<NSNumber *> *keys = A2GlfwKeysFromFCLKeycodes(sneakValue ?: @42);
        if (keys.count == 0) keys = @[ @340 ];
        [out addObject:@{
            @"id": [NSString stringWithFormat:@"%@-sneak", directionID],
            @"role": @"sneak",
            @"x": @(A2Clamp(centerX / kA2NominalScreenWidth, 0, 1)),
            @"y": @(A2Clamp(centerY / kA2NominalScreenHeight, 0, 1)),
            @"w": @(buttonPx / kA2NominalScreenWidth),
            @"h": @(buttonPx / kA2NominalScreenHeight),
            @"a": @1.0,
            @"keys": keys,
            @"key": keys.firstObject,
            @"label": @"潜",
        }];
    }
    return out;
}

#pragma mark ZL2

+ (nullable NSArray<NSDictionary *> *)a2_parseZL2:(id)json {
    NSDictionary *root = A2Dictionary(json);
    NSArray *layers = root[@"layers"];
    if (![layers isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSUInteger layerIndex = 0;
    for (id item in layers) {
        NSDictionary *layer = A2Dictionary(item);
        NSArray *buttons = layer[@"normalButtons"];
        if (![buttons isKindOfClass:NSArray.class]) { layerIndex++; continue; }

        NSUInteger index = 0;
        for (id element in buttons) {
            NSDictionary *button = A2Dictionary(element);
            if (button == nil) { index++; continue; }
            NSDictionary *position = A2Dictionary(button[@"position"]) ?: @{};
            NSMutableDictionary<NSString *, id> *control = [NSMutableDictionary dictionary];
            [control addEntriesFromDictionary:A2ZL2Size(button[@"buttonSize"])];

            NSString *cid = [button[@"uuid"] description];
            if (cid.length == 0) {
                cid = [NSString stringWithFormat:@"zl2-%lu-%lu", (unsigned long) layerIndex,
                       (unsigned long) index];
            }
            NSArray<NSNumber *> *keys = A2GlfwKeysFromZL2Events(button[@"clickEvents"]);
            double xPct = A2Clamp(A2NumberValue(position[@"x"], 0) / 10000.0, 0, 1);
            double yPct = A2Clamp(A2NumberValue(position[@"y"], 0) / 10000.0, 0, 1);

            control[@"id"] = cid;
            control[@"xPct"] = @(xPct * 10000.0);
            control[@"yPct"] = @(yPct * 10000.0);
            control[@"x"] = @(A2CenterFromPosition(xPct, [control[@"w"] doubleValue]));
            control[@"y"] = @(A2CenterFromPosition(yPct, [control[@"h"] doubleValue]));
            control[@"a"] = @1.0;
            control[@"keys"] = keys;
            control[@"key"] = keys.firstObject ?: @0;
            control[@"label"] = [self a2_labelFromZL2Text:button[@"text"]];

            [out addObject:control];
            index++;
        }
        layerIndex++;
    }

    if (out.count == 0) {
        a2_log_f(@"[A2-CONTROLS] ZL2 布局里没有可用控件（layers=%lu）", (unsigned long) layers.count);
        return nil;
    }
    return out;
}

/// ZL2 的文本是 TranslatableString { default, matchQueue }；这里只取 default。
+ (NSString *)a2_labelFromZL2Text:(id)text {
    if ([text isKindOfClass:NSString.class]) return (NSString *) text;
    NSDictionary *dict = A2Dictionary(text);
    id value = dict[@"default"];
    return [value isKindOfClass:NSString.class] ? (NSString *) value : @"";
}

#pragma mark 导出

+ (nullable id)exportControls:(NSArray<NSDictionary *> *)controls
                       format:(A2ControlLayoutFormat)format
                         name:(NSString *)name {
    if (format != A2ControlLayoutFormatA2) {
        a2_log_f(@"[A2-CONTROLS] 暂不支持导出 %s 格式：顶层还缺 styles/special/info 等必需字段",
                 (format == A2ControlLayoutFormatFCL ? @"FCL" : @"ZL2").UTF8String);
        return nil;
    }
    return @{
        @"format": @"a2",
        @"name": name.length ? name : @"布局",
        @"controls": controls ?: @[],
    };
}

@end
