#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Rust 侧 8 个底层状态枚举（对应 terracotta_ios_get_state 返回 JSON 的 "state" 字段）
typedef NS_ENUM(NSInteger, TerracottaStateKind) {
    TerracottaStateKindWaiting          = 0,  /* 空闲，未开始联机 */
    TerracottaStateKindHostScanning     = 1,  /* 房主：扫描 MC LAN 多播 */
    TerracottaStateKindHostStarting     = 2,  /* 房主：EasyTier 启动中 */
    TerracottaStateKindHostOk           = 3,  /* 房主：联机已建立，等待访客 */
    TerracottaStateKindGuestConnecting  = 4,  /* 访客：连接房主中 */
    TerracottaStateKindGuestStarting    = 5,  /* 访客：EasyTier 启动中 */
    TerracottaStateKindGuestOk          = 6,  /* 访客：联机已建立，可进 MC */
    TerracottaStateKindException        = 7,  /* 异常（参考 type 字段） */
};

/// 玩家资料（房主 + 已加入访客）
@interface TerracottaPlayerProfile : NSObject
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *machineId;
@property(nonatomic, copy, nullable) NSString *easytierId;
@property(nonatomic, copy, nullable) NSString *vendor;
@property(nonatomic, copy, nullable) NSString *kind;
@end

/// Rust 侧状态快照
@interface TerracottaState : NSObject
@property(nonatomic, assign) TerracottaStateKind kind;
@property(nonatomic, assign) NSInteger index;
@property(nonatomic, copy, nullable) NSString *room;
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *profiles;
@property(nonatomic, assign) NSInteger profileIndex;
@property(nonatomic, assign) NSInteger exceptionType;  /* 仅 kind==Exception 时有效 */
@end

/// C ABI 封装层。所有方法线程安全。
@interface TerracottaBridge : NSObject

/// 运行时检查 libterracotta 是否链接。未链接时所有调用安全降级。
+ (BOOL)isAvailable;

/// 初始化 Terracotta。App 启动时调用一次。
+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(nullable NSString *)loggingPath;

/// 回到 Waiting 状态（终止当前会话）。Idempotent。
+ (void)setWaiting;

/// 房主：开始扫描 MC LAN 多播。
+ (void)setScanningWithRoom:(nullable NSString *)room
                 playerName:(nullable NSString *)playerName;

/// 房主（手动端口模式）：用用户输入的 MC LAN 端口启动 host。
+ (BOOL)startHostWithRoom:(nullable NSString *)room
                     port:(uint16_t)port
               playerName:(nullable NSString *)playerName;

/// 访客：加入房间。
+ (BOOL)setGuestingWithRoom:(NSString *)room
                 playerName:(nullable NSString *)playerName;

/// 校验邀请码格式。返回 YES 表示合法的 Scaffolding 邀请码。
+ (BOOL)verifyRoomCode:(NSString *)code;

/// 轮询当前状态。返回 nil 表示解析失败或库不可用。
+ (nullable TerracottaState *)pollState;

/// 元数据：version / compileTimestamp / easytierVersion。
+ (nullable NSDictionary<NSString *, id> *)metadata;

/// 异常类型描述（用于 UI 显示）。
+ (NSString *)describeException:(NSInteger)type;

@end

NS_ASSUME_NONNULL_END
