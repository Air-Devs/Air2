#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 联机界面模式（参照 FCL 联机流程设计）
typedef NS_ENUM(NSInteger, MultiplayerVCMode) {
    /// 启动器模式（启动游戏前）：
    /// 显示联机开关 + 预设 Network ID 设置 + 房间列表
    /// 用户在此页面启用联机、设置自己的 ZeroTier Network ID
    MultiplayerVCModeLauncher = 0,

    /// 游戏内模式（启动游戏后，通过悬浮球菜单进入）：
    /// 显示"当房主"和"当房客"两个选项
    /// 房主：自动检测 LAN 端口 → 生成分享代码
    /// 房客：输入分享代码 → 加入网络 → 设置 SOCKS5 代理
    MultiplayerVCModeInGame = 1,
};

/// MC 联机界面（参照 FCL 联机流程重制）
///
/// 对标 FCL (FoldCraftLauncher) 的联机体验：
/// - 启动游戏前：在联机界面打开开关启用联机
/// - 启动游戏后：在悬浮球菜单中打开联机界面，选择当房主还是房客
/// - 房主：创建世界 → 开放局域网 → 自动获取端口号 → 生成分享代码
/// - 房客：输入分享代码 → 在 MC 多人游戏界面看到房间
///
/// Network ID 采用预设机制：房主首次设置一次（在 my.zerotier.com 创建后填入），
/// 之后每次开房自动使用，分享代码中自动包含此 Network ID。
@interface MultiplayerViewController : UIViewController

/// 初始化联机界面
/// @param mode 界面模式（启动器 / 游戏内）
- (instancetype)initWithMode:(MultiplayerVCMode)mode;

@end

NS_ASSUME_NONNULL_END
