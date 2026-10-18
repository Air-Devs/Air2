//
//  A2ControlLayout.m
//  Air2
//

#import "A2ControlLayout.h"
#import "A2Logger.h"

#pragma mark - 工具

/// 从多个可能的键里取第一个存在的值。
/// 这是直接兼容三家格式的核心手段 —— 同一语义在不同家的字段名不一样，
/// 按优先级依次尝试，不用写三套解析器。
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
    return fallback;
}

#pragma mark - 事件

@implementation A2ControlEvent

+ (NSDictionary<NSString *, NSNumber *> *)typeMap {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"SendKey":         @(A2ControlEventTypeSendKey),
            @"SendText":        @(A2ControlEventTypeSendText),
            @"MouseWheel":      @(A2ControlEventTypeMouseWheel),
            @"MouseMove":       @(A2ControlEventTypeMouseMove),
            @"ToggleGui":       @(A2ControlEventTypeToggleGui),
            @"ToggleGUI":       @(A2ControlEventTypeToggleGui),
            @"ToggleKeyboard":  @(A2ControlEventTypeToggleKeyboard),
            @"SwitchMouse":     @(A2ControlEventTypeSwitchMouse),
            @"SwitchGui":       @(A2ControlEventTypeToggleGui),
        };
    });
    return map;
}

+ (instancetype)eventFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ControlEvent *e = [A2ControlEvent new];
    // 事件类型字段：ZL2 用 "type"，FCL 也用 "type"
    NSString *typeName = A2Str(json, @[@"type"]);
    if (!typeName.length) typeName = A2Str(json, @[@"Type"]);
    e.rawType = typeName;

    NSNumber *mapped = [self typeMap][typeName ?: @""];
    e.type = mapped ? (A2ControlEventType)mapped.integerValue : A2ControlEventTypeUnknown;

    // 键值字段：ZL2 用 "key"，也可能是 "value"
    e.key = A2Str(json, @[@"key", @"value", @"Key"]);
    return e;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // 未知类型原样写回 —— 我们可能还没支持某些新事件类型
    NSString *typeName = self.rawType;
    if (!typeName.length) {
        switch (self.type) {
            case A2ControlEventTypeSendKey:        typeName = @"SendKey"; break;
            case A2ControlEventTypeSendText:       typeName = @"SendText"; break;
            case A2ControlEventTypeMouseWheel:     typeName = @"MouseWheel"; break;
            case A2ControlEventTypeMouseMove:      typeName = @"MouseMove"; break;
            case A2ControlEventTypeToggleGui:      typeName = @"ToggleGui"; break;
            case A2ControlEventTypeToggleKeyboard: typeName = @"ToggleKeyboard"; break;
            case A2ControlEventTypeSwitchMouse:    typeName = @"SwitchMouse"; break;
            default:                               typeName = @"Unknown"; break;
        }
    }
    d[@"type"] = typeName;
    if (self.key.length) d[@"key"] = self.key;
    return d;
}

@end

#pragma mark - 控件

@implementation A2ControlWidget

