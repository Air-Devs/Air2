//
//  A2Multiplayer.h
//  Air2
//
//  联机模块 —— 对照 ZL2 的 terracotta/ 实现。
//
//  ZL2 的方案（已核对 TerracottaState.kt）：
//    · 底层是 libterracotta（Rust 实现，走 EasyTier P2P）
//    · 房主两种模式：
//        多播扫描（HostScanning）—— 自动发现 MC 的「对局域网开放」端口
//        手动端口（HostStarting）—— 用户输入端口
//    · 访客：GuestConnecting → GuestStarting → GuestOK
//    · 状态机共 8 个底层状态，映射为 4 个 UI 状态
//
//  ⚠️ 关于端口检测：ZL2 用【多播扫描】，不解析游戏日志。
//     这比读日志可靠 —— 不受 MC 日志文案改版影响。
//     本模块同样以多播扫描为主，不实现日志解析方案。
//
//  ⚠️ 二进制依赖：需要 libterracotta.xcframework。
//     目前 Libraries/Frameworks/ 下没有这个库，所以本模块
//     当前会走「库不可用」分支 —— 状态机与 UI 逻辑完整，
//     等库就位后即可工作。这是刻意的设计，不是空壳。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 联机状态（4 个 UI 状态，由 8 个底层状态映射而来）
typedef NS_ENUM(NSInteger, A2MultiplayerStatus) {
    A2MultiplayerStatusDisconnected = 0,  ///< 未联机
    A2MultiplayerStatusConnecting,        ///< 连接中
    A2MultiplayerStatusConnected,         ///< 已连接
    A2MultiplayerStatusError,             ///< 出错
};

/// 当前角色
typedef NS_ENUM(NSInteger, A2MultiplayerRole) {
    A2MultiplayerRoleNone = 0,
    A2MultiplayerRoleHost,      ///< 房主
    A2MultiplayerRoleGuest,     ///< 房客
};

/// 状态变化通知
extern NSNotificationName const A2MultiplayerStateDidChangeNotification;

@interface A2MultiplayerPlayer : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isSelf;
@end

@interface A2Multiplayer : NSObject

+ (instancetype)shared;

@property (nonatomic, assign, readonly) A2MultiplayerStatus status;
@property (nonatomic, assign, readonly) A2MultiplayerRole role;
/// 底层库是否可用（libterracotta 链接成功）
@property (nonatomic, assign, readonly) BOOL available;

/// 房主的邀请码
@property (nonatomic, copy, readonly, nullable) NSString *inviteCode;
/// 房主的 MC 局域网端口（多播扫描得到，或用户手填）
@property (nonatomic, assign, readonly) uint16_t lanPort;
/// 房客应该连接的地址
@property (nonatomic, copy, readonly, nullable) NSString *directConnectAddress;
/// 当前阶段的展示文字
@property (nonatomic, copy, readonly, nullable) NSString *stageDescription;
/// 房间内的玩家列表
@property (nonatomic, copy, readonly) NSArray<A2MultiplayerPlayer *> *players;
/// 最后一次错误
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

#pragma mark - 会话控制

/// 初始化（App 启动时调用一次）
- (void)initializeIfNeeded;

/// 房主：创建房间。
/// @param port 0 表示用多播扫描自动发现端口；非 0 表示手动指定
/// @param inviteCode 自定义邀请码，nil 表示由库生成
- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(nullable NSString *)inviteCode;

/// 房客：加入房间。
/// @return NO 表示邀请码格式无效（不会发起加入）
- (BOOL)joinRoomWithCode:(NSString *)inviteCode;

/// 校验邀请码格式（不发起加入）
- (BOOL)isValidInviteCode:(NSString *)code;

/// 断开会话
- (void)stopSession;

@end

NS_ASSUME_NONNULL_END
