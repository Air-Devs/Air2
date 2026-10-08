//
//  A2Wardrobe.m
//  Air2
//
//  见头文件：会话 profile 获取 + 非致命下载 + 单点落盘。
//  只用 Foundation + NSURLSession；PNG 只存 data，不解成 UIImage（Core 禁 UIKit）。
//

#import "A2Wardrobe.h"

NSString *const A2SkinModelClassic = @"classic";
NSString *const A2SkinModelSlim = @"slim";

static NSString *const kMojangSessionHost = @"https://sessionserver.mojang.com";
static NSString *const kWardrobeCacheDir = @"A2Wardrobe";

@implementation A2WardrobeTextures
@end

@implementation A2Wardrobe

+ (NSString *)sessionProfileURLForAccount:(A2Account *)account {
    // UUID 是材质的唯一键，无 UUID（离线未生成/数据损坏）直接不请求。
    NSString *uuid = account.profileID.length ? account.profileID : nil;
    if (!uuid) return nil;
    // 去连字符：Mojang/Yggdrasil 的 profile 接口都要无连字符小写 UUID。
    NSString *bare = [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    if (bare.length == 0) return nil;

    NSString *host = nil;
    if (account.type == A2AccountTypeThirdParty && account.authServerURL.length) {
        host = [account.authServerURL stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    } else if (account.type == A2AccountTypeMicrosoft) {
        host = kMojangSessionHost;
    } else {
        // 离线账号无远端材质。
        return nil;
    }
    if (host.length == 0) return nil;
    return [NSString stringWithFormat:@"%@/session/minecraft/profile/%@", host, bare];
}

+ (A2WardrobeTextures *)parseSessionProfileJSON:(NSString *)profileJSON
                                          error:(NSError **)error {
    // 两层 JSON：外层 properties[0].value 是 base64，内层才是 textures。
    // 任何一层缺字段都按“无材质”处理，不抛错（调用方用占位即可）。
    NSData *outerData = [profileJSON dataUsingEncoding:NSUTF8StringEncoding];
    if (!outerData) {
        if (error) *error = [NSError errorWithDomain:@"A2Wardrobe" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"profile 不是 UTF-8"}];
        return nil;
    }
    NSDictionary *outer = [NSJSONSerialization JSONObjectWithData:outerData options:0 error:error];
    if (![outer isKindOfClass:NSDictionary.class]) return nil;
    NSArray *props = outer[@"properties"];
    if (![props isKindOfClass:NSArray.class] || props.count == 0) return nil;
    NSDictionary *first = props.firstObject;
    if (![first isKindOfClass:NSDictionary.class]) return nil;
    NSString *b64 = first[@"value"];
    if (![b64 isKindOfClass:NSString.class] || b64.length == 0) return nil;

    NSData *innerData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!innerData) {
        if (error) *error = [NSError errorWithDomain:@"A2Wardrobe" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"textures 不是合法 base64"}];
        return nil;
    }
    NSDictionary *inner = [NSJSONSerialization JSONObjectWithData:innerData options:0 error:error];
    if (![inner isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *textures = inner[@"textures"];
    if (![textures isKindOfClass:NSDictionary.class]) return nil;

    A2WardrobeTextures *out = [A2WardrobeTextures new];
    NSDictionary *skin = textures[@"SKIN"];
    if ([skin isKindOfClass:NSDictionary.class]) {
        id url = skin[@"url"];
        if ([url isKindOfClass:NSString.class]) out.skinURL = url;
        // 只有 slim 显式标记，其余（含 classic/缺省）一律按 classic 处理。
        NSDictionary *meta = skin[@"metadata"];
        NSString *model = [meta isKindOfClass:NSDictionary.class] ? meta[@"model"] : nil;
        out.skinModel = ([model isKindOfClass:NSString.class] &&
                         [model caseInsensitiveCompare:@"slim"] == NSOrderedSame)
            ? A2SkinModelSlim : A2SkinModelClassic;
    }
    NSDictionary *cape = textures[@"CAPE"];
    if ([cape isKindOfClass:NSDictionary.class]) {
        id url = cape[@"url"];
        if ([url isKindOfClass:NSString.class]) out.capeURL = url;
    }
    return out;
}

#pragma mark - 落盘

// 全部材质缓存的唯一出口（调用方禁止手写 Caches 路径）。
- (NSString *)directoryForUUID:(NSString *)uuid {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = paths.firstObject ?: NSTemporaryDirectory();
    // uuid 已去连字符小写，目录名安全。
    NSString *bare = [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    return [[caches stringByAppendingPathComponent:kWardrobeCacheDir]
            stringByAppendingPathComponent:bare.length ? bare : @"unknown"];
}

- (void)refreshWardrobeForAccount:(A2Account *)account
                       completion:(void (^)(BOOL, NSError *))completion {
    void (^doneOnMain)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        if ([NSThread isMainThread]) completion(ok, err);
        else dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, err); });
    };

    NSString *profileURL = [A2Wardrobe sessionProfileURLForAccount:account];
    // 无远端（离线/缺 UUID）：不算失败，UI 用占位即可。
    if (!profileURL) {
        doneOnMain(YES, nil);
        return;
    }

    NSURLSession *session = NSURLSession.sharedSession;
    NSURL *url = [NSURL URLWithString:profileURL];
    if (!url) {
        doneOnMain(YES, nil);
        return;
    }
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            // 网络失败非致命：保留旧皮肤。
            doneOnMain(YES, nil);
            return;
        }
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!json) {
            doneOnMain(YES, nil);
            return;
        }
        NSError *parseErr = nil;
        A2WardrobeTextures *tex = [A2Wardrobe parseSessionProfileJSON:json error:&parseErr];
        if (!tex) {
            doneOnMain(YES, nil);
            return;
        }
        // 先记模型（即使图片下载失败，模型也可用）。
        if (tex.skinModel) account.skinModel = tex.skinModel;

        NSString *dir = [self directoryForUUID:account.profileID];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES attributes:nil error:nil];

        dispatch_group_t g = dispatch_group_create();
        // skin/cape 各自失败都不影响整体（ZL2 同款：记日志不上抛）。
        if (tex.skinURL) {
            dispatch_group_enter(g);
            [self downloadURLString:tex.skinURL toPath:[dir stringByAppendingPathComponent:@"skin.png"]
                         completion:^(BOOL ok) {
                if (ok) account.skinPath = [dir stringByAppendingPathComponent:@"skin.png"];
                dispatch_group_leave(g);
            }];
        }
        if (tex.capeURL) {
            dispatch_group_enter(g);
            [self downloadURLString:tex.capeURL toPath:[dir stringByAppendingPathComponent:@"cape.png"]
                         completion:^(BOOL ok) {
                if (ok) account.capePath = [dir stringByAppendingPathComponent:@"cape.png"];
                dispatch_group_leave(g);
            }];
        }
        dispatch_group_notify(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            doneOnMain(YES, nil);
        });
    }] resume];
}

// 单文件下载：半成品写 .part，成功后原子替换；失败删 .part 保留旧文件。
- (void)downloadURLString:(NSString *)urlString
                   toPath:(NSString *)dest
               completion:(void (^)(BOOL))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(NO);
        return;
    }
    NSString *part = [dest stringByAppendingString:@".part"];
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        if (err || !loc) {
            [NSFileManager.defaultManager removeItemAtPath:part error:nil];
            completion(NO);
            return;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:part error:nil];
        NSError *moveErr = nil;
        // 先落 .part 再搬，避免半截 PNG 覆盖好文件。
        if (![fm moveItemAtPath:loc.path toPath:part error:&moveErr]) {
            completion(NO);
            return;
        }
        [fm removeItemAtPath:dest error:nil];
        if (![fm moveItemAtPath:part toPath:dest error:nil]) {
            [fm removeItemAtPath:part error:nil];
            completion(NO);
            return;
        }
        completion(YES);
    }] resume];
}

@end
