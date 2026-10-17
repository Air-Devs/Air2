//
//  A2RendererPluginViewController.h
//  Air2
//
//  渲染器插件管理页 —— 导入、查看、卸载。
//
//  对照 FCL 的「渲染器来自插件」体验，但改用 zip 导入：
//    FCL: 装个 APK → 自动出现
//    Air2: 导入 zip → 自动出现
//
//  页面结构：
//    ┌──────────────────────────────┐
//    │ [导入插件包]                  │  主按钮
//    ├──────────────────────────────┤
//    │ 已导入的渲染器                │
//    │  ┌────────────────────────┐  │
//    │  │ [图标] MyGL      ✓ 可用 │  │
//    │  │        基于 Mesa…  卸载 │  │
//    │  └────────────────────────┘  │
//    │  ┌────────────────────────┐  │
//    │  │ [图标] VirGL  ⚠ 签名无效│  │
//    │  │        需要重新签名      │  │
//    │  └────────────────────────┘  │
//    └──────────────────────────────┘
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2RendererPluginViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END
