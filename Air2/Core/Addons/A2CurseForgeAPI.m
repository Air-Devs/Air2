//
//  A2CurseForgeAPI.m
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
//

#import "A2CurseForgeAPI.h"
#import "A2MurmurHash2.h"
#import <Security/Security.h>

const NSInteger A2CFMinecraftGameID = 432;

static NSString *const kBaseURL = @"https://api.curseforge.com/v1";
/// 内置的 CurseForge API Key。
///
/// 参考 ZL2 的做法（ZalithLauncher/build.gradle.kts 里的
/// getKeyFromLocal + BuildConfig.CURSEFORGE_API）：Key 在构建期注入，
/// 用户开箱即用，不需要自己申请。
///
/// 取值优先级：
///   1. 环境变量 CURSEFORGE_API_KEY   —— 便于 CI 用 secret、本地覆盖
///   2. 沙盒 Documents/.curseforge_api.txt —— 便于临时替换
///   3. Keychain（用户在设置里填过自己的 Key）
///   4. 这个内置值                     —— 兜底，保证开箱可用
static NSString *const kBuiltinCurseForgeKey =
    @"$2a$10$VWHUI17c3d5wUKb6eiDDYOMjMrW12An3MstARm5CkuhUeC9.wJWhi";

/// Keychain 里的服务名与账号名
static NSString *const kKeychainService = @"dev.airdevs.air2.curseforge";
static NSString *const kKeychainAccount = @"apiKey";

/// 本地覆盖文件名
static NSString *const kLocalKeyFileName = @".curseforge_api.txt";

/// 解析出实际使用的 Key。
static NSString *A2ResolveCurseForgeKey(void) {
    // 1. 环境变量
    const char *env = getenv("CURSEFORGE_API_KEY");
    if (env && strlen(env) > 0) {
        NSString *v = [NSString stringWithUTF8String:env];
        if (v.length > 0) return v;
    }

    // 2. 沙盒里的本地文件
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) {
        NSString *path = [docs stringByAppendingPathComponent:kLocalKeyFileName];
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (content) {
            NSString *trimmed = [content stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length > 0) return trimmed;
        }
    }

    // 3. Keychain（用户自定义）
    NSString *stored = [A2CurseForgeAPI loadKeyFromKeychain];
    if (stored.length > 0) return stored;

    // 4. 内置兜底
    return kBuiltinCurseForgeKey;
}
static NSString *const kKeychainAccount = @"apiKey";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

/// 平台中立加载器标识 → CurseForge 的 modLoaderType 数字码。
///
/// 两家平台的取值体系不同（我们是字符串标识，CurseForge 是数字枚举），
/// 换算收在这里，调用方只说「要 Fabric」。
/// 未收录的（如 legacy-fabric，CurseForge 不支持）返回 nil，即不加该筛选。
static NSNumber *A2CFModLoaderTypeForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;
    NSString *key = identifier.lowercaseString;
    if ([key isEqualToString:@"forge"])    return @1;
    if ([key isEqualToString:@"fabric"])   return @4;
    if ([key isEqualToString:@"quilt"])    return @5;
    if ([key isEqualToString:@"neoforge"]) return @6;
    return nil;
}

#pragma mark - 项目

@implementation A2CFProject

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2CFProject *p = [A2CFProject new];
    p.projectID = [json[@"id"] integerValue];
    p.name = json[@"name"] ?: @"";
    p.summary = json[@"summary"] ?: @"";
    p.iconURL = [json[@"logo"] isKindOfClass:NSDictionary.class] ? json[@"logo"][@"thumbnailUrl"] : nil;
    p.downloadCount = [json[@"downloadCount"] longLongValue];
    p.classID = [json[@"classId"] integerValue];
    p.slug = [json[@"slug"] isKindOfClass:NSString.class] ? json[@"slug"] : nil;

    NSArray *authors = json[@"authors"];
    if ([authors isKindOfClass:NSArray.class] && authors.count > 0) {
        NSDictionary *a = authors.firstObject;
        if ([a isKindOfClass:NSDictionary.class]) p.authorName = a[@"name"];
    }

    // allowModDistribution 为 false 表示作者禁止第三方分发，
    // 这种项目只能去 CurseForge 官网下载
    id allow = json[@"allowModDistribution"];
    p.allowDistribution = [allow isKindOfClass:NSNumber.class] ? [allow boolValue] : YES;

    return p;
}

@end

#pragma mark - 文件

