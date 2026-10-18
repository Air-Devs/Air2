//
//  DataPacksManagerViewController.h
//  Amethyst
//
//  数据包管理视图控制器（继承 ResourceListViewController 列表基类）
//  本地扫描、搜索、启用/禁用、删除、导入；在线下载入口已移至统一下载界面
//  注意：Minecraft 要求数据包放在 saves/<世界名>/datapacks/，
//  本管理器扫描 <gameDir>/datapacks/（通用目录），用户需手动移动到对应世界目录
//

#import <UIKit/UIKit.h>
#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DataPacksManagerMode) {
    DataPacksManagerModeLocal,
    DataPacksManagerModeOnline
};

@interface DataPacksManagerViewController : ResourceListViewController

@property (nonatomic, copy, nullable) NSString *profileName;

// 在线下载入口已移至统一下载界面：以下属性仅为兼容既有调用方保留，界面固定本地模式
@property (nonatomic, assign) DataPacksManagerMode initialMode;
@property (nonatomic, assign) DataPacksManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
