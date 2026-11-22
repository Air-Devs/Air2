//
//  control_layout_io_tests.m
//  Air2 —— tests/Natives：★控件布局多格式导入的字段与键码换算★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（直接链接真实实现，不是文本镜像）：
//    Natives/Input/A2ControlLayoutIO.m  ← detectFormat / A2·FCL·ZL2 解析 / A2 导出
//    Natives/Input/A2KeyCodeMap.m       ← evdev→GLFW、字符串键名→GLFW
//
//  为什么要有它：
//    FCL 的键码是 Linux evdev（KEY_W = 17），ZL2 的键码是字符串名
//    （"GLFW_KEY_W"）。直接透传会按到完全无关的键；尺寸与位置也不是
//    「归一化中心点」。这些是行为问题，只有把真实实现跑一遍才能证明。
//
//  运行：python3 tests/Natives/run_control_layout_io_tests.py
//        （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>
#import <math.h>

#import "A2ControlLayoutIO.h"
#import "A2KeyCodeMap.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

static void eqNum(NSNumber *got, double want, NSString *what) {
    BOOL same = [got isKindOfClass:NSNumber.class] && fabs(got.doubleValue - want) < 1e-9;
    ok(same, [NSString stringWithFormat:@"%@（得到 %@，期望 %.6f）", what, got, want]);
}

static void eqInt(NSNumber *got, NSInteger want, NSString *what) {
    BOOL same = [got isKindOfClass:NSNumber.class] && got.integerValue == want;
    ok(same, [NSString stringWithFormat:@"%@（得到 %@，期望 %ld）", what, got, (long) want]);
}

static NSDictionary *FindByID(NSArray<NSDictionary *> *controls, NSString *cid) {
    for (NSDictionary *control in controls) {
        if ([control[@"id"] isEqualToString:cid]) return control;
    }
    return nil;
}

#pragma mark - 键码表

static void TestKeyCodeMap(void) {
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_KEY_W"]), 87, @"ZL2 风格键名 GLFW_KEY_W");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"KEY_W"]), 87, @"FCL 风格常量名 KEY_W");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"W"]), 87, @"裸键名 W");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"87"]), 87, @"数字字符串键码");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_KEY_LEFT_SHIFT"]), 340, @"GLFW_KEY_LEFT_SHIFT");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_MOUSE_BUTTON_LEFT"]), -1, @"鼠标左键");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_MOUSE_BUTTON_RIGHT"]), -2, @"鼠标右键");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_MOUSE_BUTTON_MIDDLE"]), -3, @"鼠标中键");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@"GLFW_MOUSE_BUTTON_4"]), 0, @"不支持的鼠标键");
    eqInt(@([A2KeyCodeMap keyCodeFromName:@""]), 0, @"空键名");

    eqInt(@([A2KeyCodeMap keyCodeFromFCLKeycode:17]), 87, @"evdev 17 → GLFW W");
    eqInt(@([A2KeyCodeMap keyCodeFromFCLKeycode:1]), 256, @"evdev 1 → GLFW Escape");
    eqInt(@([A2KeyCodeMap keyCodeFromFCLKeycode:42]), 340, @"evdev 42 → GLFW 左 Shift");
    eqInt(@([A2KeyCodeMap keyCodeFromFCLKeycode:9999]), 0, @"未知 evdev");
    eqInt(@([A2KeyCodeMap fclKeycodeFromKeyCode:87]), 17, @"GLFW W → evdev 17");
    eqInt(@([A2KeyCodeMap fclKeycodeFromKeyCode:9999]), 0, @"未知 GLFW 键码");
}

#pragma mark - 格式识别

static void TestDetectFormat(void) {
    ok([A2ControlLayoutIO detectFormat:@{ @"controls": @[] }] == A2ControlLayoutFormatA2,
       @"controls → A2");
    ok([A2ControlLayoutIO detectFormat:@{ @"viewGroups": @[] }] == A2ControlLayoutFormatFCL,
       @"viewGroups → FCL");
    ok([A2ControlLayoutIO detectFormat:@{ @"controllerVersion": @2 }] == A2ControlLayoutFormatFCL,
       @"controllerVersion → FCL");
    ok([A2ControlLayoutIO detectFormat:@{ @"layers": @[] }] == A2ControlLayoutFormatZL2,
       @"layers → ZL2");
    ok([A2ControlLayoutIO detectFormat:@[]] == A2ControlLayoutFormatA2,
       @"非字典回落 A2");
}

