//
//  A2ControlLayout.h
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
//  A2ControlLayout.h
//  Air2
//
//  控件系统的数据模型 —— **直接兼容 FCL / ZL2 / Air1 三家的原生格式**。
//
//  ## 为什么不做格式转换
//
//  FCL 官方做过一个 control-converter（FCL↔ZL2 双向），
//  但那是给「用户从别的启动器迁移」用的。
//  用户的要求是：**同一份布局文件在三个启动器里都能直接用**，不做转换。
//
//  三家格式实际上高度重合（都是从同一个 Android 方案演化来的）：
//
//    ZL2:  { "editorVersion": 12, "layers": [ ... ] }
//    FCL:  { "controllerVersion": 3, "viewGroups": [ ... ] }
//    Air1: 同 Android 结构（ControlButton.h 注释里写明）
//
//  按钮字段的取名差异很小：
//
//    共有：uuid, text, position, size/buttonSize, clickEvents,
//          isSwipple, isPenetrable, isToggleable
//    差异：ZL2 用 buttonSize，FCL 用 size + sizeType
//          ZL2 用 visibilityType，FCL 用 visibilityType
//          ZL2 的坐标是 {x, y} 百分比，FCL 是 {percentageX, percentageY}
//
//  所以做法是：**解析时容忍两种字段名**，写入时保留原有格式。
//  这样加载任意一家的文件都不会失败，保存时也不破坏原格式。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 控件类型

typedef NS_ENUM(NSInteger, A2ControlWidgetType) {
    A2ControlWidgetTypeButton = 0,   ///< 普通按钮（normalButtons）
    A2ControlWidgetTypeJoystick,     ///< 摇杆（joystickButtons）
    A2ControlWidgetTypeTextBox,      ///< 文本输入（textBoxes）
};

#pragma mark - 点击事件

typedef NS_ENUM(NSInteger, A2ControlEventType) {
    A2ControlEventTypeSendKey = 0,     ///< 发送按键
    A2ControlEventTypeSendText,        ///< 发送文本
    A2ControlEventTypeMouseWheel,      ///< 鼠标滚轮
    A2ControlEventTypeMouseMove,       ///< 鼠标移动
    A2ControlEventTypeToggleGui,       ///< 切换 GUI
    A2ControlEventTypeToggleKeyboard,  ///< 切换键盘
    A2ControlEventTypeSwitchMouse,     ///< 切换鼠标模式
    A2ControlEventTypeUnknown,
};

/// 一条点击事件
@interface A2ControlEvent : NSObject
@property (nonatomic, assign) A2ControlEventType type;
/// 按键码（SendKey）或文本（SendText）
@property (nonatomic, copy, nullable) NSString *key;
/// 原始类型名（保留未知类型，写回时原样输出）
@property (nonatomic, copy, nullable) NSString *rawType;
+ (instancetype)eventFromJSON:(NSDictionary *)json;
- (NSDictionary *)toJSON;
@end

#pragma mark - 控件

/// 一个控件（按钮 / 摇杆 / 文本框）
@interface A2ControlWidget : NSObject

@property (nonatomic, assign) A2ControlWidgetType type;
@property (nonatomic, copy) NSString *identifier;

/// 显示文字。三家格式可能给字符串或 {"zh": "…"} 字典
@property (nonatomic, copy, nullable) NSString *text;

/// 位置与尺寸（百分比，0~100）。
/// 这是三家唯一需要兼容的关键差异：
///   ZL2 / FCL 新版：position {x, y}  + buttonSize {width, height}
///   FCL 老版：     position {percentageX, percentageY}
@property (nonatomic, assign) CGFloat xPercent;
@property (nonatomic, assign) CGFloat yPercent;
@property (nonatomic, assign) CGFloat widthPercent;
@property (nonatomic, assign) CGFloat heightPercent;

/// 尺寸模式：百分比 / 固定点值
@property (nonatomic, copy, nullable) NSString *sizeType;

/// 样式 ID（引用 buttonStyles 里的条目）
@property (nonatomic, copy, nullable) NSString *buttonStyle;

/// 行为标志
@property (nonatomic, assign) BOOL isSwipple;      ///< 可与周围按钮联动
@property (nonatomic, assign) BOOL isPenetrable;   ///< 允许触摸穿透
@property (nonatomic, assign) BOOL isToggleable;   ///< 开关式切换

/// 可见性：always / hide-when-gamepad / ...
@property (nonatomic, copy) NSString *visibilityType;

/// 点击事件
@property (nonatomic, copy) NSArray<A2ControlEvent *> *clickEvents;

/// **保留原始 JSON**，保存时以它为基础只改有变动的字段 ——
/// 这样不会丢掉我们还不认识的字段（三家天天在加新字段）。
@property (nonatomic, copy, nullable) NSDictionary *rawJSON;

/// 从任意一家的 JSON 解析。返回 nil 表示这条记录不是有效控件。
+ (nullable instancetype)widgetFromJSON:(NSDictionary *)json
                                   type:(A2ControlWidgetType)type;

/// 写回 JSON（以 rawJSON 为底，覆盖已知字段）
- (NSDictionary *)toJSON;

@end

#pragma mark - 布局

/// 一份控件布局
@interface A2ControlLayout : NSObject

/// 来源格式，仅用于诊断
@property (nonatomic, copy, readonly) NSString *sourceFormat;   // "zl2" / "fcl" / "air1"

/// ZL2 的 editorVersion 或 FCL 的 controllerVersion
@property (nonatomic, assign) NSInteger version;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *author;

/// 全部控件（扁平化，忽略层级 —— 渲染时再说）
@property (nonatomic, copy) NSMutableArray<A2ControlWidget *> *widgets;

/// 样式表：ID → 原始 JSON
@property (nonatomic, copy) NSMutableDictionary<NSString *, NSDictionary *> *buttonStyles;

/// 摇杆样式
@property (nonatomic, copy) NSMutableDictionary<NSString *, NSDictionary *> *joystickStyles;

/// **原始根 JSON** —— 保存时以此为基础
@property (nonatomic, copy, nullable) NSDictionary *rawRoot;

+ (nullable instancetype)layoutFromJSON:(NSDictionary *)json error:(NSError **)error;
+ (nullable instancetype)layoutFromFile:(NSString *)path error:(NSError **)error;

/// 写回文件（保留原格式）
- (BOOL)writeToFile:(NSString *)path error:(NSError **)error;

/// 新建一份默认布局（我们的默认控件）
+ (instancetype)defaultLayoutForScreen:(CGSize)screenSize;

@end

NS_ASSUME_NONNULL_END
