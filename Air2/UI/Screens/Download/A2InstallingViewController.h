//
//  A2InstallingViewController.h
//  Air2
//
//  安装进度页 —— 从一个版本开始安装到完成的全过程展示。
//
//  视觉核心是环形进度 + 分步清单：
//    环形进度给一个"整体完成度"的直觉
//    下面按步骤列出（下载清单 / 校验 / 下载 jar / 下载依赖库 / 下载资源 / 完成）
//    每步有独立状态点，让用户知道卡在哪一步
//

#import "A2BaseViewController.h"
#import "A2ProgressView.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2InstallingViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName loader:(nullable NSString *)loader;

@end

NS_ASSUME_NONNULL_END