@implementation A2CFFile

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2CFFile *f = [A2CFFile new];
    f.fileID = [json[@"id"] integerValue];
    f.fileName = json[@"fileName"] ?: @"";
    f.displayName = json[@"displayName"] ?: f.fileName;
    f.downloadURL = [json[@"downloadUrl"] isKindOfClass:NSString.class] ? json[@"downloadUrl"] : nil;
    f.fileLength = [json[@"fileLength"] longLongValue];
    f.gameVersions = [json[@"gameVersions"] isKindOfClass:NSArray.class] ? json[@"gameVersions"] : @[];
    return f;
}

@end

#pragma mark - 客户端

@interface A2CurseForgeAPI ()
@property (nonatomic, copy, nullable) NSString *cachedKey;
/// 供 A2ResolveCurseForgeKey 调用
+ (nullable NSString *)loadKeyFromKeychain;
@end

@implementation A2CurseForgeAPI

+ (instancetype)shared {
    static A2CurseForgeAPI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2CurseForgeAPI alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _cachedKey = A2ResolveCurseForgeKey();
    return self;
}

#pragma mark Key 管理

- (void)setApiKey:(NSString *)apiKey {
    _cachedKey = [apiKey copy];
}

- (NSString *)apiKey {
    return _cachedKey;
}

/// 永远返回 YES —— Key 是内置的，开箱即用。
/// 保留这个方法是为了：
///   · 调用方代码不用改（否则要删一堆判断）
///   · 将来如果要加「Key 失效」的检测，在这里改即可
+ (BOOL)hasAPIKey {
    return A2ResolveCurseForgeKey().length > 0;
}

/// 是否使用了自己的 Key（非内置）
+ (BOOL)usingCustomKey {
    const char *env = getenv("CURSEFORGE_API_KEY");
    if (env && strlen(env) > 0) return YES;
    return [self loadKeyFromKeychain].length > 0;
}

/// 恢复为内置 Key（清掉用户自定义的）
+ (void)resetToBuiltinKey {
    [self saveKeyToKeychain:nil];
    [self shared].apiKey = A2ResolveCurseForgeKey();
}

+ (void)setAPIKey:(NSString *)key {
    [self saveKeyToKeychain:key];
    [self shared].apiKey = key;
}

/// Key 存 Keychain —— 它是凭据，不该放 UserDefaults（明文且会被备份）
+ (nullable NSString *)loadKeyFromKeychain {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;

    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)saveKeyToKeychain:(nullable NSString *)key {
    // 先删旧的
    NSDictionary *delQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };
    SecItemDelete((__bridge CFDictionaryRef)delQuery);

    if (key.length == 0) return YES;   // 删除即清空

    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
        (__bridge id)kSecValueData: data,
        // 仅本机可用、解锁后可读，且不参与 iCloud 备份
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    return SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL) == errSecSuccess;
}

#pragma mark 请求

- (nullable NSMutableURLRequest *)requestWithPath:(NSString *)path
                                            query:(nullable NSArray<NSURLQueryItem *> *)items {
    NSURLComponents *comp = [NSURLComponents componentsWithString:
                             [kBaseURL stringByAppendingString:path]];
    if (items.count > 0) comp.queryItems = items;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:comp.URL];
    req.timeoutInterval = 25;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSString *key = _cachedKey;
    if (key.length == 0) return nil;

    // CurseForge 要求同时带这两个头
    [req setValue:key forHTTPHeaderField:@"x-api-key"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key]
       forHTTPHeaderField:@"Authorization"];

    return req;
}

- (void)GET:(NSString *)path
      query:(nullable NSArray<NSURLQueryItem *> *)items
 completion:(void (^)(id _Nullable data, NSError * _Nullable error))completion {

    NSMutableURLRequest *req = [self requestWithPath:path query:items];
    if (!req) {
        A2Main(^{
            if (completion) {
                completion(nil, [self err:@"未设置 CurseForge API Key"]);
            }
        });
        return;
    }

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;

        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }

        if (http.statusCode == 403) {
            A2Main(^{
                if (completion) completion(nil, [self err:@"API Key 无效或已过期"]);
            });
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            A2Main(^{
                if (completion) {
                    completion(nil, [self err:[NSString stringWithFormat:
                        @"服务返回 HTTP %ld", (long)http.statusCode]]);
                }
            });
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2Main(^{ if (completion) completion(json, nil); });
    }];
    [t resume];
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2CurseForge" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// POST JSON（指纹接口用；GET 保持不动）。
// 与 GET 共用一套鉴权头，超时与错误语义一致。
- (void)POST:(NSString *)path
        body:(NSDictionary *)body
  completion:(void (^)(id _Nullable data, NSError * _Nullable error))completion {
    NSMutableURLRequest *req = [self requestWithPath:path query:nil];
    if (!req) {
        A2Main(^{
            if (completion) completion(nil, [self err:@"未设置 CurseForge API Key"]);
        });
        return;
    }
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }
        if (http.statusCode == 403) {
            A2Main(^{ if (completion) completion(nil, [self err:@"API Key 无效或已过期"]); });
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            A2Main(^{
                if (completion) {
                    completion(nil, [self err:[NSString stringWithFormat:
                        @"服务返回 HTTP %ld", (long)http.statusCode]]);
                }
            });
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2Main(^{ if (completion) completion(json, nil); });
    }];
    [t resume];
}