#pragma mark - A2

static void TestA2RoundTrip(void) {
    NSArray<NSDictionary *> *controls = @[
        @{ @"id": @"w", @"x": @0.1, @"y": @0.2, @"w": @0.05, @"h": @0.1,
           @"a": @1, @"key": @87, @"label": @"W" },
    ];
    id exported = [A2ControlLayoutIO exportControls:controls
                                            format:A2ControlLayoutFormatA2
                                              name:@"测试"];
    ok([exported isKindOfClass:NSDictionary.class], @"A2 导出返回对象");
    eqStr(exported[@"format"], @"a2", @"A2 导出带 format 标记");
    ok([exported[@"controls"] count] == 1, @"A2 导出保留控件数");

    NSArray<NSDictionary *> *parsed = [A2ControlLayoutIO parseJSON:exported
                                                            format:A2ControlLayoutFormatA2];
    ok(parsed.count == 1, @"A2 导出再解析回来仍是 1 项");
    eqStr(parsed.firstObject[@"id"], @"w", @"A2 往返保留 id");
    eqNum(parsed.firstObject[@"x"], 0.1, @"A2 往返保留 x");

    // 序列化成 JSON 再回来，证明导出的都是 JSON 可序列化类型。
    NSData *data = [NSJSONSerialization dataWithJSONObject:exported options:0 error:NULL];
    ok(data.length > 0, @"A2 导出可被 JSON 序列化");
    id roundTripped = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    ok([[A2ControlLayoutIO parseJSON:roundTripped format:A2ControlLayoutFormatA2] count] == 1,
       @"A2 JSON 往返后仍能解析");
}

static void TestA2RejectsGarbage(void) {
    ok([A2ControlLayoutIO parseJSON:nil format:A2ControlLayoutFormatA2] == nil,
       @"nil 输入 → nil");
    ok([A2ControlLayoutIO parseJSON:@{ @"controls": @"nope" } format:A2ControlLayoutFormatA2] == nil,
       @"controls 不是数组 → nil");
    ok([A2ControlLayoutIO parseJSON:@{ @"controls": @[ @{ @"x": @0 } ] }
                             format:A2ControlLayoutFormatA2] == nil,
       @"缺少 id/尺寸的控件被过滤，空表 → nil");
}

#pragma mark - FCL

static NSDictionary *FCLLayout(void) {
    return @{
        @"controllerVersion": @2,
        @"viewGroups": @[
            @{
                @"id": @"main",
                @"name": @"main",
                @"viewData": @{
                    @"buttonList": @[
                        @{
                            @"id": @"attack",
                            @"text": @"攻击",
                            @"baseInfo": @{
                                @"xPosition": @500,
                                @"yPosition": @250,
                                @"sizeType": @"PERCENTAGE",
                                @"absoluteWidth": @50,
                                @"absoluteHeight": @50,
                                @"percentageWidth": @{ @"reference": @"SCREEN_WIDTH",
                                                       @"size": @200 },
                                @"percentageHeight": @{ @"reference": @"SCREEN_HEIGHT",
                                                        @"size": @150 },
                            },
                            @"event": @{
                                @"pressEvent": @{ @"outputKeycodes": @[ @17 ] },
                                @"clickEvent": @{ @"outputKeycodes": @[] },
                            },
                        },
                        @{
                            @"id": @"abs",
                            @"text": @"abs",
                            @"baseInfo": @{
                                @"xPosition": @0,
                                @"yPosition": @0,
                                @"sizeType": @"ABSOLUTE",
                                @"absoluteWidth": @100,
                                @"absoluteHeight": @50,
                                @"percentageWidth": @{},
                                @"percentageHeight": @{},
                            },
                            @"event": @{
                                @"pressEvent": @{ @"outputKeycodes": @[] },
                                // pressEvent 为空时回落到 clickEvent；evdev 1=Escape，30=A
                                @"clickEvent": @{ @"outputKeycodes": @[ @1, @30 ] },
                            },
                        },
                    ],
                    @"directionList": @[
                        @{
                            @"id": @"pad",
                            @"baseInfo": @{
                                @"xPosition": @0,
                                @"yPosition": @500,
                                @"sizeType": @"PERCENTAGE",
                                @"percentageWidth": @{ @"reference": @"SCREEN_HEIGHT",
                                                       @"size": @400 },
                                @"percentageHeight": @{ @"reference": @"SCREEN_HEIGHT",
                                                        @"size": @400 },
                            },
                            @"event": @{
                                @"upKeycode": @[ @17 ],
                                @"downKeycode": @[ @31 ],
                                @"leftKeycode": @[ @30 ],
                                @"rightKeycode": @[ @32 ],
                                @"sneak": @YES,
                                @"sneakKeycode": @42,
                            },
                        },
                    ],
                },
            },
        ],
    };
}

