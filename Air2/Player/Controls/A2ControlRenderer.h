//
//  A2ControlRenderer.h
//  Air2
//
//  控件渲染层 —— 把 A2ControlLayout 画成可交互的视图。
//
//  ## 与数据层的关系
//
//    A2ControlLayout   只管「数据是什么」（兼容三家格式）
//    A2ControlRenderer 只管「怎么画、怎么响应触摸」
//
//  分开的理由：布局编辑器要读写数据但不一定需要渲染；
//  游戏内运行时只需要渲染，不需要理解 ZL2/FCL 的字段差异。
//
//  ## 触摸处理
//
//  控件必须把触摸事件转成 Minecraft 的输入。这依赖启动核心的
//  input_bridge（A2/Player/Input/input_bridge_v3.m），
//  所以渲染层只发「输入意图」，不直接调 JNI：
//
//    A2ControlInputDelegate
//      · pressKey:         按下/松开某个按键
//      · moveMouse:        鼠标移动（摇杆或拖动）
//      · toggleGui:        切换 GUI
//      · toggleKeyboard:   切换软键盘
//
//  这样渲染层可以脱离游戏单独预览（编辑器用得上）。
//

#import <UIKit/UIKit.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// 输入意图的接收方
@protocol A2ControlInputDelegate <NSObject>
- (void)controlPressKey:(NSString *)keyCode;
- (void)controlReleaseKey:(NSString *)keyCode;
- (void)controlMoveMouse:(CGPoint)delta;
- (void)controlToggleGui;
- (void)controlToggleKeyboard;
@end

/// 整个控件层的容器视图
/// 单个控件视图 —— 公开是因为 SurfaceViewController 的
/// executebtn: 系列方法需要它的类型签名。
@interface A2ControlButtonView : UIView
@property (nonatomic, strong) A2ControlWidget *widget;
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> inputDelegate;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign, getter=isOn) BOOL on;
- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

// ---- 兼容属性 ----
// SurfaceViewController 的 executebtn: 系列是从 Air1 沿用下来的，
// 它按 Air1 的 ControlButton 接口访问这些字段。这里补齐，
// 让那部分逻辑不用改（而且语义与 Air1 一致）。
//
// 为什么不反过来改成 widget.xxx：
//   那边有几十处访问，改一处漏一处就是编译错误；
//   而这里的实现只有几行 —— 把复杂度收敛在我们自己的类里。

/// 控件的原始属性字典（来自布局文件）。
/// 支持 properties[@"keycodes"][i] 这种 Air1 风格的访问。
@property (nonatomic, copy, readonly) NSDictionary *properties;

/// Toggleable 控件的开关态（Air1 的 isToggleOn 同名兼容）
@property (nonatomic, assign) BOOL isToggleOn;

/// 按下前的背景色，松开时恢复（兼容 Air1 的做法）
@property (nonatomic, strong, nullable) UIColor *savedBackgroundColor;

/// 显示文字（Air1 用 titleLabel.text）
@property (nonatomic, strong, readonly) UILabel *titleLabel;

@end

@interface A2ControlRenderer : UIView

@property (nonatomic, strong, readonly) A2ControlLayout *layout;
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> inputDelegate;

/// 是否处于编辑模式（编辑模式下控件可拖动、可选中）
@property (nonatomic, assign) BOOL editing;
/// 编辑模式下当前选中的控件
@property (nonatomic, strong, nullable) A2ControlWidget *selectedWidget;
/// 选中变化回调
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(A2ControlWidget * _Nullable);

- (instancetype)initWithLayout:(A2ControlLayout *)layout;

/// 重新构建视图（改动布局数据后调用）
- (void)reload;

/// 整体不透明度
@property (nonatomic, assign) CGFloat controlsOpacity;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
