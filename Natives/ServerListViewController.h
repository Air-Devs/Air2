//
//  ServerListViewController.h
//  Amethyst
//
//  服务器列表页，参照 ModpackInstallViewController 的 UI 模式：
//  - 顶部源切换（Modrinth / CurseForge）
//  - 搜索框
//  - 列表展示服务器
//  - 点击进入详情（ServerDetailViewController）
//  - 使用 InlineMessageView 替代弹窗
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ServerListViewController : UITableViewController <UISearchResultsUpdating>

@end

NS_ASSUME_NONNULL_END
