//
//  A2ControlLayoutIO.m
//  Air2
//

#import "A2ControlLayoutIO.h"

@implementation A2ControlLayoutIO

#pragma mark - 格式识别

+ (A2ControlLayoutFormat)detectFormat:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return A2ControlLayoutFormatA2;
    NSDictionary *d = (NSDictionary *) json;
    if (d[@"layers"] != nil) return A2ControlLayoutFormatZL2;
    if (d[@"viewGroups"] != nil || d[@"controllerVersion"] != nil) return A2ControlLayoutFormatFCL;
    return A2ControlLayoutFormatA2;
}

#pragma mark - 解析

+ (nullable NSArray<NSDictionary *> *)parseJSON:(id)json format:(A2ControlLayoutFormat)format {
    switch (format) {
        case A2ControlLayoutFormatFCL: return [self parseFCL:json];
        case A2ControlLayoutFormatZL2: return [self parseZL2:json];
        default:                       return [self parseA2:json];
    }
}

+ (nullable NSArray<NSDictionary *> *)parseA2:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSArray *arr = ((NSDictionary *) json)[@"controls"];
    return [arr isKindOfClass:NSArray.class] ? arr : nil;
}

/// FCL：viewGroups[].viewData.buttonList[] / directionList[]
/// baseInfo.xPosition/yPosition 为千分比(0..1000)；event.*.outputKeycodes 为数字键码。
+ (nullable NSArray<NSDictionary *> *)parseFCL:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSArray *groups = ((NSDictionary *) json)[@"viewGroups"];
    if (![groups isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *g in groups) {
        NSDictionary *vd = g[@"viewData"];
        NSArray *buttons = vd[@"buttonList"];
        if ([buttons isKindOfClass:NSArray.class]) {
            for (NSDictionary *b in buttons) {
                NSDictionary *base = b[@"baseInfo"];
                NSDictionary *ev = b[@"event"];
                NSDictionary *press = ev[@"pressEvent"] ?: ev[@"clickEvent"];
                NSArray *codes = press[@"outputKeycodes"];
                NSInteger key = ([codes isKindOfClass:NSArray.class] && codes.count > 0)
                                ? [codes.firstObject integerValue] : 0;
                double x = [base[@"xPosition"] doubleValue] / 1000.0;
                double y = [base[@"yPosition"] doubleValue] / 1000.0;
                double w = 0.10, h = 0.18;
                NSDictionary *pw = base[@"percentageWidth"];
                if ([pw isKindOfClass:NSDictionary.class]) w = [pw[@"size"] doubleValue] / 1000.0;
                NSDictionary *ph = base[@"percentageHeight"];
                if ([ph isKindOfClass:NSDictionary.class]) h = [ph[@"size"] doubleValue] / 1000.0;
                NSString *cid = b[@"id"] ?: [NSString stringWithFormat:@"fcl%lu", (unsigned long) out.count];
                [out addObject:@{
                    @"id": cid, @"x": @(x), @"y": @(y), @"w": @(w), @"h": @(h),
                    @"a": @(1.0), @"key": @(key),
                    @"label": b[@"text"] ?: @"",
                }];
            }
        }
        NSArray *dirs = vd[@"directionList"];
        if ([dirs isKindOfClass:NSArray.class]) {
            for (NSDictionary *dd in dirs) {
                NSDictionary *base = dd[@"baseInfo"];
                NSDictionary *ev = dd[@"event"];
                NSDictionary *map = @{ @"up": @87, @"down": @83, @"left": @65, @"right": @68 };
                for (NSString *dir in map) {
                    NSNumber *code = ev[[NSString stringWithFormat:@"%@Keycode", dir]];
                    NSInteger key = [code isKindOfClass:NSNumber.class] ? code.integerValue : [map[dir] integerValue];
                    NSString *cid = [NSString stringWithFormat:@"%@-%@", dd[@"id"] ?: @"dir", dir];
                    [out addObject:@{
                        @"id": cid,
                        @"x": @([base[@"xPosition"] doubleValue] / 1000.0),
                        @"y": @([base[@"yPosition"] doubleValue] / 1000.0),
                        @"w": @0.08, @"h": @0.14, @"a": @(1.0), @"key": @(key),
                        @"label": dir,
                    }];
                }
            }
        }
    }
    return out.count ? out : nil;
}

