//
//  A2SettingsSections.h
//  Air2
//
//  设置页各分组的构建器。
//  每个分组一个类方法，接收宿主控制器以便弹出子页面。
//

#import <UIKit/UIKit.h>
#import "A2SettingsSection.h"

NS_ASSUME_NONNULL_BEGIN

/// 外观 —— 主题、亮暗、玻璃强度
@interface A2AppearanceSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 游戏 —— 内存、Java、启动参数、隔离默认值
@interface A2GameSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 渲染 —— 渲染器、Zink、分辨率、帧率
@interface A2RendererSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 存储 —— 游戏目录、缓存、清理
@interface A2StorageSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 关于 —— 版本、开源许可、日志
@interface A2AboutSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