static void TestFCLLayout(void) {
    NSDictionary *json = FCLLayout();
    ok([A2ControlLayoutIO detectFormat:json] == A2ControlLayoutFormatFCL, @"FCL 被识别");

    NSArray<NSDictionary *> *controls = [A2ControlLayoutIO parseJSON:json
                                                              format:A2ControlLayoutFormatFCL];
    ok(controls.count == 7, @"FCL 解析出 2 按钮 + 4 方向 + 1 潜行 = 7 项");

    NSDictionary *attack = FindByID(controls, @"attack");
    ok(attack != nil, @"FCL 按钮 id 保留");
    eqInt(attack[@"key"], 87, @"FCL evdev 17 换算成 GLFW W");
    ok([attack[@"keys"] isEqualToArray:@[ @87 ]], @"FCL keys 也完成换算");
    eqStr(attack[@"label"], @"攻击", @"FCL text → label");
    eqNum(attack[@"w"], 0.20, @"FCL 千分比宽 200 → 0.20");
    eqNum(attack[@"h"], 0.15, @"FCL 千分比高 150 → 0.15");
    eqNum(attack[@"x"], 0.50, @"FCL 中心 x（无偏移）");
    eqNum(attack[@"y"], 0.2875, @"FCL 中心 y = 0.25 + 0.15 × 0.25");
    eqNum(attack[@"wPct"], 2000, @"FCL 精确宽 2000");
    eqStr(attack[@"wRef"], @"w", @"FCL 宽参考屏幕宽");
    eqNum(attack[@"hPct"], 1500, @"FCL 精确高 1500");
    eqStr(attack[@"hRef"], @"h", @"FCL 高参考屏幕高");
    eqNum(attack[@"xPct"], 5000, @"FCL 原始 xPosition 保留");
    eqNum(attack[@"yPct"], 2500, @"FCL 原始 yPosition 保留");

    NSDictionary *abs = FindByID(controls, @"abs");
    ok(abs != nil, @"FCL 绝对尺寸按钮存在");
    eqNum(abs[@"wPt"], 100, @"FCL 绝对宽 → wPt");
    eqNum(abs[@"hPt"], 50, @"FCL 绝对高 → hPt");
    eqNum(abs[@"w"], 100.0 / 844.0, @"FCL 绝对宽折算名义比例");
    eqNum(abs[@"h"], 50.0 / 390.0, @"FCL 绝对高折算名义比例");
    eqInt(abs[@"key"], 256, @"pressEvent 为空时取 clickEvent 首个键");
    ok([abs[@"keys"] isEqualToArray:@[ @256, @65 ]], @"多键事件全部换算成 GLFW");

    NSDictionary *up = FindByID(controls, @"pad-up");
    ok(up != nil, @"FCL 方向盘导出 up");
    eqStr(up[@"role"], @"up", @"up 带 role");
    eqInt(up[@"key"], 87, @"up 键换算成 W");
    eqNum(up[@"x"], 78.0 / 844.0, @"up 中心 x = 盘面中心");
    eqNum(up[@"y"], 145.08 / 390.0, @"up 中心 y = 上偏 18%");

    NSDictionary *down = FindByID(controls, @"pad-down");
    eqInt(down[@"key"], 83, @"down 键 evdev 31 → S");
    NSDictionary *left = FindByID(controls, @"pad-left");
    eqInt(left[@"key"], 65, @"left 键 evdev 30 → A");
    NSDictionary *right = FindByID(controls, @"pad-right");
    eqInt(right[@"key"], 68, @"right 键 evdev 32 → D");

    NSDictionary *sneak = FindByID(controls, @"pad-sneak");
    ok(sneak != nil, @"sneak 开启时导出潜行键");
    eqInt(sneak[@"key"], 340, @"sneak 键 evdev 42 → 左 Shift");
    eqNum(sneak[@"x"], 78.0 / 844.0, @"sneak 在盘面中心 x");
    eqNum(sneak[@"y"], 195.0 / 390.0, @"sneak 在盘面中心 y");
}

