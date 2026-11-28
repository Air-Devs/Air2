// ============================================================================
//  Natives/Input/A2VirtualButtonInputSource.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 虚拟按钮源（本迭代只给接口）
// ----------------------------------------------------------------------------
//  接口形状已经定死，[INPUT-MAP-2] 要做的只有两件事：
//    ① 把 A2GameControlsView 的按下/抬起改成调 -buttonWithIdentifier:action:
//       （控件的 id 就是布局模型里的 id：attack / forward / 自定义控件 id）；
//    ② 按布局里每个控件的 key 生成绑定（A2InputBindingTable 的虚拟按钮段）。
//
//  ★为什么现在就把 id 口径定下来★
//    控件的「键」是用户可改的，id 不是。用 id 当触发，改绑只改绑定表；
//    用键码当触发，改绑就等于换了一个控件 —— 用户看到的会是「改完键位，控件失灵」。
//
//  ★本迭代 start 会如实失败★（A2InputErrorCodeNotImplemented）：
//    控件层此刻仍直接往 GLFW 总线投键事件，那条路是通的；在这里假装接管，
//    只会让同一份触摸被投两次（表现为「按一下跳两下」）。
// ============================================================================
#ifndef A2_VIRTUAL_BUTTON_INPUT_SOURCE_H
#define A2_VIRTUAL_BUTTON_INPUT_SOURCE_H

#import <Foundation/Foundation.h>

#import "A2InputSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2VirtualButtonInputSource : NSObject <A2InputSource>

/// 控件层是否已经接进来。[INPUT-MAP-1] 恒为 NO（见文件头）。
@property (nonatomic, readonly) BOOL isWired;

/// 控件按下/抬起。identifier = 布局里的控件 id（不可为空）。
- (void)buttonWithIdentifier:(NSString *)identifier action:(A2InputAction)action;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_VIRTUAL_BUTTON_INPUT_SOURCE_H */
