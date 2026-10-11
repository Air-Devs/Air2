//
//  A2MultiplayerViewController.h
//  Air2
//
//  联机页 —— 对照 ZL2 的 MultiplayerScreen（Terracotta / 陶瓦联机）。
//
//  布局（与 ZL2 截图一致）：
//    ┌──────────────────────┬────────────────────────┐
//    │ [用户须知][房主教程]   │ 启用多人联机      [开关] │
//    │ [房客教程]            │ 自定义节点       [开关] │
//    ├──────────────────────┤ 分享联机核心日志        │
//    │                      │ 关于 EasyTier          │
//    │  说明文字（可滚动）     │                        │
//    └──────────────────────┴────────────────────────┘
//
//  左侧是三段说明文档（自实现，不从网络拉），右侧是设置项。
//  入场动画：两侧从外向内滑入（对应 ZL2 的 AnimatedRow）。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2MultiplayerViewController : A2BaseViewController

@end

NS_ASSUME_NONNULL_END
