//
//  A2ControlFormat.m
//  Air2
//
//  格式门面实现。见 .h 的说明。
//

#import "A2ControlFormat.h"
#import "A2ControlFormatZL.h"
#import "A2ControlFormatFCL.h"
#import "A2Logger.h"

static NSString *const kA2ExtensionsKey = @"air2Extensions";

@implementation A2ControlFormat

+ (NSString *)extensionsKey {
    return kA2ExtensionsKey;
}

#pragma mark - 识别

+ (A2ControlFormatKind)detectFormat:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return A2ControlFormatKindUnknown;

    // Air2 内部格式必须最先判断：它也用 layers[]，但坐标是屏幕百分比。
    // 判断晚了会被当成 ZL2，坐标错十倍（见 A2ControlLayout.h 的坐标说明）。
    if (json[@"air2Version"] != nil) return A2ControlFormatKindAir2;
    if ([json[@"format"] isKindOfClass:NSString.class] &&
        [json[@"format"] isEqualToString:@"air2"]) {
        return A2ControlFormatKindAir2;
    }
    if ([A2ControlFormatFCL sniff:json]) return A2ControlFormatKindFCL;
    if ([json[@"layers"] isKindOfClass:NSArray.class]) return A2ControlFormatKindZL2;
    if ([json[@"normalButtons"] isKindOfClass:NSArray.class] ||
        [json[@"joystickButtons"] isKindOfClass:NSArray.class] ||
        [json[@"viewGroup"] isKindOfClass:NSDictionary.class]) {
        return A2ControlFormatKindAir1;
    }
    if (json[@"editorVersion"] != nil) return A2ControlFormatKindAir2;
    return A2ControlFormatKindUnknown;
}

+ (A2ControlFormatKind)kindForName:(NSString *)name {
    if (![name isKindOfClass:NSString.class]) return A2ControlFormatKindUnknown;
    NSString *n = name.lowercaseString;
    if ([n isEqualToString:@"zl2"] || [n isEqualToString:@"zalith"]) return A2ControlFormatKindZL2;
    if ([n isEqualToString:@"fcl"] || [n isEqualToString:@"foldcraft"]) return A2ControlFormatKindFCL;
    if ([n isEqualToString:@"air1"]) return A2ControlFormatKindAir1;
    if ([n isEqualToString:@"air2"]) return A2ControlFormatKindAir2;
    return A2ControlFormatKindUnknown;
}

+ (NSString *)nameForKind:(A2ControlFormatKind)kind {
    switch (kind) {
        case A2ControlFormatKindZL2:  return @"zl2";
        case A2ControlFormatKindFCL:  return @"fcl";
        case A2ControlFormatKindAir1: return @"air1";
        case A2ControlFormatKindAir2: return @"air2";
        default:                      return @"unknown";
    }
}

+ (A2ControlFormatKind)kindForFileExtension:(NSString *)ext {
    // 三家的控件文件都叫 json，扩展名区分不了，内容说了算
    (void)ext;
    return A2ControlFormatKindUnknown;
}

#pragma mark - 导入

+ (A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error {
    A2ControlFormatKind kind = [self detectFormat:json];

    A2ControlLayout *layout = nil;
    switch (kind) {
        case A2ControlFormatKindFCL:
            layout = [A2ControlFormatFCL layoutFromJSON:json error:error];
            break;
        case A2ControlFormatKindZL2:
            layout = [A2ControlFormatZL layoutFromJSON:json error:error];
            break;
        case A2ControlFormatKindAir1:
        case A2ControlFormatKindAir2:
        case A2ControlFormatKindUnknown:
        default:
            // 通用兼容路径（Air1 / 老 Air2 / 未知）
            layout = [A2ControlLayout layoutFromJSON:json error:error];
            break;
    }

    if (layout) [self mergeExtensionsFrom:json into:layout];
    return layout;
}

+ (A2ControlLayout *)layoutFromFile:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2ControlFormat" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"不是 JSON 对象"}];
        }
        return nil;
    }
    return [self layoutFromJSON:json error:error];
}

