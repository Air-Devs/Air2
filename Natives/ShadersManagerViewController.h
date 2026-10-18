//
//  ShadersManagerViewController.h
//  Amethyst
//
//  光影管理界面（本地光影列表，接入 ResourceListViewController 基类）
//

#import <UIKit/UIKit.h>
#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ShadersManagerMode) {
    ShadersManagerModeLocal,
    ShadersManagerModeOnline
};

@interface ShadersManagerViewController : ResourceListViewController

/// 目标 profile（nil 时按 default 扫描 shaderpacks 目录）
@property (nonatomic, copy, nullable) NSString *profileName;

/// 初始模式：保留以兼容既有调用方赋值；
/// 在线下载入口已移至统一下载界面，本界面始终为本地模式
@property (nonatomic, assign) ShadersManagerMode initialMode;

@end

NS_ASSUME_NONNULL_END
