#import <Security/Security.h>
#import "BaseAuthenticator.h"
#import "ThirdPartyAuthenticator.h"
#import "../LauncherPreferences.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

@implementation BaseAuthenticator

static BaseAuthenticator *current = nil;

+ (id)current {
    if (current == nil) {
        // ★ [ACCT-DUP-MS] 启动时先做一次存量重复合并（幂等）：把历史遗留的同一账户多条合并为一条，
        //   并重定向 selected_account 到保留项，避免旧档“5 条相同微软账户”在列表里复活。
        [self deduplicateAccountsDirectory];
        // selected_account 现在存储的是 accountId（旧版存储 username，loadSavedName 会自动迁移）
        NSString *savedAccount = getPrefObject(@"internal.selected_account");
        if (savedAccount.length > 0) {
            [self loadSavedName:savedAccount];
        }
    }
    return current;
}

+ (void)setCurrent:(BaseAuthenticator *)auth {
    current = auth;
}

/// 根据账户数据生成唯一 accountId。
/// - 微软账户：使用 xuid（Xbox User Hash，全局唯一且稳定，登录后不变）
/// - 第三方账户：使用 profileId（角色 UUID，由认证服务器分配，唯一稳定）
/// - 本地账户：无天然唯一 ID，生成随机 UUID
/// 这样同名账户也能通过 accountId 区分，文件名不再冲突。
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData {
    // 微软账户：优先使用 xuid（XSTS 响应中的 uhs，全局唯一且稳定）
    NSString *xuid = authData[@"xuid"];
    if (xuid && [xuid length] > 0) {
        return xuid;
    }
    // 第三方账户：使用 profileId（角色 UUID，由认证服务器分配，唯一稳定）
    NSString *profileId = authData[@"profileId"];
    if (profileId && [profileId length] > 0 &&
        ![profileId isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        return profileId;
    }
    // 本地账户：无天然唯一 ID，生成随机 UUID
    return [[NSUUID UUID] UUIDString];
}

#pragma mark - ★ [ACCT-DUP] 存储幂等去重（账户身份键 / 存量清理）

/// 账户身份键：判定“这是同一个账户”。
///   · 微软（有 xuid）      → "ms:<xuid>"
///   · 第三方（有 clientToken）→ "tp:<authserver>|<profileId>"，无 profileId 退回 "…|u:<username>"
///   · 本地（无 xuid/无 clientToken/无有效 expiresAt）→ "local:<username>"
/// 关键字段缺失 ⇒ 返回 nil，调用方据此**跳过去重**（宁可漏合、不可错合）。
+ (NSString *)accountIdentityKeyForData:(NSDictionary *)authData {
    if (![authData isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    // 微软：xuid 全局唯一且稳定
    NSString *xuid = authData[@"xuid"];
    if ([xuid isKindOfClass:[NSString class]] && xuid.length > 0) {
        return [NSString stringWithFormat:@"ms:%@", xuid];
    }
    // 第三方：authserver + profileId（角色 UUID）唯一稳定
    if (authData[@"clientToken"] != nil) {
        NSString *server = authData[@"authserver"];
        if (![server isKindOfClass:[NSString class]]) {
            server = @"";
        } else {
            // 归一化：去首尾空白、末尾斜杠、转小写 —— 同一服务器书写差异（尾斜杠/大小写）不应产生两个身份键。
            server = [server stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            while ([server hasSuffix:@"/"]) {
                server = [server substringToIndex:server.length - 1];
            }
            server = server.lowercaseString;
        }
        NSString *pid = authData[@"profileId"];
        if ([pid isKindOfClass:[NSString class]] && pid.length > 0 &&
            ![pid isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
            return [NSString stringWithFormat:@"tp:%@|%@", server, pid];
        }
        NSString *user = authData[@"username"];
        if ([user isKindOfClass:[NSString class]] && user.length > 0) {
            return [NSString stringWithFormat:@"tp:%@|u:%@", server, user];
        }
        return nil;
    }
    // 带有效 expiresAt(非 0) 却缺 xuid：疑似微软残档，身份不可判定 ⇒ 不去重（保守）。
    if ([authData[@"expiresAt"] longValue] != 0) {
        return nil;
    }
    // 本地账户：没有天然唯一 ID，同名即视为同一账户（UI 上无法区分，重复即重复提交产物）
    NSString *user = authData[@"username"];
    if ([user isKindOfClass:[NSString class]] && user.length > 0) {
        return [NSString stringWithFormat:@"local:%@", user];
    }
    return nil;
}

#pragma mark - ★ [ACCT-DUP-MS] 微软兜底身份键（分层：xuid → profileId(uuid) → gamertag+username）

/// 归一化：去首尾空白 + 转小写（仅用于比较，不落盘）。
static NSString *ameNormString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

/// 账户种类：0=本地，1=微软，2=第三方。
static NSInteger ameAccountKind(NSDictionary *data) {
    if (data[@"clientToken"] != nil) {
        return 2;
    }
    if (data[@"xboxGamertag"] != nil) {
        return 1;
    }
    // 有有效期(非 0)但既无 gamertag 也无 clientToken：旧的/残缺的微软账户，按微软处理，
    // 避免被误当成“本地账户”而与同名本地账户合并。
    if ([data[@"expiresAt"] longValue] != 0) {
        return 1;
    }
    return 0;
}

/// 并查集：查根（路径压缩）。
static NSInteger ameFindRoot(NSMutableArray<NSNumber *> *parent, NSInteger x) {
    while (parent[x].integerValue != x) {
        parent[x] = parent[parent[x].integerValue];
        x = parent[x].integerValue;
    }
    return x;
}

/// 有序身份信号（强 → 弱）。两个账户**只要共用任意一条**即视为同一账户。
///   · 微软：ms:<xuid>  →  ms:uuid:<profileId>  →  ms:gt:<gamertag>|<username>
///   · 第三方：tp:<server>|<profileId>  →  tp:<server>|u:<username>
///   · 本地：local:<username>
/// 每层都要求对应字段“存在且非空”才产出信号：缺 xuid 退到 uuid，再缺退到 gamertag；
/// 全部拿不到才不产出信号（不参与去重）。⇒「有 expiresAt 却缺 xuid 的微软残档」也能被合并。
+ (NSArray<NSString *> *)accountIdentitySignalsForData:(NSDictionary *)authData {
    if (![authData isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *signals = [NSMutableArray array];
    NSInteger kind = ameAccountKind(authData);

    if (kind == 2) {
        // 第三方：authserver（归一化）+ profileId（角色 UUID），无 profileId 退回 username
        NSString *server = authData[@"authserver"];
        if (![server isKindOfClass:[NSString class]]) {
            server = @"";
        } else {
            server = [server stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            while ([server hasSuffix:@"/"]) {
                server = [server substringToIndex:server.length - 1];
            }
            server = server.lowercaseString;
        }
        NSString *pid = [authData[@"profileId"] isKindOfClass:[NSString class]] ? authData[@"profileId"] : @"";
        if (pid.length > 0 && ![pid isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
            [signals addObject:[NSString stringWithFormat:@"tp:%@|%@", server, pid.lowercaseString]];
        }
        NSString *user = [authData[@"username"] isKindOfClass:[NSString class]] ? authData[@"username"] : @"";
        if (user.length > 0) {
            [signals addObject:[NSString stringWithFormat:@"tp:%@|u:%@", server, user.lowercaseString]];
        }
        return signals;
    }

    if (kind == 1) {
        // 微软：xuid（最强）
        NSString *xuid = [authData[@"xuid"] isKindOfClass:[NSString class]] ? authData[@"xuid"] : @"";
        if (xuid.length > 0) {
            [signals addObject:[NSString stringWithFormat:@"ms:%@", xuid]];
        }
        // 微软：Minecraft profile UUID（旧档常缺 xuid 但有它）
        NSString *pid = [authData[@"profileId"] isKindOfClass:[NSString class]] ? authData[@"profileId"] : @"";
        if (pid.length > 0 && ![pid isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
            [signals addObject:[NSString stringWithFormat:@"ms:uuid:%@", pid.lowercaseString]];
        }
        // 微软兜底：gamertag + username **同时**相同才产出（username 作为“确属同一账户”的佐证；
        // 只有 gamertag 相同而 username 不同 ⇒ 不产出信号 ⇒ 不合并，仅记“疑似但保留”）。
        NSString *gt = ameNormString(authData[@"xboxGamertag"]);
        NSString *user = ameNormString(authData[@"username"]);
        if (gt.length > 0 && user.length > 0) {
            [signals addObject:[NSString stringWithFormat:@"ms:gt:%@|%@", gt, user]];
        }
        return signals;
    }

    // 本地：同名即同一账户（与既有 [ACCT-DUP] 行为一致）
    NSString *user = authData[@"username"];
    if ([user isKindOfClass:[NSString class]] && user.length > 0) {
        [signals addObject:[NSString stringWithFormat:@"local:%@", user]];
    }
    return signals;
}

/// 两条账户数据是否属于同一账户（共用任意一条身份信号）。
+ (BOOL)accountData:(NSDictionary *)a matchesAccountData:(NSDictionary *)b {
    NSArray<NSString *> *sa = [self accountIdentitySignalsForData:a];
    NSArray<NSString *> *sb = [self accountIdentitySignalsForData:b];
    if (sa.count == 0 || sb.count == 0) {
        return NO;
    }
    for (NSString *k in sa) {
        if ([sb containsObject:k]) {
            return YES;
        }
    }
    return NO;
}

/// 一条账户数据与另一条共享的“代表信号”（用于合并日志；无则 nil）。
+ (NSString *)sharedSignalBetween:(NSDictionary *)a and:(NSDictionary *)b {
    NSArray<NSString *> *sa = [self accountIdentitySignalsForData:a];
    NSArray<NSString *> *sb = [self accountIdentitySignalsForData:b];
    for (NSString *k in sa) {
        if ([sb containsObject:k]) {
            return k;
        }
    }
    return nil;
}

/// 目录内与 authData 同账户、accountId ≠ excludeId 的其它账户 accountId（第一条；无则 nil）。
+ (NSString *)existingAccountIdForData:(NSDictionary *)authData excluding:(NSString *)excludeId {
    NSString *dir = [self accountsDirectoryPath];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (![files isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSString *accountId = [file stringByDeletingPathExtension];
        if (excludeId.length > 0 && [accountId isEqualToString:excludeId]) continue;
        NSMutableDictionary *data = parseJSONFromFile([dir stringByAppendingPathComponent:file]);
        if (data == nil || data[@"NSErrorObject"] != nil) continue;
        if ([self accountData:authData matchesAccountData:data]) {
            return accountId;
        }
    }
    return nil;
}

/// 账户目录（POJAV_HOME/accounts）路径。
+ (NSString *)accountsDirectoryPath {
    return [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
}

/// 目录内与 identityKey 同身份、accountId ≠ excludeId 的其它账户 accountId（第一条；无则 nil）。
+ (NSString *)existingAccountIdForIdentityKey:(NSString *)identityKey excluding:(NSString *)excludeId {
    if (identityKey.length == 0) {
        return nil;
    }
    NSString *dir = [self accountsDirectoryPath];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (![files isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSString *accountId = [file stringByDeletingPathExtension];
        if (excludeId.length > 0 && [accountId isEqualToString:excludeId]) continue;
        NSMutableDictionary *data = parseJSONFromFile([dir stringByAppendingPathComponent:file]);
        if (data == nil || data[@"NSErrorObject"] != nil) continue;
        NSString *key = [self accountIdentityKeyForData:data];
        if (key.length > 0 && [key isEqualToString:identityKey]) {
            return accountId;
        }
    }
    return nil;
}

/// ★ [ACCT-DUP-MS] 存量清理：把目录内**同一账户**的重复文件合并为一条，删除其余。
///
/// 判定用**并查集 + 分层身份信号**（见 accountIdentitySignalsForData:）：两条账户只要共用
/// 任意一条信号（xuid / profileId(uuid) / gamertag+username / local username）即视为同一账户。
/// ⇒ 「有 expiresAt 却缺 xuid 的微软残档」只要 uuid 或 gamertag+username 对得上就能合并。
///
/// 合并策略：每组保留 1 条 —— selected_account 指向者 > 字段最全者 > mtime 最新者；
/// 并把被删条目的**缺失字段回填**到保留条目（不覆盖已有非空值，accountId 除外），写回磁盘。
/// 拿不准的（同为微软、gamertag 相同但 username 不同）**只记日志、一律保留**。
/// **不同 gamertag / 不同 xuid / 不同 profileId 的合法多账号分属不同组 ⇒ 一律不动**。
+ (NSInteger)deduplicateAccountsDirectory {
    NSString *dir = [self accountsDirectoryPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (![files isKindOfClass:[NSArray class]]) {
        return 0;
    }

    // 1) 载入全部有效账户文件（损坏文件不参与，也不删）
    NSMutableArray<NSMutableDictionary *> *nodes = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:file];
        NSMutableDictionary *data = parseJSONFromFile(path);
        if (data == nil || data[@"NSErrorObject"] != nil) continue;
        NSDate *mtime = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: [NSDate distantPast];
        [nodes addObject:[@{
            @"id": [file stringByDeletingPathExtension],
            @"path": path,
            @"data": data,
            @"signals": [NSSet setWithArray:[self accountIdentitySignalsForData:data]],
            @"mtime": mtime,
        } mutableCopy]];
    }
    if (nodes.count < 2) {
        return 0;
    }

    // 2) 并查集：共用任意一条身份信号 ⇒ 同一账户
    NSInteger n = (NSInteger)nodes.count;
    NSMutableArray<NSNumber *> *parent = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        [parent addObject:@(i)];
    }
    for (NSInteger i = 0; i < n; i++) {
        for (NSInteger j = i + 1; j < n; j++) {
            NSSet *si = nodes[i][@"signals"];
            NSSet *sj = nodes[j][@"signals"];
            if (si.count == 0 || sj.count == 0) {
                continue;
            }
            NSString *shared = nil;
            for (NSString *k in si) {
                if ([sj containsObject:k]) { shared = k; break; }
            }
            if (shared == nil) {
                continue;
            }
            // ★ 合并日志：哪个键把哪两条合到一起（便于真机核对）
            NSLog(@"[ACCT-DUP-MS] union by key '%@': %@ <-> %@",
                  shared, nodes[i][@"id"], nodes[j][@"id"]);
            if (ameFindRoot(parent, i) != ameFindRoot(parent, j)) {
                parent[ameFindRoot(parent, j)] = @(ameFindRoot(parent, i));
            }
        }
    }

    // 3) 分组（根 → 成员下标）
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *groupOf = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < n; i++) {
        NSNumber *root = @(ameFindRoot(parent, i));
        NSMutableArray *g = groupOf[root];
        if (g == nil) { g = [NSMutableArray array]; groupOf[root] = g; }
        [g addObject:@(i)];
    }

    // 4) 疑似重复但无法确认 ⇒ 只记日志、保留
    for (NSInteger i = 0; i < n; i++) {
        for (NSInteger j = i + 1; j < n; j++) {
            if (ameFindRoot(parent, i) == ameFindRoot(parent, j)) continue;
            if (ameAccountKind(nodes[i][@"data"]) == 1 && ameAccountKind(nodes[j][@"data"]) == 1) {
                NSString *gti = ameNormString(nodes[i][@"data"][@"xboxGamertag"]);
                NSString *gtj = ameNormString(nodes[j][@"data"][@"xboxGamertag"]);
                if (gti.length > 0 && [gti isEqualToString:gtj]) {
                    NSLog(@"[ACCT-DUP-MS] suspect duplicate but NOT merged (same gamertag '%@', different/absent username): %@ vs %@ => keep both",
                          gti, nodes[i][@"id"], nodes[j][@"id"]);
                }
            }
        }
    }

    // 5) 每组保留一条，其余字段回填后删除
    NSString *selected = getPrefObject(@"internal.selected_account");
    NSArray *scoreKeys = @[@"xuid", @"profileId", @"xboxGamertag", @"username",
                           @"expiresAt", @"profilePicURL", @"uuid", @"authserver", @"clientToken"];
    NSInteger removed = 0;
    for (NSNumber *root in groupOf) {
        NSArray<NSNumber *> *g = groupOf[root];
        if (g.count < 2) continue;

        // 保留优先级：(a) selected_account 指向者 > (b) 字段最全者 > (c) mtime 最新者 > (d) 第一条
        NSInteger keepIdx = g[0].integerValue;
        BOOL keepIsSelected = (selected.length > 0 && [nodes[keepIdx][@"id"] isEqualToString:selected]);
        for (NSNumber *idxN in g) {
            if (selected.length > 0 && [nodes[idxN.integerValue][@"id"] isEqualToString:selected]) {
                keepIdx = idxN.integerValue;
                keepIsSelected = YES;
                break;
            }
        }
        if (!keepIsSelected) {
            NSInteger bestScore = -1;
            for (NSNumber *idxN in g) {
                NSDictionary *d = nodes[idxN.integerValue][@"data"];
                NSInteger score = 0;
                for (NSString *k in scoreKeys) {
                    id v = d[k];
                    if (v != nil && ![v isEqual:@""]) score++;
                }
                NSDictionary *node = nodes[idxN.integerValue];
                if (score > bestScore ||
                    (score == bestScore && [node[@"mtime"] compare:nodes[keepIdx][@"mtime"]] == NSOrderedDescending)) {
                    bestScore = score;
                    keepIdx = idxN.integerValue;
                }
            }
        }

        // 代表信号（用于合并日志）
        NSString *keyLog = nil;
        for (NSNumber *idxN in g) {
            if (idxN.integerValue == keepIdx) continue;
            keyLog = [self sharedSignalBetween:nodes[keepIdx][@"data"] and:nodes[idxN.integerValue][@"data"]];
            if (keyLog.length > 0) break;
        }

        // 字段回填 + 删除其余
        NSMutableDictionary *keepData = nodes[keepIdx][@"data"];
        NSMutableArray<NSString *> *removedIds = [NSMutableArray array];
        BOOL selectedSurvives = NO;
        for (NSNumber *idxN in g) {
            NSInteger idx = idxN.integerValue;
            if ([nodes[idx][@"id"] isEqualToString:selected]) selectedSurvives = YES;
            if (idx == keepIdx) continue;
            NSDictionary *other = nodes[idx][@"data"];
            for (NSString *k in other) {
                if ([k isEqualToString:@"accountId"]) continue;   // accountId 必须保留 keep 的
                id cur = keepData[k];
                id val = other[k];
                BOOL curEmpty = (cur == nil || [cur isEqual:@""]);
                BOOL valEmpty = (val == nil || [val isEqual:@""]);
                if (curEmpty && !valEmpty) {
                    keepData[k] = val;   // ★ 补齐保留条缺失的字段（令牌/头像/xuid…）
                }
            }
            if ([fm removeItemAtPath:nodes[idx][@"path"] error:nil]) {
                removed++;
                [removedIds addObject:nodes[idx][@"id"]];
            }
        }
        saveJSONToFile(keepData, nodes[keepIdx][@"path"]);   // 回填后写回

        NSLog(@"[ACCT-DUP-MS] merged group key=%@ keep=%@ removed(%lu)=%@",
              keyLog.length > 0 ? keyLog : @"(multi)",
              nodes[keepIdx][@"id"], (unsigned long)removedIds.count, removedIds);

        // selected_account 指向被删项 ⇒ 重定向到保留项（同一账户）
        if (selected.length > 0 && !selectedSurvives &&
            ![nodes[keepIdx][@"id"] isEqualToString:selected]) {
            setPrefObject(@"internal.selected_account", nodes[keepIdx][@"id"]);
        }
    }
    if (removed > 0) {
        NSLog(@"[ACCT-DUP-MS] deduplicated accounts directory: removed %ld duplicate file(s)", (long)removed);
    }
    return removed;
}

+ (id)loadSavedName:(NSString *)accountId {
    // accountId 可能是新格式的 accountId，也可能是旧格式的 username（迁移场景）
    NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    NSMutableDictionary *authData = parseJSONFromFile(path);
    if (authData[@"NSErrorObject"] != nil) {
        NSError *error = ((NSError *)authData[@"NSErrorObject"]);
        if (error.code != NSFileReadNoSuchFileError) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
        return nil;
    }

    // 根据账户数据创建对应类型的 authenticator（initWithData 会设置 current 单例）
    // ★ [AUTH-FIX] 分类顺序修正（修「第三方账户被识别成离线/本地」的根因）：
    //   旧码先判 `expiresAt == 0` 就归 LocalAuthenticator —— 但第三方账户的 expiresAt 可能缺失
    //   （多角色登录路径 refreshToBindProfile 历史上不写 expiresAt），于是带 clientToken/authserver
    //   的第三方账户被 loadSavedName 判成 Local(离线) ⇒ BaseAuthenticator.current 不是
    //   ThirdPartyAuthenticator ⇒ 启动时不再注入 authlib-injector ⇒ 游戏内按离线处理。
    //   现改为先按【账户类型标识字段】判定，最后才用 expiresAt==0 兜底判本地；
    //   标识字段缺失的旧档行为不变（仍回落到 expiresAt 判据，兼容读取）。
    BaseAuthenticator *auth = nil;
    if (authData[@"clientToken"] != nil) {
        // 有 clientToken = 第三方(Yggdrasil / authlib-injector)账户
        auth = [[ThirdPartyAuthenticator alloc] initWithData:authData];
    } else if (authData[@"xboxGamertag"] != nil || authData[@"xuid"] != nil) {
        // 有 Xbox 标识 = 微软账户（即便 expiresAt 缺失也不该被当成离线本地账户）
        auth = [[MicrosoftAuthenticator alloc] initWithData:authData];
    } else if ([authData[@"expiresAt"] longValue] == 0) {
        auth = [[LocalAuthenticator alloc] initWithData:authData];
    } else {
        auth = [[MicrosoftAuthenticator alloc] initWithData:authData];
    }

    // 迁移旧格式账户：若 authData 没有 accountId 字段，说明是旧版按 username 命名的账户。
    // 生成 accountId，保存到新文件 <accountId>.json，删除旧文件 <username>.json，
    // 迁移头像文件，并更新 selected_account。
    NSString *existingAccountId = authData[@"accountId"];
    if (existingAccountId == nil || [existingAccountId length] == 0) {
        NSString *newAccountId = [BaseAuthenticator generateAccountIdForData:authData];
        // ★ [ACCT-DUP-MS] 迁移前先按兜底身份键查“同账户”是否已存在：命中则复用其 accountId，
        //   避免旧格式（username 命名 / 缺 xuid）账户迁移时又生成随机 id，冒出第二条同账户记录。
        NSString *migDupId = [BaseAuthenticator existingAccountIdForData:authData excluding:accountId];
        if (migDupId.length > 0) {
            newAccountId = migDupId;
        }
        authData[@"accountId"] = newAccountId;

        NSString *newPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), newAccountId];
        NSError *saveError = saveJSONToFile(authData, newPath);

        if (saveError == nil) {
            // 删除旧文件（如果 accountId 入参与生成的 newAccountId 不同，说明入参是旧 username）
            if (![accountId isEqualToString:newAccountId]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
            // 迁移头像文件：<username>.png → <accountId>.png
            // 头像目录是 <Documents>/avatars/，与账户目录（POJAV_HOME/accounts/）分离
            NSString *username = authData[@"username"];
            if (username && username.length > 0 && ![username isEqualToString:newAccountId]) {
                NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString *oldAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, username];
                NSString *newAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, newAccountId];
                // 仅当旧头像存在且新头像不存在时迁移，避免覆盖
                if ([NSFileManager.defaultManager fileExistsAtPath:oldAvatarPath] &&
                    ![NSFileManager.defaultManager fileExistsAtPath:newAvatarPath]) {
                    [NSFileManager.defaultManager moveItemAtPath:oldAvatarPath toPath:newAvatarPath error:nil];
                }
            }
            // 更新 selected_account：若当前选中的是旧 username/accountId，改为新的 accountId
            if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
                setPrefObject(@"internal.selected_account", newAccountId);
            }
        }
    }

    return auth;
}

- (id)initWithData:(NSMutableDictionary *)data {
    current = self = [self init];
    self.authData = data;
    return self;
}

- (id)initWithInput:(NSString *)string {
    NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
    data[@"input"] = string;
    return [self initWithData:data];
}

- (void)loginWithCallback:(Callback)callback {
}

- (void)refreshTokenWithCallback:(Callback)callback {
}

- (BOOL)saveChanges {
    NSError *error;

    [self.authData removeObjectForKey:@"input"];
    [self.authData removeObjectForKey:@"password"];
    // oldusername 机制已废弃：文件名改用 accountId，username 变更不再需要重命名文件
    [self.authData removeObjectForKey:@"oldusername"];

    // 确保 accountId 存在（首次保存时兜底生成，正常登录流程已在子类设置）
    NSString *accountId = self.authData[@"accountId"];
    if (accountId == nil || [accountId length] == 0) {
        accountId = [BaseAuthenticator generateAccountIdForData:self.authData];
        self.authData[@"accountId"] = accountId;
    }

    // 文件名使用 accountId（唯一标识），同名账户不再冲突
    NSString *accountsDir = [BaseAuthenticator accountsDirectoryPath];
    NSString *newPath = [accountsDir stringByAppendingPathComponent:
        [accountId stringByAppendingPathExtension:@"json"]];

    // ★ [ACCT-DUP-MS] 存储幂等去重（分层身份信号）：先按“兜底身份键”(xuid→profileId(uuid)→gamertag+username)
    //   找“同一账户”的其它文件。命中 ⇒ 这条账户其实已存在（重复提交 / 二次登录 / 缺 xuid 的残档 /
    //   accountId 非确定性）：
    //     · 若本次 accountId 尚未落盘，改为复用既有 accountId —— 收敛到同一文件，避免 append 第二条；
    //     · 无论哪种情况，都删掉那条重复文件。
    //   结果：同一账户**永远只留一条**（即使缺 xuid、只有 gamertag+uuid 也能收敛）。
    NSString *dupId = [BaseAuthenticator existingAccountIdForData:self.authData excluding:accountId];
    if (dupId.length == 0) {
        // 旧主键路径兜底（与上一轮 [ACCT-DUP] 行为一致）
        NSString *identityKey = [BaseAuthenticator accountIdentityKeyForData:self.authData];
        if (identityKey.length > 0) {
            dupId = [BaseAuthenticator existingAccountIdForIdentityKey:identityKey excluding:accountId];
        }
    }
    if (dupId.length > 0) {
        NSString *dupPath = [accountsDir stringByAppendingPathComponent:
            [dupId stringByAppendingPathExtension:@"json"]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
            accountId = dupId;
            self.authData[@"accountId"] = dupId;
            newPath = dupPath;
        }
        if (![dupPath isEqualToString:newPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:dupPath error:nil];
        }
    }

    error = saveJSONToFile(self.authData, newPath);

    if (error != nil) {
        showDialog(@"Error while saving file", error.localizedDescription);
    } else {
        // 保存选中的账户（accountId），确保重启后能恢复登录状态
        setPrefObject(@"internal.selected_account", accountId);
    }
    return error == nil;
}

@end