#pragma mark 接口

- (void)validateKeyWithCompletion:(void (^)(BOOL, NSError *))completion {
    // 拉一次 games 列表最省流量，也能验证 Key
    [self GET:@"/games" query:@[[NSURLQueryItem queryItemWithName:@"pageSize"
                                                            value:@"1"]]
     completion:^(id json, NSError *error) {
        if (completion) completion(error == nil && json != nil, error);
    }];
}

- (void)searchClassID:(A2CFClassID)classID
                query:(NSString *)query
          gameVersion:(NSString *)gameVersion
               loader:(NSString *)loader
          categoryIDs:(NSArray<NSString *> *)categoryIDs
            sortField:(NSString *)sortField
               offset:(NSInteger)offset
                limit:(NSInteger)limit
           completion:(void (^)(NSArray<A2CFProject *> *, NSError *))completion {

    NSInteger pageSize = MIN(limit, 50);

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"gameId"
                                                 value:[@(A2CFMinecraftGameID) stringValue]]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"classId"
                                                 value:[@(classID) stringValue]]];
    // sortField 是 CurseForge 的数字排序码（1=相关 6=下载量 2=人气 11=最新 3=更新）
    [items addObject:[NSURLQueryItem queryItemWithName:@"sortField"
                                                 value:sortField.length ? sortField : @"1"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"sortOrder" value:@"desc"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"pageSize"
                                                 value:[@(pageSize) stringValue]]];

    // CurseForge 用 index/pageSize 分页，不是 offset
    if (offset > 0 && pageSize > 0) {
        NSInteger index = offset / pageSize;
        [items addObject:[NSURLQueryItem queryItemWithName:@"index"
                                                     value:[@(index) stringValue]]];
    }
    if (query.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"searchFilter" value:query]];
    }
    if (gameVersion.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"gameVersion" value:gameVersion]];
    }
    // 加载器筛选：换算失败（CurseForge 不支持该加载器）就不加，避免筛出空结果
    NSNumber *loaderCode = A2CFModLoaderTypeForIdentifier(loader);
    if (loaderCode) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"modLoaderType"
                                                     value:[loaderCode stringValue]]];
    }
    // 分类多选：CurseForge 用逗号分隔的 id 列表
    if (categoryIDs.count > 0) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSString *cid in categoryIDs) {
            if (cid.length > 0) [ids addObject:cid];
        }
        if (ids.count > 0) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"categoryIds"
                                                         value:[ids componentsJoinedByString:@","]]];
        }
    }

    [self GET:@"/mods" query:items completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSArray *raw = dict[@"data"];
        NSMutableArray<A2CFProject *> *out = [NSMutableArray array];
        if ([raw isKindOfClass:NSArray.class]) {
            for (NSDictionary *j in raw) {
                A2CFProject *p = [A2CFProject fromJSON:j];
                if (p) [out addObject:p];
            }
        }
        if (completion) completion(out, nil);
    }];
}

- (void)categoriesForClassID:(NSInteger)classID
                  completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *, NSError *))completion {

    NSArray<NSURLQueryItem *> *items = @[
        [NSURLQueryItem queryItemWithName:@"gameId"
                                    value:[@(A2CFMinecraftGameID) stringValue]],
        [NSURLQueryItem queryItemWithName:@"classId"
                                    value:[@(classID) stringValue]],
    ];

    [self GET:@"/categories" query:items completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSArray *raw = dict[@"data"];
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
        if ([raw isKindOfClass:NSArray.class]) {
            for (NSDictionary *j in raw) {
                if (![j isKindOfClass:NSDictionary.class]) continue;
                NSString *name = j[@"name"];
                if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
                // id 是数字，统一转成字符串以对齐 A2ContentCategory.identifier
                NSString *identifier = [NSString stringWithFormat:@"%ld", (long)[j[@"id"] integerValue]];
                [out addObject:@{ @"identifier": identifier, @"displayName": name }];
            }
        }
        if (completion) completion(out, nil);
    }];
}

