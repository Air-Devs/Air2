#import <Foundation/Foundation.h>

typedef void(^Callback)(id status, BOOL success);

@interface BaseAuthenticator : NSObject

@property (nonatomic, strong) NSMutableDictionary *authData;

+ (id)current;
+ (void)setCurrent:(BaseAuthenticator *)auth;
// 按 accountId 从磁盘加载账户文件。兼容旧版（按 username 命名）账户：
// 若加载到的 authData 没有 accountId 字段，会自动生成并迁移文件、头像、selected_account。
+ (id)loadSavedName:(NSString *)accountId;
// 根据账户数据生成唯一 accountId。微软账户用 xuid，第三方账户用 profileId，本地账户生成 UUID。
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData;

// ★ [ACCT-DUP] 存储幂等去重（账户身份）。用**稳定身份键**判定“同一账户”：
//   微软 = xuid；第三方 = authserver|profileId（无 profileId 退回 username）；本地 = username。
//   身份不可判定（缺关键字段）时返回 nil ⇒ 调用方保守跳过去重，绝不误合并。
+ (NSString *)accountIdentityKeyForData:(NSDictionary *)authData;
// 账户目录内身份键相同、且 accountId 不等于 excludeId 的第一条账户的 accountId（无则 nil）。
+ (NSString *)existingAccountIdForIdentityKey:(NSString *)identityKey excluding:(NSString *)excludeId;

// ★ [ACCT-DUP-MS] 微软兜底身份键（分层）。有序信号（强→弱）：
//   微软 = ms:<xuid> → ms:uuid:<profileId> → ms:gt:<gamertag>|<username>；第三方/本地同旧。
//   缺 xuid 自动退到 uuid，再缺退到 gamertag+username —— 让“缺 xuid 的微软残档”也能合并。
+ (NSArray<NSString *> *)accountIdentitySignalsForData:(NSDictionary *)authData;
// 两条账户数据是否属于同一账户（共用任意一条身份信号）。
+ (BOOL)accountData:(NSDictionary *)a matchesAccountData:(NSDictionary *)b;
// 目录内与 authData 同账户、accountId ≠ excludeId 的第一条账户 accountId（无则 nil）。
+ (NSString *)existingAccountIdForData:(NSDictionary *)authData excluding:(NSString *)excludeId;
// 启动/进入账户页时调用：合并目录内“同身份”的重复账户文件，返回删除的重复条数。
// 仅合并身份键完全相同的条目（不同 username / 不同 xuid / 不同 profileId 的多账号一律保留）。
+ (NSInteger)deduplicateAccountsDirectory;

- (id)initWithData:(NSMutableDictionary *)data;
- (id)initWithInput:(NSString *)string;
- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (BOOL)saveChanges;

@end

@interface LocalAuthenticator : BaseAuthenticator
@end

@interface MicrosoftAuthenticator : BaseAuthenticator

+ (void)clearTokenDataOfProfile:(NSString *)profile;
+ (NSDictionary *)tokenDataOfProfile:(NSString *)profile;

@end
