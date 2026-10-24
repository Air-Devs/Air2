//
//  A2ControlLayout.m
//  Air2
//

#import "A2ControlLayout.h"
#import "A2Logger.h"

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
        w.text = t[@"zh"] ?: t[@"zh_CN"] ?: t[@"zh-Hans"] ?: t[@"en"]
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

    // ---- 行为 ----
    w.isSwipple    = A2Bool(json, @[@"isSwipple", @"swipple", @"isSwipeable"], NO);
    w.isPenetrable = A2Bool(json, @[@"isPenetrable", @"penetrable"], NO);
    w.isToggleable = A2Bool(json, @[@"isToggleable", @"toggleable"], NO);

    // ---- 可见性 ----
    NSString *vis = A2Str(json, @[@"visibilityType", @"visibility"]);
    if ([vis isEqualToString:@"in_game"]) w.visibility = A2ControlVisibilityInGame;
    else if ([vis isEqualToString:@"in_menu"]) w.visibility = A2ControlVisibilityInMenu;
    else w.visibility = A2ControlVisibilityAlways;

    // ---- 点击事件 ----
    id events = A2First(json, @[@"clickEvents", @"events", @"actions"]);
    NSMutableArray<A2ControlEvent *> *list = [NSMutableArray array];
    if ([events isKindOfClass:NSArray.class]) {
        for (id e in events) {
            A2ControlEvent *ev = [A2ControlEvent eventFromJSON:e];
            if (ev) [list addObject:ev];
        }
    }
    w.clickEvents = list;

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

    return d;
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
    return self;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = self.rawJSON
        ? [self.rawJSON mutableCopy] : [NSMutableDictionary dictionary];

    d[@"id"] = self.identifier;
    if (self.name.length) d[@"name"] = self.name;

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *joysticks = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];

    for (A2ControlWidget *w in self.widgets) {
        NSDictionary *j = [w toJSON];
        switch (w.type) {
            case A2ControlWidgetTypeButton:   [buttons addObject:j]; break;
            case A2ControlWidgetTypeJoystick: [joysticks addObject:j]; break;
            case A2ControlWidgetTypeTextBox:  [texts addObject:j]; break;
        }
    }

    // 沿用原有键名：ZL2 用 normalButtons，FCL 用 buttonList
    NSString *btnKey = (d[@"buttonList"] && !d[@"normalButtons"]) ? @"buttonList" : @"normalButtons";
    if (buttons.count || d[btnKey]) d[btnKey] = buttons;
    if (joysticks.count || d[@"joystickButtons"]) d[@"joystickButtons"] = joysticks;
    if (texts.count || d[@"textBoxes"]) d[@"textBoxes"] = texts;

    return d;
}

@end

#pragma mark - 布局

@interface A2ControlLayout ()
@property (nonatomic, copy, readwrite) NSString *sourceFormat;
@end

@implementation A2ControlLayout

+ (instancetype)emptyLayout {
    A2ControlLayout *l = [A2ControlLayout new];
    l.sourceFormat = @"air2";
    l.version = 12;
    l.name = @"新布局";
    l.author = @"Air2";
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

    A2ControlLayout *layout = [A2ControlLayout new];
    layout.rawRoot = json;
    layout.layers = [NSMutableArray array];
    layout.buttonStyles = [NSMutableDictionary dictionary];
    layout.joystickStyles = [NSMutableDictionary dictionary];

    // ---- 格式识别 ----
    if (json[@"layers"] != nil) {
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
        layer.identifier = A2Str(groupBody, @[@"id", @"name"]) ?: [NSString stringWithFormat:@"layer%lu", (unsigned long)i];
        layer.name = A2Str(groupBody, @[@"name", @"id"]) ?: layer.identifier;
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
    if ([json[@"joystickStyles"] isKindOfClass:NSArray.class]) {
        for (NSDictionary *s in json[@"joystickStyles"]) {
            if (![s isKindOfClass:NSDictionary.class]) continue;
            NSString *sid = A2Str(s, @[@"id", @"uuid", @"name"]);
            if (sid.length) layout.joystickStyles[sid] = s;
        }
    }

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
    NSMutableDictionary *root = self.rawRoot
        ? [self.rawRoot mutableCopy] : [NSMutableDictionary dictionary];

    // 按来源格式写回对应的容器键
    BOOL isFCL = [self.sourceFormat isEqualToString:@"fcl"];
    NSString *containerKey = isFCL ? @"viewGroups" : @"layers";

    NSMutableArray *containers = [NSMutableArray array];
    for (A2ControlLayer *layer in self.layers) {
        NSDictionary *layerJSON = [layer toJSON];
        // FCL 要包一层 viewGroup
        containers = containers;  // 保持可读
        [containers addObject:(isFCL ? @{@"viewGroup": layerJSON} : layerJSON)];
    }

    root[containerKey] = containers;
    if (!root[@"editorVersion"] && !isFCL) {
        root[@"editorVersion"] = @(MAX(12, self.version));
    }
    if (!root[@"controllerVersion"] && isFCL) {
        root[@"controllerVersion"] = @(self.version ?: 3);
    }
    if (!root[@"name"]) root[@"name"] = self.name;

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

+ (NSError *)errorWith:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ControlLayout" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
