//
//  ServerDetailViewController.h
//  Amethyst
//
//  服务器详情页：
//  - 服务器图标、名称、描述
//  - 服务器地址（可复制）
//  - "加入服务器"按钮（保存地址到当前 profile）
//  - "下载关联整合包"按钮（如果有关联 modpack / server pack）
//  - 使用 InlineMessageView 显示操作结果
//

#import <UIKit/UIKit.h>
#import "ServerItem.h"
#import "ServerService.h"

NS_ASSUME_NONNULL_BEGIN

@interface ServerDetailViewController : UIViewController

- (instancetype)initWithServerItem:(ServerItem *)item api:(ServerDownloadAPI)api;

@end

NS_ASSUME_NONNULL_END
