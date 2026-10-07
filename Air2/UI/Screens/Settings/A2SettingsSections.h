//
//  A2SettingsSections.h
//  Air2
//
//  设置页的分组构建器。
//
//  ⚠️ 只放「已经有实现」的设置项。
//
//  教训：之前我凭空编了 30 个设置项（渲染器、Java 运行时、内存分配、
//  完整性检查…），全都没有对应实现 —— 图标、开关、滑块都渲染出来了，
//  点下去什么都不会发生。这比没有设置页更糟：用户会以为功能存在。
//
//  新增设置项的前提是有真实实现。宁缺毋滥。
//

#import <UIKit/UIKit.h>
#import "A2SettingsSection.h"

NS_ASSUME_NONNULL_BEGIN

/// 外观 —— 主题、亮暗模式、自定义背景
@interface A2AppearanceSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
/// 资源下载来源（CurseForge API Key 配置）
+ (A2SettingsSection *)buildSourceSectionWithHost:(UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