- (void)filesForProject:(NSInteger)projectID
            gameVersion:(NSString *)gameVersion
             completion:(void (^)(NSArray<A2CFFile *> *, NSError *))completion {

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"50"]];
    if (gameVersion.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"gameVersion" value:gameVersion]];
    }

    NSString *path = [NSString stringWithFormat:@"/mods/%ld/files", (long)projectID];
    [self GET:path query:items completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSArray *raw = dict[@"data"];
        NSMutableArray<A2CFFile *> *out = [NSMutableArray array];
        if ([raw isKindOfClass:NSArray.class]) {
            for (NSDictionary *j in raw) {
                A2CFFile *f = [A2CFFile fromJSON:j];
                if (f) [out addObject:f];
            }
        }
        if (completion) completion(out, nil);
    }];
}

- (void)projectWithID:(NSInteger)projectID
           completion:(void (^)(A2CFProject *, NSError *))completion {
    NSString *path = [NSString stringWithFormat:@"/mods/%ld", (long)projectID];
    [self GET:path query:nil completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        A2CFProject *p = [A2CFProject fromJSON:dict[@"data"]];
        if (completion) completion(p, p ? nil : [self err:@"项目不存在"]);
    }];
}

#pragma mark - MurmurHash 反查

+ (NSSet<NSNumber *> *)fingerprintSkipBytes {
    // CurseForge 指纹剔除 \t \n \r 空格（与 ZL2 CURSEFORGE_FINGERPRINT_SKIP_BYTES 一致）。
    static NSSet<NSNumber *> *skip = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skip = [NSSet setWithObjects:@(0x09), @(0x0A), @(0x0D), @(0x20), nil];
    });
    return skip;
}

/// CurseForge 用 MurmurHash2 做文件指纹，不是 SHA1。
/// 接口：POST /v1/fingerprints 带 fingerprints 数组，取 data.exactMatches[0].file。
- (void)versionByMurmur:(uint32_t)murmur
            completion:(void (^)(A2CFFile *, NSError *))completion {
    [self POST:@"/fingerprints"
          body:@{@"fingerprints": @[@(murmur)]}
    completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSDictionary *data = [dict[@"data"] isKindOfClass:NSDictionary.class] ? dict[@"data"] : nil;
        NSArray *matches = [data[@"exactMatches"] isKindOfClass:NSArray.class] ? data[@"exactMatches"] : @[];
        NSDictionary *first = [matches.firstObject isKindOfClass:NSDictionary.class] ? matches.firstObject : nil;
        NSDictionary *fileJSON = [first[@"file"] isKindOfClass:NSDictionary.class] ? first[@"file"] : nil;
        A2CFFile *f = [A2CFFile fromJSON:fileJSON];
        // 无精确匹配不算错：调用方回退或提示“无更新”即可（与旧 stub 的 nil 语义兼容）。
        if (completion) completion(f, nil);
    }];
}

/// 按本地文件反查：先本地算 murmur2（seed=1），再调指纹接口。
/// 哈希是 CPU 密集，两次全文件扫描放后台队列，不堵调用线程。
- (void)versionByLocalFileAtPath:(NSString *)path
                     completion:(void (^)(A2CFFile *, NSError *))completion {
    if (path.length == 0) {
        A2Main(^{ if (completion) completion(nil, nil); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *hashErr = nil;
        uint32_t murmur = [A2MurmurHash2 hash32OfFileAtPath:path
                                                 skipBytes:A2CurseForgeAPI.fingerprintSkipBytes
                                                      seed:1
                                                     error:&hashErr];
        if (hashErr) {
            A2Main(^{ if (completion) completion(nil, hashErr); });
            return;
        }
        [self versionByMurmur:murmur completion:completion];
    });
}

/// 旧入口：拿 SHA1 字符串查 CurseForge 是查不出的（两种哈希体系不同）。
/// 保留仅作兼容，始终返回 nil；新代码走 versionByLocalFileAtPath:。
/// 当前实现为「尽力而为」：没有 murmur2 实现时返回 nil，
/// 调用方应回退到 Modrinth 查询或直接提示无法检查更新。
- (void)versionByMurmurHash:(NSString *)sha1
                       size:(long long)size
                 completion:(void (^)(A2CFFile *, NSError *))completion {
    (void)sha1;
    (void)size;
    // 未实现 murmur2 计算 —— 明确返回 nil 而不是给错数据
    if (completion) completion(nil, nil);
}

@end
