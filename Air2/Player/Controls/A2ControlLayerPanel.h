//
//  A2ControlLayerPanel.h
//  Air2
//
//  图层面板 —— 对照 ZL2 的层管理（ControlLayer.kt / HideLayerWhen.kt）。
//
//  ## 层的概念
//
//  一个布局可以有多层，每层是一组控件。典型用法：
//
//    层「移动」  →  摇杆 + WASD（始终可见）
//    层「战斗」  →  攻击/潜行/跳跃（仅游戏内）
//    层「背包」  →  快捷栏（打开背包时显示）
//
//  层的可见性由三件事决定：
//    1. 用户手动切换（点「切换层」的控件）
//    2. 按游戏状态自动（in_game / in_menu）
//    3. 按设备状态自动（hideWhenGamepad / hideWhenMouse / hideWhenJoystick）
//
//  第 3 条是 ZL2 的 HideLayerWhen —— 接了手柄就隐藏触控层，
//  这是很实用的设计（否则两套输入打架）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ControlLayer;

typedef NS_ENUM(NSInteger, A2HideLayerWhen) {
    A2HideLayerWhenNever = 0,      ///< 始终显示
    A2HideLayerWhenGamepad,        ///< 接了手柄时隐藏
    A2HideLayerWhenMouse,          ///< 接了鼠标时隐藏
    A2HideLayerWhenJoystick,       ///< 接了手柄摇杆时隐藏
};

/// 给层加可见性规则（挂到 A2ControlLayer 的 rawJSON 里）
@interface A2ControlLayerRule : NSObject
@property (nonatomic, assign) A2HideLayerWhen hideWhen;
+ (instancetype)ruleFromJSON:(NSDictionary *)json;
- (NSDictionary *)toJSON;
@end

/// 图层面板（编辑器里的一个面板）
///
/// 交互（对照 ZL2 的 edit_layer/EditControlLayerDialog 与
/// control_editor/_Layout.kt 的层列表）：
///   · 点一层 = 选中（新控件加到这一层）
///   · 上/下箭头 = 调整前后顺序（renderer 的 z 序跟着变）
///   · 眼睛 = 显示/隐藏（对应 ZL2 的 layer.hide）
///   · 垃圾桶 = 删除（至少保留一层）
@interface A2ControlLayerPanel : UIView

/// 层列表变化时回调（顺序 / 可见性 / 增删）
@property (nonatomic, copy, nullable) void (^onLayersChanged)(void);

/// 选中某层
@property (nonatomic, copy, nullable) void (^onLayerSelected)(A2ControlLayer *layer);

/// 当前选中的层（nil 时用第一层）
@property (nonatomic, strong, nullable) A2ControlLayer *selectedLayer;

- (instancetype)initWithLayers:(NSMutableArray<A2ControlLayer *> *)layers;
- (void)reload;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
