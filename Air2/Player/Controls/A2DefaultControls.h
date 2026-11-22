//
//  A2DefaultControls.h
//  Air2
//
//  Air2 自带的默认控件布局。
//
//  ## 设计依据
//
//  对照 ZL2 / FCL 的默认布局，取两家的共同点：
//
//    左下     摇杆（WASD 八方向）
//    右侧     视角区（拖动转视角）
//    右下     攻击 / 使用 / 跳跃 / 潜行 / 疾跑
//    右上     背包 / 菜单
//    底部     九格快捷栏（数字键 1~9，长按丢弃、双击换副手）
//    右侧边缘 滚轮（上下滑）
//    顶部     状态条（文本框，穿透）
//
//  这是触屏玩 PC 版 MC 的最小可用集；坐标全部是 0~100 屏幕百分比，
//  换分辨率不会漂移。
//
//  ## 持久化
//
//  makeLayout 会优先读 A2ControlStore 的用户布局（default.json），
//  没有才生成内置布局并落盘。这样游戏内编辑器的「保存」才能在
//  下次进入时生效 —— 宿主加载控件的回退路径就是 makeLayout。
//
//  ## 为什么单独一个文件
//
//  默认布局是「产品决策」，不属于控件引擎。
//  引擎（A2ControlLayout / A2ControlRenderer）应该对默认值无感。
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DefaultControls : NSObject

/// 生成一套默认布局。
/// 优先返回用户保存过的布局（A2ControlStore），没有才返回内置布局。
/// 宿主（SurfaceViewController）在没配置 defaultTouchCtrl 时会调用这个，
/// 所以编辑器保存的布局能从这条路径生效。
+ (A2ControlLayout *)makeLayout;

/// 内置布局（不读写文件）。编辑器「恢复默认」用。
+ (A2ControlLayout *)builtInLayout;

/// 把默认布局写进指定路径（Air2 原生格式）
+ (BOOL)installDefaultLayoutToPath:(NSString *)path error:(NSError **)error;

/// 已存在就不覆盖（首次启动时调用）
+ (BOOL)installIfNeededAtPath:(NSString *)path error:(NSError **)error;

/// 恢复默认：覆盖用户布局（先留备份，见 A2ControlStore）
+ (BOOL)restoreDefaultLayoutWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
