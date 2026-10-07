//
//  A2ModpackInstallingViewController.h
//  Air2
//
//  整合包安装进度页 —— 展示「下载 → 解压 → 解析 → 铺覆盖 → 装模组 → 装本体 → 收尾」全过程。
//
//  与 A2InstallingViewController 的分工：
//    · 那个装的是 MC 本体 + 加载器
//    · 这个装的是整合包，阶段更多，但视觉语言保持一致
//

#import "A2BaseViewController.h"
#import "A2ModpackInstaller.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ModpackInstallingViewController : A2BaseViewController

/// 用安装请求初始化；进入页面后自动开始安装。
- (instancetype)initWithRequest:(A2ModpackInstallRequest *)request;

@end

NS_ASSUME_NONNULL_END
