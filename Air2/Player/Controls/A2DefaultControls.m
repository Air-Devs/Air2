//
//  A2DefaultControls.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2DefaultControls.m
//  Air2
//

#import "A2DefaultControls.h"

/// LWJGL GLFW 键码（与 input_bridge_v3.m 里的映射一致）
static NSString *const kKeyW = @"87";
static NSString *const kKeyA = @"65";
static NSString *const kKeyS = @"83";
static NSString *const kKeyD = @"68";
static NSString *const kKeySpace = @"32";
static NSString *const kKeyShift = @"340";
static NSString *const kKeyCtrl = @"341";
static NSString *const kKeyE = @"69";
static NSString *const kKeyEsc = @"256";
static NSString *const kKeyF1 = @"290";
static NSString *const kKeyMouseLeft = @"0";
static NSString *const kKeyMouseRight = @"1";

@implementation A2DefaultControls

/// 造一个按钮控件
static A2ControlWidget *Btn(NSString *ident, NSString *text,
                            CGFloat x, CGFloat y, CGFloat size,
                            NSString *keyCode) {
    A2ControlWidget *w = [A2ControlWidget new];
    w.type = A2ControlWidgetTypeButton;
    w.identifier = ident;
    w.text = text;
    w.xPercent = x;
    w.yPercent = y;
    w.widthPercent = size * 0.9;    // 竖屏下按高度算，这里给个近似
    w.heightPercent = size;
    w.buttonStyle = @"default";
    w.isSwipple = YES;
    w.isPenetrable = NO;
    w.isToggleable = NO;
    w.visibilityType = @"always";

    if (keyCode.length) {
        A2ControlEvent *e = [A2ControlEvent new];
        e.type = A2ControlEventTypeSendKey;
        e.key = keyCode;
        w.clickEvents = @[e];
    }
    return w;
}

+ (A2ControlLayout *)makeLayout {
    A2ControlLayout *layout = [A2ControlLayout defaultLayoutForScreen:CGSizeZero];
    layout.name = @"默认布局";
    layout.author = @"Air2";

    NSMutableArray *ws = [NSMutableArray array];

    // ============ 左侧：摇杆 + 快捷菜单 ============
    A2ControlWidget *joystick = [A2ControlWidget new];
    joystick.type = A2ControlWidgetTypeJoystick;
    joystick.identifier = @"air2.joystick";
    joystick.text = @"";
    joystick.xPercent = 6;
    joystick.yPercent = 58;
    joystick.widthPercent = 22;
    joystick.heightPercent = 30;
    joystick.visibilityType = @"always";
    [ws addObject:joystick];

    // 摇杆外圈的四个方向键（三家默认都有，方便精确移动）
    [ws addObject:Btn(@"air2.w",    @"", 22, 52,  8, kKeyW)];
    [ws addObject:Btn(@"air2.a",    @"",  6, 66,  8, kKeyA)];
    [ws addObject:Btn(@"air2.s",    @"", 22, 80,  8, kKeyS)];
    [ws addObject:Btn(@"air2.d",    @"", 38, 66,  8, kKeyD)];

    [ws addObject:Btn(@"air2.esc",   @"≡",  4,  8,  9, kKeyEsc)];
    [ws addObject:Btn(@"air2.shift", @"潜行", 4, 26, 10, kKeyShift)];

    // ============ 右侧：战斗与交互 ============
    [ws addObject:Btn(@"air2.jump",   @"跳",  86, 76, 13, kKeySpace)];
    [ws addObject:Btn(@"air2.attack", @"攻",  72, 86, 12, kKeyMouseLeft)];
    [ws addObject:Btn(@"air2.use",    @"用",  88, 90, 12, kKeyMouseRight)];

    [ws addObject:Btn(@"air2.inv",    @"包",  86, 20, 10, kKeyE)];
    [ws addObject:Btn(@"air2.sneak",  @"蹲",  70, 72, 10, kKeyCtrl)];

    // ============ 顶部：快捷栏 ============
    for (int i = 0; i < 9; i++) {
        NSString *label = [NSString stringWithFormat:@"%d", i + 1];
        NSString *key = [NSString stringWithFormat:@"%d", kKeyF1.intValue + i];
        [ws addObject:Btn([NSString stringWithFormat:@"air2.hotbar%d", i],
                          label,
                          24 + i * 5.8, 4, 6, key)];
    }

    layout.widgets = ws;

    // 默认样式
    layout.buttonStyles[@"default"] = @{
        @"id": @"default",
        @"color": @"#33FFFFFF",
        @"borderColor": @"#66FFFFFF",
        @"textColor": @"#FFFFFFFF",
        @"borderWidth": @1,
        @"alpha": @0.75,
    };

    return layout;
}

+ (BOOL)installDefaultLayoutToPath:(NSString *)path error:(NSError **)error {
    A2ControlLayout *layout = [self makeLayout];
    return [layout writeToFile:path error:error];
}

+ (BOOL)installIfNeededAtPath:(NSString *)path error:(NSError **)error {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    return [self installDefaultLayoutToPath:path error:error];
}

@end