/// ZL2：layers[].normalButtons[]；position 为万分比(0..10000)；键码已是 GLFW。
+ (nullable NSArray<NSDictionary *> *)parseZL2:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSArray *layers = ((NSDictionary *) json)[@"layers"];
    if (![layers isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *layer in layers) {
        NSArray *buttons = layer[@"normalButtons"];
        if (![buttons isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *b in buttons) {
            NSDictionary *pos = b[@"position"];
            NSDictionary *size = b[@"buttonSize"];
            NSArray *events = b[@"clickEvents"];
            NSInteger key = 0;
            if ([events isKindOfClass:NSArray.class] && events.count > 0) {
                NSDictionary *e0 = events.firstObject;
                id k = e0[@"keycode"] ?: e0[@"keyCode"] ?: e0[@"glfwKeycode"];
                if ([k isKindOfClass:NSNumber.class]) key = [k integerValue];
            }
            NSString *text = nil;
            id t = b[@"text"];
            if ([t isKindOfClass:NSDictionary.class]) text = t[@"default"];
            else if ([t isKindOfClass:NSString.class]) text = t;
            [out addObject:@{
                @"id": b[@"uuid"] ?: [NSString stringWithFormat:@"zl%lu", (unsigned long) out.count],
                @"x": @([pos[@"x"] doubleValue] / 10000.0),
                @"y": @([pos[@"y"] doubleValue] / 10000.0),
                @"w": @(size[@"width"] ? [size[@"width"] doubleValue] / 10000.0 : 0.08),
                @"h": @(size[@"height"] ? [size[@"height"] doubleValue] / 10000.0 : 0.14),
                @"a": @(1.0), @"key": @(key), @"label": text ?: @"",
            }];
        }
    }
    return out.count ? out : nil;
}

#pragma mark - 导出

+ (nullable id)exportControls:(NSArray<NSDictionary *> *)controls
                       format:(A2ControlLayoutFormat)format
                         name:(NSString *)name {
    if (format == A2ControlLayoutFormatA2) {
        return @{ @"format": @"a2", @"name": name ?: @"布局", @"controls": controls ?: @[] };
    }
    if (format == A2ControlLayoutFormatFCL) {
        NSMutableArray *buttons = [NSMutableArray array];
        for (NSDictionary *c in controls) {
            [buttons addObject:@{
                @"id": c[@"id"] ?: @"",
                @"text": c[@"label"] ?: @"",
                @"baseInfo": @{
                    @"xPosition": @([c[@"x"] doubleValue] * 1000.0),
                    @"yPosition": @([c[@"y"] doubleValue] * 1000.0),
                    @"percentageWidth": @{ @"reference": @"SCREEN_WIDTH",
                                           @"size": @([c[@"w"] doubleValue] * 1000.0) },
                    @"percentageHeight": @{ @"reference": @"SCREEN_HEIGHT",
                                            @"size": @([c[@"h"] doubleValue] * 1000.0) },
                },
                @"event": @{ @"pressEvent": @{ @"outputKeycodes": @[ c[@"key"] ?: @0 ] } },
            }];
        }
        return @{ @"controllerVersion": @1, @"viewGroups": @[
                      @{ @"id": @"main", @"name": @"main",
                         @"viewData": @{ @"buttonList": buttons, @"directionList": @[] } } ] };
    }
    // ZL2
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *c in controls) {
        [buttons addObject:@{
            @"uuid": c[@"id"] ?: @"",
            @"text": @{ @"default": c[@"label"] ?: @"" },
            @"position": @{ @"x": @([c[@"x"] doubleValue] * 10000.0),
                            @"y": @([c[@"y"] doubleValue] * 10000.0) },
            @"buttonSize": @{ @"width": @([c[@"w"] doubleValue] * 10000.0),
                              @"height": @([c[@"h"] doubleValue] * 10000.0) },
            @"clickEvents": @[ @{ @"keycode": c[@"key"] ?: @0 } ],
        }];
    }
    return @{ @"editorVersion": @1,
              @"info": @{ @"name": @{ @"default": name ?: @"布局" } },
              @"layers": @[ @{ @"name": @"main", @"uuid": @"main", @"normalButtons": buttons } ] };
}

@end
