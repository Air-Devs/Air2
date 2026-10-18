#import "utils.h"
#import "UpdateChecker.h"
#import "UpdateDialogViewController.h"
#import "LauncherPreferences.h"
#import <UIKit/UIKit.h>

#pragma mark - JSON 取值工具

/// GitHub API 的字段在"作者没填"时会返回 JSON null，Foundation 解析为 NSNull。
/// 早期实现直接把 json[@"name"] 赋给 NSString* 属性，随后 .length / stringWithFormat
/// 会向 NSNull 发消息而崩溃，或把 "(null)" 显示给用户。这里统一收敛为 nil。
static NSString * _Nullable AMEUpdateString(id _Nullable value) {
    if (value == nil || [value isKindOfClass:[NSNull class]]) return nil;
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSNumber * _Nullable AMEUpdateNumber(id _Nullable value) {
    if (value == nil || [value isKindOfClass:[NSNull class]]) return nil;
    if ([value isKindOfClass:[NSNumber class]]) return (NSNumber *)value;
    if ([value isKindOfClass:[NSString class]]) {
        NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
        f.numberStyle = NSNumberFormatterDecimalStyle;
        return [f numberFromString:(NSString *)value];
    }
    return nil;
}

static NSString *AMENonEmpty(NSString * _Nullable s, NSString *fallback) {
    return (s.length > 0) ? s : fallback;
}

#pragma mark - UpdateInfo

@implementation UpdateInfo
@end

#pragma mark - UpdateChecker

@interface UpdateChecker ()
+ (void)presentSimpleAlertWithTitle:(NSString *)title
                            message:(NSString *)message
                      fromPresenter:(UIViewController *)presenter;
+ (BOOL)hasUpdateBetweenCurrent:(NSString *)current latest:(NSString *)latest;
+ (void)fetchLatestReleaseJSON:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion;
@end

@implementation UpdateChecker

+ (NSString *)repoOwner { return @"herbrine8403"; }
+ (NSString *)repoName { return @"Amethyst-iOS-MyRemastered"; }

+ (NSString *)latestReleaseURL {
    /* /releases/latest 接口自动返回最新的非 pre-release（正式版） */
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
            self.repoOwner, self.repoName];
}

+ (NSString *)releaseListURL {
    /* 回退接口：仓库只有 pre-release 时 /releases/latest 返回 404 */
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases?per_page=1",
            self.repoOwner, self.repoName];
}

+ (NSString *)currentVersion {
    NSString *v = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if (v == nil) v = @"";
    /* 当前版本号可能是 "5.0.0 Preview"，提取数字部分用于比较 */
    return v;
}

#pragma mark - 偏好键

+ (BOOL)autoCheckEnabled {
    id value = getPrefObject(@"general.auto_check_update");
    if (value == nil || [value isKindOfClass:[NSNull class]]) {
        /* 键不存在时"默认开启"，并立即落盘 —— 否则设置页开关读到的缺省值 NO
           与这里的行为不一致，用户会看到开关是关的、但启动时照样在检查。 */
        setPrefBool(@"general.auto_check_update", YES);
        return YES;
    }
    return getPrefBool(@"general.auto_check_update");
}

+ (NSTimeInterval)minimumCheckInterval {
    /* 与 ZL2 一致：启动检查 1 小时限频 */
    return 3600.0;
}

+ (NSTimeInterval)lastCheckTime {
    id value = getPrefObject(@"general.last_update_check");
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue];
    return 0.0;
}

+ (void)setLastCheckTime:(NSTimeInterval)time {
    setPrefObject(@"general.last_update_check", @(time));
}

+ (BOOL)isWithinRateLimit:(NSTimeInterval)interval {
    NSTimeInterval last = [self lastCheckTime];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    /* 用户把系统时间调到了过去/未来时无法正常判断，直接放行 */
    if (last <= 0 || last > now) return NO;
    return (now - last) < interval;
}

+ (void)skipVersion:(nullable NSString *)version {
    if (version.length == 0) {
        setPrefObject(@"general.skipped_update_version", @"");
        return;
    }
    setPrefObject(@"general.skipped_update_version", version);
}