static void TestFCLUnknownKeycode(void) {
    NSDictionary *json = @{
        @"viewGroups": @[
            @{ @"id": @"g", @"viewData": @{
                   @"buttonList": @[
                       @{ @"id": @"weird", @"text": @"?",
                          @"baseInfo": @{ @"xPosition": @500, @"yPosition": @500,
                                          @"sizeType": @"PERCENTAGE",
                                          @"percentageWidth": @{ @"size": @100 },
                                          @"percentageHeight": @{ @"size": @100 } },
                          @"event": @{ @"pressEvent": @{ @"outputKeycodes": @[ @9999 ] } } },
                   ],
                   @"directionList": @[] } },
        ],
    };
    NSArray<NSDictionary *> *controls = [A2ControlLayoutIO parseJSON:json
                                                              format:A2ControlLayoutFormatFCL];
    ok(controls.count == 1, @"未知键码仍保留控件");
    eqInt(controls.firstObject[@"key"], 0, @"未知 evdev 不猜键，key = 0");
    ok([controls.firstObject[@"keys"] count] == 0, @"未知 evdev 不进 keys");
}

#pragma mark - ZL2

static NSDictionary *ZL2Layout(void) {
    return @{
        @"editorVersion": @1,
        @"info": @{ @"name": @{ @"default": @"测试" } },
        @"layers": @[
            @{
                @"name": @"main",
                @"uuid": @"layer-1",
                @"normalButtons": @[
                    @{
                        @"uuid": @"btn-w",
                        @"text": @{ @"default": @"W" },
                        @"position": @{ @"x": @5000, @"y": @2500 },
                        @"buttonSize": @{
                            @"type": @"percentage",
                            @"widthDp": @50, @"heightDp": @50,
                            @"widthPercentage": @1400,
                            @"heightPercentage": @1200,
                            @"widthReference": @"screen_height",
                            @"heightReference": @"screen_height",
                        },
                        @"clickEvents": @[ @{ @"type": @"key", @"key": @"GLFW_KEY_W" } ],
                    },
                    @{
                        @"uuid": @"btn-dp",
                        @"text": @{ @"default": @"组合" },
                        @"position": @{ @"x": @0, @"y": @0 },
                        @"buttonSize": @{
                            @"type": @"dp",
                            @"widthDp": @60, @"heightDp": @40,
                            @"widthPercentage": @100,
                            @"heightPercentage": @100,
                            @"widthReference": @"screen_width",
                            @"heightReference": @"screen_width",
                        },
                        @"clickEvents": @[
                            @{ @"type": @"key", @"key": @"GLFW_KEY_LEFT_CONTROL" },
                            @{ @"type": @"key", @"key": @"GLFW_KEY_C" },
                            @{ @"type": @"launcher_event", @"key": @"launcher_event_switch_ime" },
                        ],
                    },
                    @{
                        @"uuid": @"btn-mouse",
                        @"text": @{ @"default": @"鼠标" },
                        @"position": @{ @"x": @0, @"y": @0 },
                        @"buttonSize": @{
                            @"type": @"wrap_content",
                            @"widthDp": @5, @"heightDp": @5,
                            @"widthPercentage": @100,
                            @"heightPercentage": @100,
                            @"widthReference": @"screen_width",
                            @"heightReference": @"screen_width",
                        },
                        @"clickEvents": @[ @{ @"type": @"key",
                                              @"key": @"GLFW_MOUSE_BUTTON_LEFT" } ],
                    },
                ],
            },
        ],
    };
}

