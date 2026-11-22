//
//  A2LogUploader.m
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

#import "A2LogUploader.h"

NSString *const A2LogUploaderErrorDomain = @"A2LogUploaderErrorDomain";

// ---------------------------------------------------------------- 服务表

static NSString *const kMCLogsAPI  = @"https://api.mclo.gs/1/log";
static NSString *const kMCLogsRoot = @"https://mclo.gs";
static NSString *const kMirrorAPI  = @"https://api.logshare.cn/1/log";
static NSString *const kMirrorRoot = @"https://logshare.cn";

/// 默认截断大小。日志服务对超大 body 会直接 413，而且崩溃现场在文件末尾，
/// 所以只取尾部。512 KB 足够覆盖一次完整启动 + 崩溃栈。
static const NSUInteger kDefaultMaxBytes = 512 * 1024;

#pragma mark - 结果对象

@interface A2LogShareResult ()
@property (nonatomic, copy, readwrite, nullable) NSString *url;
@property (nonatomic, copy, readwrite, nullable) NSString *logID;
@property (nonatomic, assign, readwrite) A2LogShareProvider provider;
@property (nonatomic, strong, readwrite, nullable) NSError *error;
@end

@implementation A2LogShareResult
@end

#pragma mark - 上传器

@interface A2LogUploader ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation A2LogUploader

+ (NSURLSession *)sharedSession {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 60;
        // 日志上传不需要 cookie 缓存
        cfg.HTTPCookieStorage = nil;
        cfg.URLCache = nil;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

+ (NSString *)rootURLStringForProvider:(A2LogShareProvider)provider {
    return (provider == A2LogShareProviderMirrored) ? kMirrorRoot : kMCLogsRoot;
}

+ (NSString *)apiURLStringForProvider:(A2LogShareProvider)provider {
    return (provider == A2LogShareProviderMirrored) ? kMirrorAPI : kMCLogsAPI;
}

+ (void)uploadLogContent:(NSString *)content
                provider:(A2LogShareProvider)provider
              completion:(void (^)(A2LogShareResult *result))completion {
    NSAssert(completion != nil, @"completion 不能为 nil");

    // 空内容直接失败，不去打网络
    if (content.length == 0) {
        A2LogShareResult *r = [A2LogShareResult new];
        r.provider = provider;
        r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                     code:A2LogUploaderErrorEmptyContent
                                 userInfo:@{NSLocalizedDescriptionKey: @"日志为空，无法上传"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
        return;
    }

    if (provider == A2LogShareProviderAutomatic) {
        // 先 mclo.gs；失败再试镜像。两次都失败才报错。
        [self uploadLogContent:content provider:A2LogShareProviderMCLogs completion:^(A2LogShareResult *first) {
            if (first.url != nil) { completion(first); return; }
            [self uploadLogContent:content provider:A2LogShareProviderMirrored completion:^(A2LogShareResult *second) {
                if (second.url != nil) { completion(second); return; }
                // 两个都失败：把第一次的错误留着（通常更贴近真实原因）
                A2LogShareResult *r = [A2LogShareResult new];
                r.provider = A2LogShareProviderMCLogs;
                r.error = first.error;
                completion(r);
            }];
        }];
        return;
    }

    NSString *api = [self apiURLStringForProvider:provider];
    NSURL *url = [NSURL URLWithString:api];
    if (url == nil) {
        A2LogShareResult *r = [A2LogShareResult new];
        r.provider = provider;
        r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                     code:A2LogUploaderErrorTransport
                                 userInfo:@{NSLocalizedDescriptionKey: @"上传地址无效"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8"
        forHTTPHeaderField:@"Content-Type"];
    // 服务端要求 form 字段 content。<内容>按 urlencoded 转义，中文日志也不会坏。
    NSString *encoded = [self formEncode:content];
    NSString *body = [@"content=" stringByAppendingString:encoded];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task =
        [[self sharedSession] dataTaskWithRequest:req
                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            A2LogShareResult *r = [A2LogShareResult new];
            r.provider = provider;

            if (err != nil) {
                r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                              code:A2LogUploaderErrorTransport
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         err.localizedDescription ?: @"网络请求失败",
                                                     NSUnderlyingErrorKey: err}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
                return;
            }

            NSInteger status = 0;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                status = ((NSHTTPURLResponse *)resp).statusCode;
            }
            if (status < 200 || status >= 300) {
                r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                              code:A2LogUploaderErrorTransport
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         [NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)status]}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
                return;
            }

            // 响应：{ "success": true, "url": "...", "id": "...", "error": "..." }
            id json = nil;
            if (data.length > 0) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            }
            if (![json isKindOfClass:[NSDictionary class]]) {
                r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                              code:A2LogUploaderErrorRejected
                                          userInfo:@{NSLocalizedDescriptionKey: @"服务器响应无法解析"}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
                return;
            }

            NSDictionary *dict = (NSDictionary *)json;
            BOOL ok = [dict[@"success"] respondsToSelector:@selector(boolValue)]
                        ? [dict[@"success"] boolValue] : NO;
            NSString *shareURL = [dict[@"url"] isKindOfClass:[NSString class]] ? dict[@"url"] : nil;
            NSString *logID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : nil;
            NSString *serverError = [dict[@"error"] isKindOfClass:[NSString class]] ? dict[@"error"] : nil;

            if (ok && shareURL.length > 0) {
                r.url = shareURL;
                r.logID = logID;
            } else if (logID.length > 0) {
                // 有些部署只回 id 不回 url，按 root 拼一个
                r.logID = logID;
                r.url = [[self rootURLStringForProvider:provider]
                            stringByAppendingFormat:@"/%@", logID];
            } else {
                r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                              code:A2LogUploaderErrorRejected
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         serverError ?: @"服务器拒绝接收日志"}];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
        }];
    [task resume];
}