+ (NSString *)skippedVersion {
    return AMEUpdateString(getPrefObject(@"general.skipped_update_version"));
}

#pragma mark - Check For Update

+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion {
    [self checkForUpdateIgnoringSkipped:NO completion:completion];
}

+ (void)checkForUpdateIgnoringSkipped:(BOOL)ignoreSkipped
                           completion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion {
    [self fetchLatestReleaseJSON:^(NSDictionary * _Nullable json, NSError * _Nullable error) {
        if (error != nil || json == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        UpdateInfo *info = [self parseReleaseJSON:json];
        if (info == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1050", nil)}]);
            });
            return;
        }
        /* 已忽略的版本：启动检查静默跳过，手动检查照样返回（由调用方决定是否展示） */
        if (ignoreSkipped && info.hasUpdate) {
            NSString *skipped = [self skippedVersion];
            if (skipped.length > 0 && [skipped isEqualToString:info.latestVersion]) {
                NSLog(@"[UpdateChecker] Update %@ available but skipped by user", info.latestVersion);
                info.hasUpdate = NO;
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(info, nil);
        });
    }];
}

/// 取最新 release 的 JSON。先试 /releases/latest，404 时回退到 /releases 列表首条。
+ (void)fetchLatestReleaseJSON:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    [self performJSONRequestWithURLString:self.latestReleaseURL completion:^(id jsonObject, NSInteger statusCode, NSError *error) {
        if ([jsonObject isKindOfClass:[NSDictionary class]]) {
            completion((NSDictionary *)jsonObject, nil);
            return;
        }
        if (statusCode == 404) {
            /* 仓库可能只发过 pre-release，/releases/latest 会 404 */
            NSLog(@"[UpdateChecker] /releases/latest returned 404, falling back to release list");
            [self performJSONRequestWithURLString:self.releaseListURL completion:^(id jsonObject2, NSInteger statusCode2, NSError *error2) {
                if ([jsonObject2 isKindOfClass:[NSArray class]] && [(NSArray *)jsonObject2 count] > 0) {
                    id first = [(NSArray *)jsonObject2 firstObject];
                    if ([first isKindOfClass:[NSDictionary class]]) {
                        completion((NSDictionary *)first, nil);
                        return;
                    }
                }
                completion(nil, error2 ?: error);
            }];
            return;
        }
        completion(nil, error);
    }];
}

