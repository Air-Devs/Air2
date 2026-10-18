//
//  ModsManagerViewController.h
//  Amethyst
//
//  Mod 管理页（继承 ResourceListViewController 基类）
//  基类提供：毛玻璃背景、胶囊搜索栏、卡片表格、空/加载态、
//  批量选择模式底部工具栏、连锁进场动画。
//  本类负责：Mod 数据加载、筛选（全部/已启用/已禁用）与排序、
//  批量启用/禁用/删除、内置更新检测与下载替换。
//

#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModsManagerViewController : ResourceListViewController

/// 目标 profile 名（nil 时按 default 处理）
@property (nonatomic, copy, nullable) NSString *profileName;

@end

NS_ASSUME_NONNULL_END
