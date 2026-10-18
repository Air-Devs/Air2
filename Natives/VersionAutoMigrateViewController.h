#pragma once

// ★ [VI-MIGRATE-AUTO] 版本隔离「自动识别迁移」页：
// 用户指一个文件夹 → 自动扫描并按 (MC 版本, 加载器) 分组匹配目标实例 → 用户只勾选「搬哪些」
// （★ [VI-FLOW] 用户修正 4：目标由自动识别决定，本页不提供改归属）→ 确认后才走既有迁移引擎复制
// （复制不移动、幂等、原子、不静默覆盖）。
// 默认不扫不搬：只有用户主动打开本页并操作才动数据。

#import <UIKit/UIKit.h>

@interface VersionAutoMigrateViewController : UIViewController

/// 当前实例 profile（用于解析共享游戏根 / 目标实例根）。
@property (nonatomic, strong) NSDictionary *profile;

@end
