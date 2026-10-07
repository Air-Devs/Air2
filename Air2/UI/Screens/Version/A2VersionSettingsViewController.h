//
//  A2VersionSettingsViewController.h
//  Air2
//
//  单版本设置 —— 覆盖全局设置。
//
//  重点：版本隔离
//    隔离类型：跟随全局 / 开启 / 关闭
//    自定义游戏目录（未隔离时生效）
//    五个可隔离目录的入口：mods / resourcepacks / saves / shaderpacks / screenshots
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionSettingsViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName;

@end

NS_ASSUME_NONNULL_END
