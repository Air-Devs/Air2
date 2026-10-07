//
//  A2HomeViewController.h
//  Air2
//
//  主页 —— 启动器门面。
//
//  布局（自上而下）：
//    [窄顶栏]  标题 + 右侧账号头像 / 任务入口 / 设置入口
//    [内容区]  滚动视图
//      ├ 当前版本大卡片（毛玻璃，含"开始游戏"主按钮）
//      ├ 快捷操作网格（版本管理 / 下载 / 联机 / 文件）
//      └ 最近游玩列表
//    [底部抽屉] 任务进度（可上滑展开）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2HomeViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
