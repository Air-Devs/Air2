//
//  A2GameMenuOverlay.h
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
//  A2GameMenuOverlay.h
//  Air2
//
//  游戏内悬浮球 + 功能面板。
//
//  ## 对照的 ZL2 实现
//
//    · 交互与生命周期
//        zl2/ZalithLauncher/.../ui/screens/game/elements/GameBall.kt
//        zl2/ZalithLauncher/.../ui/components/Draggabble.kt（FloatingBall）
//    · 展开后的功能集合
//        zl2/ZalithLauncher/.../ui/screens/game/elements/GameMenuSubscreen.kt
//
//  ## ZL2 的浮球行为（本类逐条对齐）
//
//    1. 全屏浮层，但只有浮球/统计文字/展开后的面板命中；
//       其余区域的 hitTest 返回 nil，触摸继续下发给游戏输入层。
//       命中后的触摸在浮层内被吞掉，不会沿响应链冒到
//       SurfaceViewController 的 touchesBegan 再送进游戏。
//    2. 只挂一个 UIPanGestureRecognizer：位移超过 6pt 才算拖动，
//       未超过算轻点（对应 Draggabble.kt 的 touchSlop + 松手判定）。
//       纯轻点（静止按下抬起）由视图触摸回调兜底，因为 UIPan 对
//       完全静止的触摸不会进入 Began/Ended。
//    3. 拖动时实时跟手，松手吸附到最近的左右边缘并回弹。
//    4. 轻点展开/收起功能面板；展开时浮球图标切换并轻微放大。
//    5. 位置、大小、不透明度、FPS/内存显隐持久化。
//       位置存归一化中心坐标（0~1），换方向/分辨率/设备都不丢。
//    6. 展开时铺一层透明遮罩吞掉全部触摸，避免点面板时误触游戏；
//       点遮罩空白处收起。
//    7. 每次 layout 都按当前安全区重新钳制位置（含旋转后），
//       FPS/内存文字跟着球在左半边/右半边自动换边。
//
//  ## 与旧版 A2GameMenuOverlay 的兼容性
//
//    对外 API 全部保留：delegate / expanded / expand / collapse / toggle /
//    visible / ballOpacity / gameLayer / onOpenEditor / applyTheme /
//    updateFPS:memoryUsageMB:。旧的 `long press → onOpenEditor` 行为也保留。
//    新增的只有可选的 delegate 方法 gameMenuReturnToLauncher 与若干外观属性；
//    宿主不改代码也能直接编译。
//
//  ## 持久化
//
//    Air2 的偏好机制 PLPreferences 只接受在 PLPreferences.m 里【预注册】的键
//    （setObject 对未知键只打日志、不落盘，见 PLPreferences.m:536）。而本任务
//    禁止改 Air2/Player/Context/，无法注册新键，因此这里按任务说明改用
//    NSUserDefaults。键：
//      · game.menu.ballPosition   "x,y" 归一化中心（0~1，逗号分隔）
//      · game.menu.ballDiameter   32~64
//      · game.menu.ballOpacity    0.2~1.0
//      · game.menu.ballShowsFPS   BOOL
//      · game.menu.ballShowsMemory BOOL
//    语义与 ZL2 的 Settings.setValue(..., saveToDisk) 一致。
//
//  ## 陶瓦联机
//
//    gameMenuOpenTerracotta 是【已有】能力入口（A2Multiplayer 核心已完整），
//    本类只负责在宿主实现了 delegate 时显示入口并转发，不重写联机逻辑。
//

#import <UIKit/UIKit.h>
#import "A2ResolutionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 菜单动作，由宿主实现
@protocol A2GameMenuDelegate <NSObject>
@optional
// —— 控制总览 ——
- (void)gameMenuOpenInputMethod;
- (void)gameMenuSendKeycode;
- (void)gameMenuToggleControls;
- (void)gameMenuEditLayout;
// —— 游戏操作 ——
- (void)gameMenuForceClose;
- (void)gameMenuToggleLog;
- (void)gameMenuOpenTerracotta;
- (void)gameMenuRefreshWindowSize;
// —— 显示选项 ——
- (void)gameMenuSetFPSDisplayMode:(NSInteger)mode;   // 0=关 1=总是 2=仅调试
- (void)gameMenuSetShowMemory:(BOOL)show;
- (void)gameMenuSetMaxRefreshRate:(NSInteger)hz;

/// 返回启动器（由宿主决定是重建 surface 还是退出游戏宿主进程）。
///
/// Air2 有 UIKit_returnToSplitView()，但它服务于 JVM 启动失败 / 退出路径的
/// 换根；游戏运行中直接调用不会终止进程内的 JVM，下一次启动会撞
/// 「JVM 已创建」。PLCrashView 的 dismissAndReturnToLauncher 在
/// PLLogOutputView 里也是空实现。因此这里只预留回调，真正的清理顺序
/// （终止 JVM / exit(0) / 重建根视图）由宿主决定；宿主不实现时菜单不显示
/// 这一项，不发明不存在的功能。
- (void)gameMenuReturnToLauncher;
@end

/// FPS 显示模式
typedef NS_ENUM(NSInteger, A2FPSDisplayMode) {
    A2FPSDisplayModeOff = 0,
    A2FPSDisplayModeAlways = 1,
    A2FPSDisplayModeDebugOnly = 2,
};

@interface A2GameMenuOverlay : UIView

@property (nonatomic, weak, nullable) id<A2GameMenuDelegate> delegate;

@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;
- (void)expand;
- (void)collapse;
- (void)toggle;

/// 浮球显隐
@property (nonatomic, assign) BOOL visible;
/// 浮球不透明度（0.2 ~ 1.0）
@property (nonatomic, assign) CGFloat ballOpacity;

/// 浮球直径（32 ~ 64，默认 44）。
/// 对应 ZL2 GameBall 的自适应尺寸：小屏用手势，大屏可以放大。
@property (nonatomic, assign) CGFloat ballDiameter;

/// 是否在球旁显示 FPS / 内存小字。
///
/// 默认都是 YES —— 与旧实现（收到非 0 数据就显示）保持一致；
/// 用户可在展开面板里单独关掉，关掉后若两者都关则整块小字隐藏。
@property (nonatomic, assign) BOOL showsFPS;
@property (nonatomic, assign) BOOL showsMemory;

/// 是否吸附在右边缘（只读，供宿主恢复 UI 时参考）
@property (nonatomic, assign, readonly) BOOL pinnedToRightEdge;

/// 游戏 surface —— 分辨率调整会作用到它
@property (nonatomic, weak, nullable) CALayer *gameLayer;

/// 长按浮球 → 打开控件编辑器（对照 ZL2 的 GameBall 长按）
@property (nonatomic, copy, nullable) void (^onOpenEditor)(void);

- (void)applyTheme;

/// 重新读取 NSUserDefaults 中的外观/位置（宿主从设置页返回时调用）。
- (void)reloadPreferences;

/// 把浮球复位到右上角（位置存坏时的逃生口）。
- (void)resetBallPosition;

/// 更新 FPS / 内存显示（悬浮球旁的小字）。
/// 对应 ZL2 的 FPS 与内存显示开关 —— 数据由 SurfaceViewController 的
/// statsTimer 每秒喂一次。
- (void)updateFPS:(double)fps memoryUsageMB:(double)memoryMB;

@end

NS_ASSUME_NONNULL_END
