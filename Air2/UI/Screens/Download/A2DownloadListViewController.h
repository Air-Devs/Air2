//
//  A2DownloadListViewController.h
//  Air2
//
//  资源下载列表 —— 带搜索、筛选、排序的列表页。
//  游戏版本、模组、光影、资源包、整合包、存档共用这一个页面，
//  靠 category 区分数据源与筛选维度。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2DownloadCategory) {
    A2DownloadCategoryGame = 0,    ///< 游戏版本
    A2DownloadCategoryMod,         ///< 模组
    A2DownloadCategoryShader,      ///< 光影包
    A2DownloadCategoryResourcePack,///< 资源包
    A2DownloadCategoryModpack,     ///< 整合包
    A2DownloadCategoryWorld,       ///< 存档
};

@interface A2DownloadListViewController : A2BaseViewController

@property (nonatomic, assign) A2DownloadCategory category;

@end

NS_ASSUME_NONNULL_END
