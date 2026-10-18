//
//  TerracottaViewController.h
//  陶瓦联机界面（ZalithLauncher2 / FoldCraftLauncher 设计综合）
//
//  设计要点：
//   - 状态驱动：界面随 TerracottaManager.status 切换，不再用常驻 Tab。
//     · 未连接 → 两张入口卡片（创建房间 / 加入房间）
//     · 连接中 → 进度视图 + 阶段描述 + 返回
//     · 已连接 → 房间码 + 复制/退出 + 玩家列表（自适应分栏）
//     · 出错   → 错误描述 + 重试/返回
//   - 去掉了 ZeroTier 入口（不再需要）。
//   - 保留：端口自动检测、邀请码与直连地址复制、玩家列表、状态卡片。
//

#import <UIKit/UIKit.h>
#import "TerracottaManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface TerracottaViewController : UIViewController

/// 由调用方在 present 前设置：以哪个玩家名联机（默认取当前账号名）。
@property(nonatomic, copy, nullable) NSString *playerName;

@end

NS_ASSUME_NONNULL_END
