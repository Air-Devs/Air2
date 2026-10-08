//
//  A2AccountManager.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#import "A2AccountManager.h"
#import "A2MicrosoftAuth.h"
#import "A2Settings.h"
#import "A2Log.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const A2AccountsDidChangeNotification = @"A2AccountsDidChangeNotification";

// 账号落盘目录：Documents/account/，一个账号一个 JSON 文件。
// 文件名用账号的 uniqueID（随机串），不用账号名 —— 从文件名看不出是谁。
static NSString *const kAccountsDirName = @"account";
static NSString *const kAccountFileExtension = @"json";
// 当前账号 key 收敛到 A2Settings，不再本地定义。

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

#pragma mark - Yggdrasil

@implementation A2YggdrasilAuth

- (NSMutableURLRequest *)requestWithURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return req;
}

/// 规范化服务器地址：去掉尾部斜杠
- (NSString *)normalize:(NSString *)url {
    NSMutableString *s = [url mutableCopy];
    while ([s hasSuffix:@"/"]) [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
    return s;
}

- (void)authenticateWithServer:(NSString *)serverURL
                      username:(NSString *)username
                      password:(NSString *)password
                    completion:(void (^)(A2Account *, NSError *))completion {

    if (serverURL.length == 0 || username.length == 0) {
        if (completion) completion(nil, [self err:@"请填写服务器地址与用户名"]);
        return;
    }

    NSString *base = [self normalize:serverURL];
    NSMutableURLRequest *req = [self requestWithURL:
        [base stringByAppendingString:@"/authserver/authenticate"]];
    if (!req) {
        if (completion) completion(nil, [self err:@"服务器地址无效"]);
        return;
    }

    // Yggdrasil 的标准请求体：agent.name 固定 Minecraft，version 为 1
    NSDictionary *body = @{
        @"username": username,
        @"password": password,
        @"agent": @{ @"name": @"Minecraft", @"version": @1 },
        @"requestUser": @YES,
        @"clientToken": [self randomToken],
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            A2Main(^{ if (completion) completion(nil, [self err:@"返回格式异常"]); });
            return;
        }
        if (json[@"error"]) {
            NSString *msg = json[@"errorMessage"] ?: json[@"error"];
            A2Main(^{ if (completion) completion(nil, [self err:msg]); });
            return;
        }

        // 取选中的角色档案
        NSDictionary *profile = json[@"selectedProfile"];
        if (![profile isKindOfClass:NSDictionary.class]) {
            NSArray *available = json[@"availableProfiles"];
            if ([available isKindOfClass:NSArray.class] && available.count > 0) {
                profile = available.firstObject;
            }
        }
        if (![profile isKindOfClass:NSDictionary.class]) {
            A2Main(^{ if (completion) completion(nil, [self err:@"此账号没有可用的角色"]); });
            return;
        }

        A2Account *account = [[A2Account alloc] initWithType:A2AccountTypeThirdParty
                                                    username:profile[@"name"] ?: username];
        account.profileID = profile[@"id"];
        account.accessToken = json[@"accessToken"];
        account.clientToken = json[@"clientToken"];
        account.authServerURL = base;

        A2Main(^{ if (completion) completion(account, nil); });
    }];
    [t resume];
}

- (void)validateAccount:(A2Account *)account
             completion:(void (^)(BOOL, NSError *))completion {
    if (account.authServerURL.length == 0) {
        if (completion) completion(NO, [self err:@"缺少服务器地址"]);
        return;
    }
    NSString *base = [self normalize:account.authServerURL];
    NSMutableURLRequest *req = [self requestWithURL:
        [base stringByAppendingString:@"/authserver/validate"]];
    NSDictionary *body = @{
        @"accessToken": account.accessToken ?: @"",
        @"clientToken": account.clientToken ?: @"",
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        // Yggdrasil 规范：令牌有效返回 204 No Content
        BOOL valid = (http.statusCode == 204);
        A2Main(^{ if (completion) completion(valid, error); });
    }];
    [t resume];
}

- (void)refreshAccount:(A2Account *)account
            completion:(void (^)(A2Account *, NSError *))completion {
    if (account.authServerURL.length == 0) {
        if (completion) completion(nil, [self err:@"缺少服务器地址"]);
        return;
    }
    NSString *base = [self normalize:account.authServerURL];
    NSMutableURLRequest *req = [self requestWithURL:
        [base stringByAppendingString:@"/authserver/refresh"]];
    NSDictionary *body = @{
        @"accessToken": account.accessToken ?: @"",
        @"clientToken": account.clientToken ?: @"",
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *token = json[@"accessToken"];
        if (token.length == 0) {
            A2Main(^{ if (completion) completion(nil, [self err:@"续期失败"]); });
            return;
        }
        A2Account *newAcc = [account copy];
        newAcc.accessToken = token;
        A2Main(^{ if (completion) completion(newAcc, nil); });
    }];
    [t resume];
}

