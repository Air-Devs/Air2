//
//  A2ControlsEditorViewController.h
//  Air2
//
//  控件布局编辑器（在「设置」里编辑，不在游戏内）。
//
//  用户要求（2026-10-23）：
//    · 编辑入口必须在设置里，游戏里不要放 ⚙（否则关掉窗口后编辑态还留着、点一下就要绑键）
//    · 位置/大小/透明度、多套方案、导入导出，全部在这里做
//
//  实现：一块固定比例（16:9）的深色画布，上面直接放一个 A2GameControlsView，
//  以 editing=YES 启动；保存/取消后关闭。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ControlsEditorViewController : UIViewController

+ (instancetype)editor;

@end

NS_ASSUME_NONNULL_END