+ (instancetype)widgetFromJSON:(NSDictionary *)json type:(A2ControlWidgetType)type {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ControlWidget *w = [A2ControlWidget new];
    w.type = type;
    w.rawJSON = json;

    // ---- 标识 ----
    w.identifier = A2Str(json, @[@"uuid", @"id"]) ?: [[NSUUID UUID] UUIDString];

    // ---- 文字 ----
    // 三家可能给字符串，也可能给 {"zh": "...", "en": "..."} 这种多语言字典
    id textVal = A2First(json, @[@"text", @"name", @"title"]);
    if ([textVal isKindOfClass:NSString.class]) {
        w.text = textVal;
    } else if ([textVal isKindOfClass:NSDictionary.class]) {
        // 按语言优先级取
        NSDictionary *t = textVal;
        w.text = t[@"zh"] ?: t[@"zh_CN"] ?: t[@"zh-Hans"] ?: t[@"en"]
               ?: t.allValues.firstObject;
    }

    // ---- 位置与尺寸 ----
    // 这是三家差异最大的一处：
    //   ZL2:      position: {x, y}        buttonSize: {width, height}   单位 %
    //   FCL 新版:  position: {x, y}        size: {width, height}
    //   FCL 老版:  position: {percentageX, percentageY}
    id pos = A2First(json, @[@"position", @"pos"]);
    w.xPercent = A2Num(pos, @[@"x", @"percentageX", @"percentX"], 0);
    w.yPercent = A2Num(pos, @[@"y", @"percentageY", @"percentY"], 0);

    id size = A2First(json, @[@"buttonSize", @"size"]);
    w.widthPercent  = A2Num(size, @[@"width", @"percentageWidth", @"percentWidth"], 0);
    w.heightPercent = A2Num(size, @[@"height", @"percentageHeight", @"percentHeight"], 0);

    // 有些布局把尺寸直接放在顶层
    if (w.widthPercent <= 0) {
        w.widthPercent = A2Num(json, @[@"width", @"widthPercentage"], 0);
    }
    if (w.heightPercent <= 0) {
        w.heightPercent = A2Num(json, @[@"height", @"heightPercentage"], 0);
    }

    w.sizeType = A2Str(json, @[@"sizeType", @"size_type"]);

    // ---- 样式 ----
    w.buttonStyle = A2Str(json, @[@"buttonStyle", @"style", @"styleId"]);

    // ---- 行为标志 ----
    w.isSwipple    = A2Bool(json, @[@"isSwipple", @"swipple"], NO);
    w.isPenetrable = A2Bool(json, @[@"isPenetrable", @"penetrable"], NO);
    w.isToggleable = A2Bool(json, @[@"isToggleable", @"toggleable"], NO);

    // ---- 可见性 ----
    w.visibilityType = A2Str(json, @[@"visibilityType", @"visibility"]) ?: @"always";

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

    // 位置/尺寸：写回时【保持原来的键名】——
    // 检测原始 JSON 里有 buttonSize 还是 size，沿用同一个
    NSMutableDictionary *pos = [NSMutableDictionary dictionary];
    [pos addEntriesFromDictionary:[self dictOrEmpty:d[@"position"]]];
    if (pos[@"percentageX"] != nil || pos[@"percentX"] != nil) {
        pos[@"percentageX"] = @(self.xPercent);
        pos[@"percentageY"] = @(self.yPercent);
    } else {
        pos[@"x"] = @(self.xPercent);
        pos[@"y"] = @(self.yPercent);
    }
    d[@"position"] = pos;

    NSString *sizeKey = @"buttonSize";
    if (d[@"size"] != nil && d[@"buttonSize"] == nil) sizeKey = @"size";
    NSMutableDictionary *size = [NSMutableDictionary dictionary];
    [size addEntriesFromDictionary:[self dictOrEmpty:d[sizeKey]]];
    size[@"width"] = @(self.widthPercent);
    size[@"height"] = @(self.heightPercent);
    d[sizeKey] = size;

    if (self.sizeType.length) d[@"sizeType"] = self.sizeType;
    if (self.buttonStyle.length) d[@"buttonStyle"] = self.buttonStyle;

    d[@"isSwipple"] = @(self.isSwipple);
    d[@"isPenetrable"] = @(self.isPenetrable);
    d[@"isToggleable"] = @(self.isToggleable);
    d[@"visibilityType"] = self.visibilityType;

    NSMutableArray *events = [NSMutableArray array];
    for (A2ControlEvent *e in self.clickEvents) {
        [events addObject:[e toJSON]];
    }
    d[@"clickEvents"] = events;

    return d;
}

- (NSDictionary *)dictOrEmpty:(id)v {
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

@end

#pragma mark - 布局

@interface A2ControlLayout ()
@property (nonatomic, copy, readwrite) NSString *sourceFormat;
@end

@implementation A2ControlLayout

+ (instancetype)layoutFromJSON:(NSDictionary *)json error:(NSError **)error {
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [self errorWith:@"不是有效的 JSON 对象"];
        return nil;
    }

    A2ControlLayout *layout = [A2ControlLayout new];
    layout.rawRoot = json;
    layout.widgets = [NSMutableArray array];
    layout.buttonStyles = [NSMutableDictionary dictionary];
    layout.joystickStyles = [NSMutableDictionary dictionary];

    // ---- 格式识别 ----
    // ZL2: editorVersion + layers
    // FCL: controllerVersion + viewGroups
    if (json[@"layers"] != nil) {
        layout.sourceFormat = @"zl2";
        layout.version = [json[@"editorVersion"] integerValue];
    } else if (json[@"viewGroups"] != nil) {
        layout.sourceFormat = @"fcl";
        layout.version = [json[@"controllerVersion"] integerValue];
    } else {
        // Air1 与 Android 同构，通常也是 layers
        layout.sourceFormat = @"air1";
        layout.version = [json[@"editorVersion"] integerValue];
    }

    layout.name = A2Str(json, @[@"name", @"layoutName"]) ?: @"未命名布局";
    layout.author = A2Str(json, @[@"author"]);

    // ---- 取出容器 ----
    // 三家都可能有「层」的概念，装饰扁平化处理
    NSArray *containers = nil;
    if (layout.sourceFormat == @"fcl") {
        containers = json[@"viewGroups"];
    } else {
        containers = json[@"layers"];
    }

    if (![containers isKindOfClass:NSArray.class]) {
        // 少数布局把按钮直接放在根上
        containers = @[json];
    }

    for (NSDictionary *container in containers) {
        if (![container isKindOfClass:NSDictionary.class]) continue;
        [layout collectWidgetsFromContainer:container];
    }

    // ---- 样式表 ----
    // ZL2: buttonStyles / joystickStyles
    // FCL: styles
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
           message:[NSString stringWithFormat:
                    @"加载布局「%@」：格式=%@ 版本=%ld 控件=%lu",
                    layout.name, layout.sourceFormat, (long)layout.version,
                    (unsigned long)layout.widgets.count]];

    return layout;
}