+ (void)performJSONRequestWithURLString:(NSString *)urlStr
                             completion:(void(^)(id _Nullable jsonObject, NSInteger statusCode, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) {
        completion(nil, -1, [NSError errorWithDomain:@"UpdateChecker" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1048", nil)}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    /* GitHub API 要求 User-Agent 头，否则可能被拒绝 */
    [request setValue:@"Amethyst-iOS-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, -1, error);
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSInteger code = httpResp.statusCode;
        if (code != 200 || data == nil) {
            completion(nil, code, [NSError errorWithDomain:@"UpdateChecker" code:code
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:localize(@"i18n_str_1049", nil), (long)code]}]);
            return;
        }
        id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (jsonObject == nil) {
            completion(nil, code, [NSError errorWithDomain:@"UpdateChecker" code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_444", nil)}]);
            return;
        }
        completion(jsonObject, code, nil);
    }];
    [task resume];
}

/// 解析 GitHub Releases API 返回的 JSON
+ (UpdateInfo *)parseReleaseJSON:(NSDictionary *)json {
    UpdateInfo *info = [[UpdateInfo alloc] init];
    info.currentVersion = self.currentVersion;

    /* tag_name 通常是 "v5.0.1" 或 "5.0.1" */
    NSString *tag = AMEUpdateString(json[@"tag_name"]);
    if (tag.length == 0) return nil;
    info.tagName = tag;
    info.latestVersion = [self normalizeVersion:tag];

    info.releaseName = AMEUpdateString(json[@"name"]);
    info.releaseNotes = AMEUpdateString(json[@"body"]);
    info.htmlURL = AMEUpdateString(json[@"html_url"]);
    info.publishedAt = AMEUpdateString(json[@"published_at"]);
    info.isPrerelease = [AMEUpdateNumber(json[@"prerelease"]) boolValue];

    /* assets 数组 */
    NSArray *assets = json[@"assets"];
    if ([assets isKindOfClass:[NSArray class]]) {
        NSMutableArray *assetList = [NSMutableArray array];
        for (NSDictionary *a in assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            [assetList addObject:@{
                @"name": AMENonEmpty(AMEUpdateString(a[@"name"]), @""),
                @"url": AMENonEmpty(AMEUpdateString(a[@"browser_download_url"]), @""),
                @"size": AMEUpdateNumber(a[@"size"]) ?: @(0),
                @"contentType": AMENonEmpty(AMEUpdateString(a[@"content_type"]), @"")
            }];
        }
        info.assets = assetList;
    }

    info.hasUpdate = [self hasUpdateBetweenCurrent:info.currentVersion latest:info.latestVersion];
    return info;
}

/// 版本比较。
///
/// 修复：旧实现在 tag 不是纯数字（例如历史 tag "第四版（第三方认证账户支持）"）时，
/// extractVersionNumbers 取不到数字，就退化成字符串不等比较 —— 结果 hasUpdate 恒为 YES，
/// 每次启动都弹更新。这里改为：任一版本号无法解析出数字段时判定"无更新"，
/// 宁可不打扰，也不误报。
+ (BOOL)hasUpdateBetweenCurrent:(NSString *)current latest:(NSString *)latest {
    NSString *currentNum = [self extractVersionNumbers:current];
    NSString *latestNum = [self extractVersionNumbers:latest];
    if (currentNum.length == 0 || latestNum.length == 0) {
        NSLog(@"[UpdateChecker] Unparsable version (current=%@ latest=%@), assuming no update", current, latest);
        return NO;
    }
    return ([self compareVersion:currentNum withVersion:latestNum] == NSOrderedAscending);
}

/// 去掉版本号前面的 "v" 或 "V" 前缀
+ (NSString *)normalizeVersion:(NSString *)tag {
    if (tag == nil) return @"";
    NSString *v = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([v hasPrefix:@"v"] || [v hasPrefix:@"V"]) {
        v = [v substringFromIndex:1];
    }
    return v;
}

/// 从版本字符串中提取数字部分（如 "5.0.0 Preview" → "5.0.0"），提取不到返回 nil
+ (NSString *)extractVersionNumbers:(NSString *)version {
    if (version.length == 0) return nil;
    NSError *err = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([0-9]+(\\.[0-9]+)*)"
                            options:0 error:&err];
    if (regex == nil) return nil;
    NSTextCheckingResult *match = [regex firstMatchInString:version
                                                    options:0
                                                      range:NSMakeRange(0, version.length)];
    if (match == nil) return nil;
    NSString *found = [version substringWithRange:[match rangeAtIndex:1]];
    return found.length > 0 ? found : nil;
}

#pragma mark - Version Comparison

+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2 {
    /* 容错：nil 或空字符串视为 "0" */
    if (v1.length == 0) v1 = @"0";
    if (v2.length == 0) v2 = @"0";

    NSArray *c1 = [v1 componentsSeparatedByString:@"."];
    NSArray *c2 = [v2 componentsSeparatedByString:@"."];
    NSInteger max = MAX(c1.count, c2.count);

    for (NSInteger i = 0; i < max; i++) {
        /* 非数字段（如 "Beta"）按 0 处理 */
        NSInteger n1 = (i < c1.count) ? [c1[i] integerValue] : 0;
        NSInteger n2 = (i < c2.count) ? [c2[i] integerValue] : 0;
        if (n1 < n2) return NSOrderedAscending;
        if (n1 > n2) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark - 启动检查 / 手动检查

+ (void)performStartupCheckFromPresenter:(UIViewController *)presenter {
    if (![self autoCheckEnabled]) {
        NSLog(@"[UpdateChecker] Startup check disabled by preference");
        return;
    }
    if ([self isWithinRateLimit:[self minimumCheckInterval]]) {
        NSLog(@"[UpdateChecker] Startup check within rate limit, skipping");
        return;
    }
    /* 先落时间戳：避免同一次启动里多处调用重复发请求 */
    [self setLastCheckTime:[[NSDate date] timeIntervalSince1970]];

    [self checkForUpdateIgnoringSkipped:YES completion:^(UpdateInfo *info, NSError *error) {
        if (error != nil || info == nil) {
            NSLog(@"[UpdateChecker] Startup check failed: %@", error.localizedDescription);
            return;
        }
        if (!info.hasUpdate) {
            NSLog(@"[UpdateChecker] Launcher is up to date (%@)", info.currentVersion);
            return;
        }
        NSLog(@"[UpdateChecker] Update detected: %@ -> %@", info.currentVersion, info.latestVersion);
        [self presentUpdateDialogForInfo:info fromPresenter:presenter];
    }];
}

+ (void)performManualCheckFromPresenter:(UIViewController *)presenter
                           showUpToDate:(BOOL)showUpToDate {
    /* 5 秒防连点（对齐 ZL2 手动检查的限频） */
    if ([self isWithinRateLimit:5.0]) {
        NSLog(@"[UpdateChecker] Manual check too frequent, ignoring");
        return;
    }
    [self setLastCheckTime:[[NSDate date] timeIntervalSince1970]];

    [self checkForUpdateIgnoringSkipped:NO completion:^(UpdateInfo *info, NSError *error) {
        if (error != nil || info == nil) {
            NSString *msg = error.localizedDescription ?: localize(@"i18n_str_97", nil);
            [self presentSimpleAlertWithTitle:localize(@"check_update.failed", @"Update check failed")
                                      message:msg
                                fromPresenter:presenter];
            return;
        }
        if (info.hasUpdate) {
            [self presentUpdateDialogForInfo:info fromPresenter:presenter];
            return;
        }
        if (showUpToDate) {
            NSString *msg = [NSString stringWithFormat:
                localize(@"check_update.current_version", @"Current version %@ is the latest stable release."),
                AMENonEmpty(info.currentVersion, @"-")];
            [self presentSimpleAlertWithTitle:localize(@"check_update.up_to_date", @"Up to date")
                                      message:msg
                                fromPresenter:presenter];
        }
    }];
}

+ (void)presentSimpleAlertWithTitle:(NSString *)title
                            message:(NSString *)message
                      fromPresenter:(UIViewController *)presenter {
    if (presenter == nil) return;
    if (presenter.presentedViewController != nil) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)presentUpdateDialogForInfo:(UpdateInfo *)info fromPresenter:(UIViewController *)presenter {
    if (presenter == nil || info == nil) return;
    if (presenter.presentedViewController != nil) {
        /* 已有弹窗在屏幕上（例如首次启动的翻译提示）时不能直接叠加，
           延后一拍重试一次；仍被占用就放弃，下次启动再说。 */
        NSLog(@"[UpdateChecker] Another modal already presented, retrying update dialog in 3s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (presenter.presentedViewController != nil) {
                NSLog(@"[UpdateChecker] Still busy, skipping update dialog");
                return;
            }
            UpdateDialogViewController *retryDialog = [UpdateDialogViewController dialogWithInfo:info];
            [presenter presentViewController:retryDialog animated:YES completion:nil];
        });
        return;
    }
    UpdateDialogViewController *dialog = [UpdateDialogViewController dialogWithInfo:info];
    [presenter presentViewController:dialog animated:YES completion:nil];
}

#pragma mark - Open Release Page

+ (void)openReleasePageForInfo:(nullable UpdateInfo *)info {
    NSString *urlStr = info.htmlURL;
    if (urlStr.length == 0) {
        /* 回退到固定的 /releases/latest */
        urlStr = [NSString stringWithFormat:@"https://github.com/%@/%@/releases/latest",
                  self.repoOwner, self.repoName];
    }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if ([app canOpenURL:url]) {
            [app openURL:url options:@{} completionHandler:nil];
        }
    });
}

+ (void)openReleasePage {
    [self openReleasePageForInfo:nil];
}

@end
