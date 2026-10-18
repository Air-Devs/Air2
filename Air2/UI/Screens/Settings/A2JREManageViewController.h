//
//  A2JREManageViewController.h
//  Air2
//
//  JRE 管理页 —— 参考 ZL2 的 Java 管理。
//
//  ## 页面结构
//
//    ┌────────────────────────────────────┐
//    │ 已安装的 Java 运行时                │
//    │  ┌──────────────────────────────┐  │
//    │  │ Java 17      内置  arm64     │  │
//    │  │ java-17-openjdk           ✓  │  │
//    │  └──────────────────────────────┘  │
//    │  ┌──────────────────────────────┐  │
//    │  │ Java 21      内置  arm64     │  │
//    │  └──────────────────────────────┘  │
//    ├────────────────────────────────────┤
//    │ [导入 JRE]                          │
//    └────────────────────────────────────┘
//
//  ## 与 ZL2 的差异
//
//  ZL2 的 Java 管理还要下载 JRE（它的 JRE 不随 APK 打包）。
//  我们的 4 个 JRE 已经打包进 IPA，所以这个页面只做
//  「查看 / 导入自定义 / 删除导入的 / 给版本指定」。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2JREManageViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END