static void TestZL2Layout(void) {
    NSDictionary *json = ZL2Layout();
    ok([A2ControlLayoutIO detectFormat:json] == A2ControlLayoutFormatZL2, @"ZL2 被识别");

    NSArray<NSDictionary *> *controls = [A2ControlLayoutIO parseJSON:json
                                                              format:A2ControlLayoutFormatZL2];
    ok(controls.count == 3, @"ZL2 解析出 3 项");

    NSDictionary *w = FindByID(controls, @"btn-w");
    ok(w != nil, @"ZL2 uuid 保留为 id");
    eqInt(w[@"key"], 87, @"ZL2 字符串键名 GLFW_KEY_W → 87");
    eqStr(w[@"label"], @"W", @"ZL2 text.default → label");
    eqNum(w[@"wPct"], 1400, @"ZL2 百分比宽 1400");
    eqStr(w[@"wRef"], @"h", @"ZL2 宽参考屏幕高");
    eqNum(w[@"w"], (390.0 / 844.0) * 0.14, @"ZL2 参考屏幕高的宽折算名义比例");
    eqNum(w[@"hPct"], 1200, @"ZL2 百分比高 1200");
    eqStr(w[@"hRef"], @"h", @"ZL2 高参考屏幕高");
    eqNum(w[@"h"], 0.12, @"ZL2 参考屏幕高的高比例");
    eqNum(w[@"x"], 0.50, @"ZL2 中心 x（pos 5000）");
    eqNum(w[@"y"], 0.28, @"ZL2 中心 y = 0.25 + 0.12 × 0.25");

    NSDictionary *dp = FindByID(controls, @"btn-dp");
    eqNum(dp[@"wPt"], 60, @"ZL2 dp 宽 → wPt");
    eqNum(dp[@"hPt"], 40, @"ZL2 dp 高 → hPt");
    eqNum(dp[@"w"], 60.0 / 844.0, @"ZL2 dp 宽折算名义比例");
    eqNum(dp[@"h"], 40.0 / 390.0, @"ZL2 dp 高折算名义比例");
    eqInt(dp[@"key"], 341, @"组合键取首个键");
    ok([dp[@"keys"] isEqualToArray:@[ @341, @67 ]], @"ZL2 组合键全部保留，launcher_event 被忽略");

    NSDictionary *mouse = FindByID(controls, @"btn-mouse");
    eqInt(mouse[@"key"], -1, @"ZL2 鼠标键 → -1");
    ok([mouse[@"wrap"] boolValue], @"ZL2 wrap_content 标记 wrap");
}

static void TestZL2RejectsGarbage(void) {
    ok([A2ControlLayoutIO parseJSON:@{} format:A2ControlLayoutFormatZL2] == nil,
       @"无 layers → nil");
    ok([A2ControlLayoutIO parseJSON:@{ @"layers": @[ @{} ] }
                             format:A2ControlLayoutFormatZL2] == nil,
       @"空 layers → nil");
    ok([A2ControlLayoutIO parseJSON:@{ @"viewGroups": @"nope" }
                             format:A2ControlLayoutFormatFCL] == nil,
       @"viewGroups 不是数组 → nil");
}

#pragma mark - 导出边界

static void TestExportBoundaries(void) {
    NSArray *controls = @[ @{ @"id": @"w" } ];
    ok([A2ControlLayoutIO exportControls:controls
                                  format:A2ControlLayoutFormatFCL
                                    name:@"x"] == nil,
       @"FCL 导出暂不产出半合法文件");
    ok([A2ControlLayoutIO exportControls:controls
                                  format:A2ControlLayoutFormatZL2
                                    name:@"x"] == nil,
       @"ZL2 导出暂不产出半合法文件");
    id exported = [A2ControlLayoutIO exportControls:@[]
                                            format:A2ControlLayoutFormatA2
                                              name:@""];
    eqStr(exported[@"name"], @"布局", @"空名字回落默认名");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        TestKeyCodeMap();
        TestDetectFormat();
        TestA2RoundTrip();
        TestA2RejectsGarbage();
        TestFCLLayout();
        TestFCLUnknownKeycode();
        TestZL2Layout();
        TestZL2RejectsGarbage();
        TestExportBoundaries();

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
