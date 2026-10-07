//
//  A2AccountManager.h
//  Air2
//
//  账号管理器 —— 账号的增删改查、当前账号、凭据续期。
//
//  另含 Yggdrasil 第三方认证（对应 ZL2 的 AuthServerApi）。
//

#import <Foundation/Foundation.h>
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

/// 账号列表变更通知
extern NSNotificationName const A2AccountsDidChangeNotification;

#pragma mark - Yggdrasil 第三方认证

/**
 * Yggdrasil 协议客户端（第三方认证服务器，如 LittleSkin）。
 *
 * 协议要点（对照 ZL2 的 AuthServerApi）：
 *   POST /authserver/authenticate  登录
 *   POST /authserver/refresh       续期
 *   POST /authserver/validate      校验
 * 请求体里的 agent.name 固定为 "Minecraft"，version 为 1。
 */
@interface A2YggdrasilAuth : NSObject

/// 登录
- (void)authenticateWithServer:(NSString *)serverURL
                      username:(NSString *)username
                      password:(NSString *)password
                    completion:(void (^)(A2Account * _Nullable account,
                                         NSError * _Nullable error))completion;

/// 校验令牌是否有效
- (void)validateAccount:(A2Account *)account
             completion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

/// 续期
- (void)refreshAccount:(A2Account *)account
            completion:(void (^)(A2Account * _Nullable account,
                                 NSError * _Nullable error))completion;

@end

#pragma mark - 账号管理

@interface A2AccountManager : NSObject

+ (instancetype)shared;

@property (nonatomic, copy, readonly) NSArray<A2Account *> *accounts;
@property (nonatomic, strong, nullable) A2Account *currentAccount;

/// 从磁盘重新加载
- (void)reload;

/// 添加账号（重复的会替换）
- (void)addAccount:(A2Account *)account;

/// 移除账号
- (void)removeAccount:(A2Account *)account;

/// 设为当前账号
- (BOOL)setCurrentAccount:(A2Account *)account;

/// 创建离线账号（仅需用户名）
- (A2Account *)createOfflineAccountWithName:(NSString *)name;

/// 当前账号凭据过期时自动续期
- (void)refreshCurrentAccountIfNeeded:(nullable void (^)(BOOL success,
                                                         NSError * _Nullable error))completion;

/// 生成离线模式下的玩家 UUID（基于用户名，与官方算法一致）
+ (NSString *)offlineUUIDForName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
