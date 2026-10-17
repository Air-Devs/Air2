//
//  A2RendererSettingsViewController.h
//  Air2
//
//  渲染器选择页 —— 对照 ZL2 的 RendererSettingsScreen.kt。
//
//  ZL2 的结构：
//    ┌──────────────────────────────────────┐
//    │ 全局渲染器                        ⚙ ⬇ │  ← 齿轮=配置，下载=插件下载
//    │ 全局默认的渲染器…                     │
//    │ 当前选择项：NG-GL4ES                  │
//    ├──────────────────────────────────────┤
//    │ 渲染器列表（点开是单选列表）           │
//    │  · NG-GL4ES   内置                    │
//    │  · Zink       内置                    │
//    │  · MyGL       来自插件 xxx            │
//    └──────────────────────────────────────┘
//
//  ⚙ 只在选中的渲染器有可配置项时出现（对应 ZL2 的 v2 插件）
//  ⬇ 打开插件导入（我们的对应物，ZL2 是打开 GitHub 下载页）
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2RendererSettingsViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END
