//
//  A2VersionExportViewController.h
//  Air2
//
//  版本导出 —— 把已安装的版本打包成整合包。
//
//  对照 ZL2 的 VersionExportScreen（三步页面）：
//    1. 选格式（Modrinth / CurseForge）
//    2. 填信息（名称、简介、作者、版本号 —— 各格式要求的字段不同）
//    3. 选文件（勾选要打包的内容）
//
//  我们合并成单页 —— 横屏下三步骤分页反而繁琐。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionExportViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName
                        versionPath:(NSString *)versionPath;

@end

NS_ASSUME_NONNULL_END