+ (void)uploadLogFileAtPath:(NSString *)path
                   provider:(A2LogShareProvider)provider
                 completion:(void (^)(A2LogShareResult *result))completion {
    if (path.length == 0) {
        A2LogShareResult *r = [A2LogShareResult new];
        r.provider = provider;
        r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                     code:A2LogUploaderErrorEmptyContent
                                 userInfo:@{NSLocalizedDescriptionKey: @"日志路径为空"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
        return;
    }

    // 尾部读取：崩溃现场在文件末尾，且避免把几十 MB 全读进内存。
    NSString *tail = [self tailOfFile:path maxBytes:kDefaultMaxBytes error:NULL];
    if (tail.length == 0) {
        A2LogShareResult *r = [A2LogShareResult new];
        r.provider = provider;
        r.error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                     code:A2LogUploaderErrorEmptyContent
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                @"日志文件不存在或为空"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
        return;
    }
    [self uploadLogContent:tail provider:provider completion:completion];
}

#pragma mark - 工具

/// 只读文件尾部 maxBytes 字节；截断点尽量落在行边界，避免首行残缺。
+ (nullable NSString *)tailOfFile:(NSString *)path maxBytes:(NSUInteger)maxBytes error:(NSError **)error {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) {
        if (error) {
            *error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                         code:A2LogUploaderErrorEmptyContent
                                     userInfo:@{NSLocalizedDescriptionKey: @"打不开日志文件"}];
        }
        return nil;
    }

    NSData *data = nil;
    @try {
        unsigned long long size = [fh seekToEndOfFile];
        if (size == 0) { [fh closeFile]; return nil; }
        unsigned long long start = (size > maxBytes) ? (size - maxBytes) : 0;
        [fh seekToFileOffset:start];
        data = [fh readDataToEndOfFile];
        [fh closeFile];
    } @catch (NSException *e) {
        @try { [fh closeFile]; } @catch (__unused NSException *e2) {}
        if (error) {
            *error = [NSError errorWithDomain:A2LogUploaderErrorDomain
                                         code:A2LogUploaderErrorTransport
                                     userInfo:@{NSLocalizedDescriptionKey: @"读取日志失败"}];
        }
        return nil;
    }

    if (data.length == 0) return nil;

    // 截断点可能落在多字节字符中间：UTF-8 解不出就退到 Latin-1（日志可读性优先）
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (body == nil) {
        body = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (body.length == 0) return nil;

    BOOL truncated = (data.length >= maxBytes);
    if (truncated) {
        // 丢掉首个换行前的半截行
        NSRange nl = [body rangeOfString:@"\n"];
        if (nl.location != NSNotFound) {
            body = [body substringFromIndex:nl.location + 1];
        }
        return [NSString stringWithFormat:@"[Air2] 日志过大，仅上传尾部 %lu KB\n%@",
                (unsigned long)(maxBytes / 1024), body];
    }
    return body;
}

/// application/x-www-form-urlencoded 转义。
/// 注意不能直接用 stringByAddingPercentEncodingWithAllowedCharacters +
/// URLQueryAllowedCharacterSet —— 那个集合里包含 & 和 =，会把表单拆坏。
+ (NSString *)formEncode:(NSString *)raw {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *escaped = [raw stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return escaped ?: @"";
}

@end