/// 从一个容器（layer / viewGroup）里收集控件
- (void)collectWidgetsFromContainer:(NSDictionary *)container {
    struct { const char *keys[3]; A2ControlWidgetType type; } groups[] = {
        { { "normalButtons", "buttons", "buttonList" }, A2ControlWidgetTypeButton },
        { { "joystickButtons", "stockButtons", NULL }, A2ControlWidgetTypeJoystick },
        { { "textBoxes", "textButtons", NULL },       A2ControlWidgetTypeTextBox },
    };

    for (size_t i = 0; i < sizeof(groups) / sizeof(groups[0]); i++) {
        NSArray *list = nil;
        for (int k = 0; k < 3 && groups[i].keys[k]; k++) {
            id v = container[[NSString stringWithUTF8String:groups[i].keys[k]]];
            if ([v isKindOfClass:NSArray.class]) { list = v; break; }
        }
        if (!list) continue;

        for (NSDictionary *j in list) {
            A2ControlWidget *w = [A2ControlWidget widgetFromJSON:j type:groups[i].type];
            if (w) [self.widgets addObject:w];
        }
    }
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

    // 把控件写回对应的容器。
    // 简化处理：全部放进第一个容器（层的划分我们暂不支持编辑）。
    NSArray *containers = root[@"layers"] ?: root[@"viewGroups"];
    NSMutableDictionary *firstContainer = nil;
    if ([containers isKindOfClass:NSArray.class] && containers.count > 0) {
        firstContainer = [containers.firstObject mutableCopy];
    } else {
        firstContainer = [NSMutableDictionary dictionary];
        root[@"layers"] = @[firstContainer];
        root[@"editorVersion"] = root[@"editorVersion"] ?: @12;
    }

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *joysticks = [NSMutableArray array];
    NSMutableArray *textBoxes = [NSMutableArray array];

    for (A2ControlWidget *w in self.widgets) {
        NSDictionary *j = [w toJSON];
        switch (w.type) {
            case A2ControlWidgetTypeButton:   [buttons addObject:j]; break;
            case A2ControlWidgetTypeJoystick: [joysticks addObject:j]; break;
            case A2ControlWidgetTypeTextBox:  [textBoxes addObject:j]; break;
        }
    }

    // 只写存在的容器键 —— 不要凭空加上 "joystickButtons": []
    if (buttons.count || firstContainer[@"normalButtons"]) {
        firstContainer[@"normalButtons"] = buttons;
    }
    if (joysticks.count || firstContainer[@"joystickButtons"]) {
        firstContainer[@"joystickButtons"] = joysticks;
    }
    if (textBoxes.count || firstContainer[@"textBoxes"]) {
        firstContainer[@"textBoxes"] = textBoxes;
    }

    if (root[@"layers"]) {
        NSMutableArray *layers = [containers mutableCopy];
        layers[0] = firstContainer;
        root[@"layers"] = layers;
    } else {
        NSMutableArray *groups = [containers mutableCopy];
        groups[0] = firstContainer;
        root[@"viewGroups"] = groups;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

+ (instancetype)defaultLayoutForScreen:(CGSize)screenSize {
    (void)screenSize;
    A2ControlLayout *layout = [A2ControlLayout new];
    layout.sourceFormat = @"air2";
    layout.version = 12;
    layout.name = @"默认布局";
    layout.author = @"Air2";
    layout.widgets = [NSMutableArray array];
    layout.buttonStyles = [NSMutableDictionary dictionary];
    layout.joystickStyles = [NSMutableDictionary dictionary];

    // 默认控件集在渲染层定义（A2ControlRenderer），
    // 这里只建空布局 —— 避免数据层依赖具体的按钮配置。
    return layout;
}

+ (NSError *)errorWith:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ControlLayout" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