- (NSString *)randomToken {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2Yggdrasil" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"认证失败"}];
}

@end

#pragma mark - 账号管理器

@interface A2AccountManager ()
// 头文件标 readonly，这里重声明为可写 —— 标准的「对外只读、对内可写」
@property (nonatomic, copy) NSArray<A2Account *> *accounts;
@property (nonatomic, strong, nullable) A2Account *currentAccount;
@property (nonatomic, strong) A2YggdrasilAuth *yggdrasil;
@property (nonatomic, strong) A2MicrosoftAuth *microsoft;
@end

@implementation A2AccountManager

+ (instancetype)shared {
    static A2AccountManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2AccountManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _accounts = @[];
    _yggdrasil = [A2YggdrasilAuth new];
    _microsoft = [A2MicrosoftAuth new];
    // 构造期只读盘、不发通知：此刻 shared 的 dispatch_once 还没返回，
    // 观察者在回调里再取一次 shared 会重入同一个 dispatch_once 而死锁（SIGTRAP）。
    [self loadAccountsFromDisk];
    return self;
}

#pragma mark 持久化

/// 账号目录：Documents/account/。不存在时创建。
- (NSString *)accountsDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:kAccountsDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return dir;
}

/// 账号对应的文件路径。文件名就是账号的随机 uniqueID，与账号名无关。
- (NSString *)filePathForAccount:(A2Account *)account {
    NSString *name = [NSString stringWithFormat:@"%@.%@",
                      account.uniqueID, kAccountFileExtension];
    return [[self accountsDirectory] stringByAppendingPathComponent:name];
}

- (void)reload {
    [self loadAccountsFromDisk];
    [self notify];
}

/// 扫描账号目录并恢复当前账号。与 reload 分开是因为 init 必须在
/// dispatch_once 内完成，期间不能发通知（见 init 处的说明）。
- (void)loadAccountsFromDisk {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self accountsDirectory];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    NSMutableArray<A2Account *> *list = [NSMutableArray array];
    for (NSString *name in entries) {
        if (![name.pathExtension isEqualToString:kAccountFileExtension]) continue;

        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;

        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *dict = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        A2Account *a = [A2Account fromDictionary:dict];
        if (!a) continue;

        // 文件名即账号 ID：内容里缺 uniqueID 时用它兜底。
        if (a.uniqueID.length == 0) a.uniqueID = name.stringByDeletingPathExtension;
        [list addObject:a];
    }

    // 目录枚举顺序不保证稳定，按创建时间排回「添加顺序」。
    [list sortUsingComparator:^NSComparisonResult(A2Account *x, A2Account *y) {
        return [x.createdAt compare:y.createdAt];
    }];

    _accounts = [list copy];
    [A2Log log:@"AccountManager: 从 %@ 目录载入 %lu 个账号",
                kAccountsDirName, (unsigned long)_accounts.count];

    NSString *savedID = A2Settings.shared.currentAccountID;
    _currentAccount = nil;
    if (savedID) {
        for (A2Account *a in _accounts) {
            if ([a.uniqueID isEqualToString:savedID]) { _currentAccount = a; break; }
        }
    }
    if (!_currentAccount && _accounts.count > 0) _currentAccount = _accounts.firstObject;
}

/// 把单个账号写成独立 JSON 文件。
- (void)persistAccount:(A2Account *)account {
    if (account.uniqueID.length == 0) return;

    NSData *data = [NSJSONSerialization dataWithJSONObject:[account toDictionary]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSString *path = [self filePathForAccount:account];
    [data writeToFile:path atomically:YES];

    // 账号文件含 access token，收紧权限到 0600
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:path error:nil];

    [A2Log log:@"AccountManager: 写入账号文件 %@.%@",
                account.uniqueID, kAccountFileExtension];
}

/// 删除账号对应的文件。
- (void)deleteFileForAccount:(A2Account *)account {
    if (account.uniqueID.length == 0) return;

    [[NSFileManager defaultManager] removeItemAtPath:[self filePathForAccount:account]
                                              error:nil];
    [A2Log log:@"AccountManager: 删除账号文件 %@.%@",
                account.uniqueID, kAccountFileExtension];
}

- (void)notify {
    [NSNotificationCenter.defaultCenter postNotificationName:A2AccountsDidChangeNotification
                                                      object:self];
}

#pragma mark 增删改

