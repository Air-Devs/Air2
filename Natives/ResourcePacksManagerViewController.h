//
//  ResourcePacksManagerViewController.h
//  Amethyst
//
//  资源包管理视图控制器（继承 ResourceListViewController 列表基类）
//  本地扫描、搜索、启用/禁用、删除、导入；在线下载入口已移至统一下载界面
//

#import <UIKit/UIKit.h>
#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ResourcePacksManagerMode) {
    ResourcePacksManagerModeLocal,
    ResourcePacksManagerModeOnline
};

@interface ResourcePacksManagerViewController : ResourceListViewController

@property (nonatomic, copy, nullable) NSString *profileName;

// 在线下载入口已移至统一下载界面：以下属性仅为兼容既有调用方保留，界面固定本地模式
@property (nonatomic, assign) ResourcePacksManagerMode initialMode;
@property (nonatomic, assign) ResourcePacksManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
