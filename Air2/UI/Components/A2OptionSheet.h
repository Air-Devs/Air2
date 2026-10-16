//
//  A2OptionSheet.h
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
//  自研 MD3 选项弹窗 —— 二级选择界面的统一形态。
//
//  布局（横屏居中卡片）：
//    ┌────────────────────────────────┐
//    │            标题                 │
//    │        可选说明（居中）           │
//    │  ┌──────────────────────────┐  │
//    │  │ 选项 A                  ✓ │  │   一组行拼成一张卡（A2SettingsSection）
//    │  │ 选项 B                    │  │   行间距 2，首/末行 28 圆角
//    │  ├──────────────────────────┤  │
//    │  │ 选项 C                    │  │
//    │  └──────────────────────────┘  │
//    ├────────────────────────────────┤
//    │           [ 取消 ]              │
//    └────────────────────────────────┘
//
//  为什么自研：两件事都做不到 ——
//    ① 系统 UIAlertController 的 ActionSheet 用系统半透明材质（玻璃）、
//       不跟随本应用主题与材料包，横屏下与 MD3 界面割裂；
//    ② 它在 iPad 上必须锚定 popover 源视图，否则直接抛异常。
//  MD3 的「单选列表」应当是实心 surface + 语义色 + 弹簧入场，
//  所以这里做成自绘弹窗，与仓内既有的自绘弹窗（输入 / 配色主题）同一套外壳口径。
//
//  组件复用：选项行复用 A2SettingsSection + A2SettingsRow（含选中勾配件），
//  本题不新建列表控件。见 docs/DECISIONS.md ADR-010。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2OptionSheet : UIViewController

/// 创建一个选项弹窗（标题 / 说明都可为空）
+ (instancetype)sheetWithTitle:(nullable NSString *)title
                       message:(nullable NSString *)message;

/// 追加一个选项。selected = YES 时该行右侧显示 MD3 选中勾；
/// destructive = YES 时标题用语义色 error（移除/删除这类不可逆操作）。
/// handler 在弹窗关闭【之后】回调 —— 这样 handler 里再弹别的弹窗不会撞上这场转场。
- (void)addOptionWithTitle:(NSString *)title
                  selected:(BOOL)selected
               destructive:(BOOL)destructive
                   handler:(nullable void (^)(void))handler;

/// 呈现（自绘居中卡片，不依赖 popover，iPad 上同样成立）
- (void)presentFrom:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