/// 把导出时塞进 air2Extensions 的扩展控件合并回对应层
+ (void)mergeExtensionsFrom:(NSDictionary *)json into:(A2ControlLayout *)layout {
    NSArray *entries = [json[kA2ExtensionsKey] isKindOfClass:NSArray.class]
        ? json[kA2ExtensionsKey] : @[];
    if (entries.count == 0) return;

    // 已有控件的 identifier 集合 —— 避免和普通控件重复（比如 FCL 里的占位按钮）
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (A2ControlWidget *w in layout.allWidgets) {
        if (w.identifier.length) [existing addObject:w.identifier];
    }

    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *layerID = entry[@"layer"];
        NSNumber *typeNum = entry[@"type"];
        NSDictionary *widgetJSON = entry[@"widget"];
        if (![typeNum isKindOfClass:NSNumber.class] ||
            ![widgetJSON isKindOfClass:NSDictionary.class]) continue;
        if ([widgetJSON[@"uuid"] isKindOfClass:NSString.class] &&
            [existing containsObject:widgetJSON[@"uuid"]]) continue;

        A2ControlLayer *target = nil;
        for (A2ControlLayer *l in layout.layers) {
            if (layerID.length && [l.identifier isEqualToString:layerID]) { target = l; break; }
        }
        if (!target) target = layout.layers.firstObject;
        if (!target) continue;

        A2ControlWidgetType type = (A2ControlWidgetType)typeNum.integerValue;
        if (type != A2ControlWidgetTypeGamepad &&
            type != A2ControlWidgetTypeGyroscope &&
            type != A2ControlWidgetTypeHotbar &&
            type != A2ControlWidgetTypeView &&
            type != A2ControlWidgetTypeScroll) continue;

        // FCL 导出时给扩展控件写了一个装饰占位按钮（id = "<uuid>.air2"）。
        // 恢复真控件前先把这个占位删掉，否则界面上会多一个点不动的假按钮。
        NSString *uuid = widgetJSON[@"uuid"];
        if (uuid.length) {
            NSString *placeholderID = [uuid stringByAppendingString:@".air2"];
            for (A2ControlLayer *l in layout.layers) {
                NSMutableArray *toRemove = [NSMutableArray array];
                for (A2ControlWidget *candidate in l.widgets) {
                    if ([candidate.identifier isEqualToString:placeholderID]) {
                        [toRemove addObject:candidate];
                    }
                }
                for (A2ControlWidget *dead in toRemove) [l.widgets removeObject:dead];
            }
        }

        A2ControlWidget *w = [A2ControlWidget widgetFromJSON:widgetJSON
                                                        type:type
                                                     layerID:target.identifier];
        if (w) {
            [target.widgets addObject:w];
            [A2Logger info:@"A2ControlFormat"
                   message:[NSString stringWithFormat:@"恢复扩展控件「%@」(type=%ld)",
                            w.identifier, (long)type]];
        }
    }
}

#pragma mark - 导出

+ (NSDictionary *)genericJSONFromLayout:(A2ControlLayout *)layout {
    NSMutableArray *layers = [NSMutableArray array];
    for (A2ControlLayer *layer in layout.layers) {
        [layers addObject:[layer toJSON]];
    }
    // format / air2Version 是内部格式的"身份证"：
    //   · 让 detectFormat 走 Air2 分支（百分比坐标）
    //   · 让 A2ControlStore 的迁移能判断文件版本
    // editorVersion 保留 ZL2 的值只是方便人工阅读，不代表坐标是 ZL2 的。
    return @{
        @"format": @"air2",
        @"air2Version": @([A2ControlLayout currentFormatVersion]),
        @"editorVersion": @(MAX(12, layout.version)),
        @"name": layout.name ?: @"Air2 布局",
        @"author": layout.author ?: @"Air2",
        @"layers": layers,
        @"buttonStyles": layout.buttonStyles ?: @{},
        @"joystickStyles": layout.joystickStyles ?: @{},
    };
}

+ (NSArray<NSDictionary *> *)extensionEntriesFromLayout:(A2ControlLayout *)layout {
    NSMutableArray *out = [NSMutableArray array];
    for (A2ControlLayer *layer in layout.layers) {
        for (A2ControlWidget *w in layer.widgets) {
            if (w.type != A2ControlWidgetTypeGamepad &&
                w.type != A2ControlWidgetTypeGyroscope &&
                w.type != A2ControlWidgetTypeHotbar &&
                w.type != A2ControlWidgetTypeView &&
                w.type != A2ControlWidgetTypeScroll) continue;
            [out addObject:@{
                @"layer": layer.identifier ?: @"",
                @"type": @(w.type),
                @"widget": [w toJSON],
            }];
        }
    }
    return out;
}

+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout format:(A2ControlFormatKind)kind {
    if (!layout) return @{};

    A2ControlFormatKind resolved = kind;
    if (resolved == A2ControlFormatKindUnknown) {
        resolved = [self kindForName:layout.sourceFormat];
    }

    NSMutableDictionary *json = nil;
    switch (resolved) {
        case A2ControlFormatKindFCL:
            json = [[A2ControlFormatFCL jsonFromLayout:layout
                                                aspect:layout.aspectRatio] mutableCopy];
            break;
        case A2ControlFormatKindZL2:
            json = [[A2ControlFormatZL jsonFromLayout:layout
                                               aspect:layout.aspectRatio] mutableCopy];
            break;
        default:
            json = [[self genericJSONFromLayout:layout] mutableCopy];
            break;
    }

    // 扩展控件保真：只有导出到对方格式时才需要挂在根节点上。
    // Air2 原生格式里这些控件本来就在 layers[] 里，再挂一份会重复。
    if (resolved == A2ControlFormatKindZL2 || resolved == A2ControlFormatKindFCL) {
        NSArray *extensions = [self extensionEntriesFromLayout:layout];
        if (extensions.count) json[kA2ExtensionsKey] = extensions;
    }

    return json;
}

+ (BOOL)writeLayout:(A2ControlLayout *)layout
             toFile:(NSString *)path
             format:(A2ControlFormatKind)kind
              error:(NSError **)error {
    NSDictionary *json = [self jsonFromLayout:layout format:kind];
    if (![NSJSONSerialization isValidJSONObject:json]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2ControlFormat" code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"布局里有无法序列化的值"}];
        }
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@end
