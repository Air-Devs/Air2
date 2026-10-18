#import <UIKit/UIKit.h>

// 下载页面 - 版本/模组/光影/资源包/数据包/整合包/世界 七个标签
@interface DownloadViewController : UIViewController

/// 初始显示的 tab（0版本 1模组 2光影 3资源包 4数据包 5整合包 6世界），默认 0；
/// 供资源管理界面"去下载"引导跳转时定位到对应资源类型
@property (nonatomic, assign) NSInteger initialTabIndex;

/// 下载目标实例（profile）。从资源管理页进入时传入该页绑定的 profileName，
/// 保证"下载页的目标实例"与"资源管理页打开的实例"一致，避免资源写入另一个游戏目录。
/// 未传入时回退到启动下载瞬间的当前选中 profile（viewDidLoad 时快照）。
@property (nonatomic, copy, nullable) NSString *targetProfileName;

@end