- (void)addAccount:(A2Account *)account {
    if (!account) return;
    NSMutableArray<A2Account *> *list = [_accounts mutableCopy];

    // 同一账号（类型 + profileID 相同）则替换，避免重复
    NSInteger existing = NSNotFound;
    for (NSUInteger i = 0; i < list.count; i++) {
        A2Account *a = list[i];
        if (a.type == account.type &&
            ((account.profileID.length && [a.profileID isEqualToString:account.profileID]) ||
             (!account.profileID.length && [a.username isEqualToString:account.username]))) {
            existing = i;
            break;
        }
    }

    if (existing != NSNotFound) {
        // 保留原有唯一 ID，这样文件名不变，也不影响「当前账号」的记录
        account.uniqueID = list[existing].uniqueID;
        if (!account.createdAt) account.createdAt = list[existing].createdAt;
        list[existing] = account;
    } else {
        if (!account.createdAt) account.createdAt = [NSDate date];
        [list addObject:account];
    }

    _accounts = [list copy];
    [self persistAccount:account];

    if (!_currentAccount) [self selectCurrentAccount:account];
    [self notify];
}

- (void)removeAccount:(A2Account *)account {
    if (!account) return;
    NSMutableArray<A2Account *> *list = [_accounts mutableCopy];
    A2Account *found = nil;
    for (A2Account *a in list) {
        if ([a.uniqueID isEqualToString:account.uniqueID]) { found = a; break; }
    }
    if (!found) return;

    [list removeObject:found];
    _accounts = [list copy];
    [self deleteFileForAccount:found];

    if (_currentAccount && [_currentAccount.uniqueID isEqualToString:account.uniqueID]) {
        _currentAccount = _accounts.count > 0 ? _accounts.firstObject : nil;
        // 同步「当前账号」记录，否则下次启动会指向已被删掉的 ID。
        A2Settings.shared.currentAccountID = _currentAccount.uniqueID;
    }

    [self notify];
}

- (BOOL)selectCurrentAccount:(A2Account *)account {
    if (!account) return NO;
    _currentAccount = account;
    A2Settings.shared.currentAccountID = account.uniqueID;
    [self notify];
    return YES;
}

#pragma mark 离线账号

- (A2Account *)createOfflineAccountWithName:(NSString *)name {
    if (name.length == 0) return nil;
    A2Account *a = [[A2Account alloc] initWithType:A2AccountTypeOffline username:name];
    a.profileID = [A2AccountManager offlineUUIDForName:name];
    return a;
}

/// 离线模式的 UUID：对 "OfflinePlayer:{name}" 做 MD5 并按 RFC 4122 设置版本位。
///
/// 必须与 Java 的 UUID.nameUUIDFromBytes 完全一致 ——
/// 不一致会导致联机时服务端把你识别成另一个玩家。
+ (NSString *)offlineUUIDForName:(NSString *)name {
    NSString *input = [NSString stringWithFormat:@"OfflinePlayer:%@", name];
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];

    // MD5 已被标记弃用，但这里【必须】用 MD5 ——
    // 离线 UUID 的算法就是 Java 的 UUID.nameUUIDFromBytes，
    // 它内部固定用 MD5。换成 SHA256 会导致生成的 UUID 与
    // 服务端、与其他启动器都不一致，联机时被识别成不同玩家。
    // 这是协议兼容性要求，不是安全用途。
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop

    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];

    // 第 13 个十六进制位设为 3（版本号），第 17 位设为 8~b（变体）
    NSMutableString *uuid = [hex mutableCopy];
    [uuid replaceCharactersInRange:NSMakeRange(12, 1) withString:@"3"];

    unichar variant = [uuid characterAtIndex:16];
    NSInteger v = [self hexValueOf:variant];
    [uuid replaceCharactersInRange:NSMakeRange(16, 1)
                        withString:[NSString stringWithFormat:@"%lx", (v & 0x3) | 0x8]];
    return [uuid copy];
}

+ (NSInteger)hexValueOf:(unichar)c {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

#pragma mark 续期

- (void)refreshCurrentAccountIfNeeded:(void (^)(BOOL, NSError *))completion {
    A2Account *acc = _currentAccount;
    if (!acc) {
        if (completion) completion(NO, nil);
        return;
    }
    if (!acc.isExpired) {
        if (completion) completion(YES, nil);
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (acc.type == A2AccountTypeMicrosoft) {
        [_microsoft refreshAccount:acc completion:^(A2Account *newAcc, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (newAcc) [self addAccount:newAcc];
            if (completion) completion(newAcc != nil, error);
        }];
    } else if (acc.type == A2AccountTypeThirdParty) {
        [_yggdrasil refreshAccount:acc completion:^(A2Account *newAcc, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (newAcc) [self addAccount:newAcc];
            if (completion) completion(newAcc != nil, error);
        }];
    } else {
        if (completion) completion(YES, nil);   // 离线账号无需续期
    }
}

@end
