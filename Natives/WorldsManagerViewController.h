//
//  WorldsManagerViewController.h
//  Amethyst
//
//  世界存档管理视图控制器（继承 ResourceListViewController 列表基类）
//  扫描 saves/ 目录、删除世界、导入世界 zip（含健壮解压）；在线下载入口已移至统一下载界面
//

#import <UIKit/UIKit.h>
#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WorldsManagerMode) {
    WorldsManagerModeLocal,
    WorldsManagerModeOnline
};

@interface WorldsManagerViewController : ResourceListViewController

@property (nonatomic, copy, nullable) NSString *profileName;

// 在线下载入口已移至统一下载界面：以下属性仅为兼容既有调用方保留，界面固定本地模式
@property (nonatomic, assign) WorldsManagerMode initialMode;
@property (nonatomic, assign) WorldsManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
