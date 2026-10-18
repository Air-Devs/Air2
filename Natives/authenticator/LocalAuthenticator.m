#import "BaseAuthenticator.h"

@implementation LocalAuthenticator

- (void)loginWithCallback:(Callback)callback {
    self.authData[@"username"] = self.authData[@"input"];
    self.authData[@"profileId"] = @"00000000-0000-0000-0000-000000000000";
    // ★ [ACCT-DUP] 本地账户无天然唯一 ID，这里先给一个随机 UUID 兜底。
    //   注意：BaseAuthenticator.saveChanges 会按身份键(local:<username>)做幂等去重——
    //   若磁盘上已存在同名本地账户，会**复用其 accountId** 并把数据写回同一条文件，
    //   因此“同一用户名重复登录”不会再冒第二条（原先每次登录都新建文件 = 偶发重复账户的主因）。
    self.authData[@"accountId"] = [[NSUUID UUID] UUIDString];
    // 使用Minecraft Headshot API加载头像
    self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://api.rms.net.cn/head/%@", self.authData[@"username"]];
    callback(nil, [super saveChanges]);
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Nothing to do
    callback(nil, YES);
}

@end
