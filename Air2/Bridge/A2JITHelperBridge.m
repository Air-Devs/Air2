//
//  A2JITHelperBridge.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— 主 App 侧拉起内建 JIT helper appex 的实现。
//  结构对照 Henge ios/Henge/JIT/JITBuiltIn.swift:1-186（GPL-2.0-or-later）：
//    · 私有 NSExtension 协议 shim  ← JITBuiltIn.swift:7-23
//    · helper 的 bundle id 从包内 Info.plist 现取 ← JITBuiltIn.swift:61-64
//    · 一个请求一个会话对象、完成后从 running 列表移除 ← JITBuiltIn.swift:101-110 / 173-181
//    · 三个回调块（completion/cancellation/interruption）← JITBuiltIn.swift:130-145
//  与 Henge 的差别只有语言（ObjC vs Swift）与命名；调用序列一一对应。
//

#import "A2JITHelperBridge.h"

#import <TargetConditionals.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>   // getpid()：日志里对照 helper 进程与主进程

NSString *const A2JITHelperErrorDomain = @"A2JITHelperBridge";
NSString *const A2JITHelperBundleName = @"Air2JITHelper.appex";
NSString *const A2JITHelperRequestItemKey = @"henge-jit-request";
NSString *const A2JITHelperResponseItemKey = @"henge-jit-response";
NSString *const A2JITHelperResponseSuccessKey = @"success";
NSString *const A2JITHelperResponseMessageKey = @"message";
NSString *const A2JITHelperResponseCodeKey = @"code";
NSString *const A2JITHelperResponseTXMPresentKey = @"txmPresent";

static NSError *A2JITHelperError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:A2JITHelperErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"(no reason)"}];
}

// ---------------------------------------------------------------------------
// 私有 NSExtension API（ExtensionFoundation）。
//  ★iOS 26 才有这个类★，所以只能用 NSClassFromString 取、用本地协议描述消息形状；
//  绝不能在头文件里 #import 它（没有公开头）。
//  消息签名与 Henge JITBuiltIn.swift:12-23 的 @objc protocol 逐条一致。
// ---------------------------------------------------------------------------
@protocol A2JITNSExtensionClass <NSObject>
/// `+[NSExtension extensionWithIdentifier:error:]`
+ (nullable id)extensionWithIdentifier:(NSString *)identifier
                                 error:(NSError *_Nullable *_Nullable)error;
@end

@protocol A2JITNSExtension <NSObject>
/// `-beginExtensionRequestWithInputItems:completion:`（completion 收到的 NSUUID 是 request identifier）
- (void)beginExtensionRequestWithInputItems:(NSArray *)items
                                 completion:(void (^)(NSUUID *_Nullable requestIdentifier))completion;
/// `-pidForRequestIdentifier:`（helper 进程的 pid，只用于日志判据）
- (int32_t)pidForRequestIdentifier:(NSUUID *)requestIdentifier;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *_Nullable requestIdentifier,
                                            NSArray *_Nullable returnedItems))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *_Nullable requestIdentifier,
                                              NSError *_Nullable error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *_Nullable requestIdentifier))block;
@end

/// 尽量把 ExtensionFoundation 拉进来 —— 低版本上它不存在，所以判否不报错。
/// 调用点：`+unavailableReason`（唯一）。
static void A2JITHelperLoadExtensionFramework(void) {
    if (NSClassFromString(@"NSExtension") != nil) return;
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
}

// ---------------------------------------------------------------------------
// 一次请求 = 一个会话对象。
// ★为什么必须有个对象撑着★：`enable` 请求要挂到 helper 反向 attach 完并 detach 为止
// （几十秒），期间 NSExtension 实例、三个回调块、调用方的 completion 都不能被释放；
// Henge 用 `running: [HelperRequest]`（JITBuiltIn.swift:42）做同一件事，这里用数组 + 全局表。
// 会话全部在主线程创建 / 结束（Henge 用 @MainActor 表达了同一约束）。
// ---------------------------------------------------------------------------
@interface A2JITHelperSession : NSObject
@property (nonatomic, strong, readonly) id extensionObject;
@property (nonatomic, strong, readonly) id<A2JITNSExtension> extension;
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *operation;
@property (nonatomic, copy, nullable) void (^completion)(NSDictionary<NSString *, id> *_Nullable,
                                                         NSError *_Nullable);
- (instancetype)initWithExtension:(id)extensionObject
                       identifier:(NSString *)identifier
                        operation:(NSString *)operation
                       completion:(void (^)(NSDictionary<NSString *, id> *_Nullable,
                                            NSError *_Nullable))completion;
- (void)beginWithRequestData:(NSData *)requestData;
- (void)finishWithResponse:(nullable NSDictionary<NSString *, id> *)response
                     error:(nullable NSError *)error;
@end

/// 活着的会话（保活表）。调用点：`+startWithRequestData:` 加、`finishWithResponse:` 删。
static NSMutableArray<A2JITHelperSession *> *A2JITHelperSessions(void) {
    static NSMutableArray<A2JITHelperSession *> *sessions = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sessions = [NSMutableArray array];
    });
    return sessions;
}

@implementation A2JITHelperSession

- (instancetype)initWithExtension:(id)extensionObject
                       identifier:(NSString *)identifier
                        operation:(NSString *)operation
                       completion:(void (^)(NSDictionary<NSString *, id> *_Nullable,
                                            NSError *_Nullable))completion {
    self = [super init];
    if (self) {
        _extensionObject = extensionObject;   // ★强引用★：NSExtension 没了，请求就没了
        _extension = (id<A2JITNSExtension>)extensionObject;
        _identifier = [identifier copy];
        _operation = [operation copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)beginWithRequestData:(NSData *)requestData {
    id<A2JITNSExtension> extension = self.extension;
    __weak typeof(self) weakSelf = self;

    // ① 先挂三个块，再 begin（顺序与 Henge JITBuiltIn.swift:130-148 一致）：
    //    块可能在任意队列到达，所以统一转回主线程再动状态。
    [extension setRequestCompletionBlock:^(NSUUID *_Nullable requestIdentifier,
                                           NSArray *_Nullable returnedItems) {
        id first = returnedItems.firstObject;
        NSDictionary *info = [first isKindOfClass:NSExtensionItem.class]
                                 ? ((NSExtensionItem *)first).userInfo
                                 : nil;
        id payload = info[A2JITHelperResponseItemKey];
        NSData *data = [payload isKindOfClass:NSData.class] ? payload : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = nil;
            NSDictionary<NSString *, id> *response = [A2JITHelperBridge responseFromPayload:data
                                                                                     error:&error];
            [weakSelf finishWithResponse:response error:error];
        });
    }];
    [extension setRequestCancellationBlock:^(NSUUID *_Nullable requestIdentifier,
                                             NSError *_Nullable error) {
        NSString *message = error.localizedDescription ?: @"the request was cancelled";
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishWithResponse:nil
                                   error:A2JITHelperError(5, [NSString stringWithFormat:
                                        @"JIT helper 停止了：%@", message])];
        });
    }];
    [extension setRequestInterruptionBlock:^(NSUUID *_Nullable requestIdentifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishWithResponse:nil
                                   error:A2JITHelperError(6, @"JIT helper 异常退出，请重试")];
        });
    }];

    // ② 请求载荷就是 userInfo 里的一段 JSON（与 appex 的 itemKey 一致）。
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{A2JITHelperRequestItemKey: requestData};
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *_Nullable uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            A2JITHelperSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (uuid == nil) {
                [strongSelf finishWithResponse:nil
                                         error:A2JITHelperError(7, [NSString stringWithFormat:
                                              @"JIT helper（%@）没有启动起来；重装 Air2 并保留它的 app extensions，"
                                              @"或改用 StikDebug", strongSelf.identifier])];
                return;
            }
            // 这一行是「扩展真的起来了」的唯一现场判据：pid 就是 debugger 那一半的进程。
            NSLog(@"[A2JITHelper] %@: started %@ as pid %d (self pid %d)",
                  strongSelf.operation, strongSelf.identifier,
                  (int)[strongSelf.extension pidForRequestIdentifier:uuid], (int)getpid());
        });
    }];
}

- (void)finishWithResponse:(NSDictionary<NSString *, id> *)response error:(NSError *)error {
    void (^completion)(NSDictionary<NSString *, id> *, NSError *) = self.completion;
    if (completion == nil) return;   // 第一次结果为准（Henge JITBuiltIn.swift:173-175 同口径）
    self.completion = nil;
    // 先摘掉保活，再回调：回调里可能立刻发第二个请求。
    [A2JITHelperSessions() removeObjectIdenticalTo:self];
    if (response != nil) {
        NSLog(@"[A2JITHelper] %@: finished success=%@ message=%@", self.operation,
              response[A2JITHelperResponseSuccessKey], response[A2JITHelperResponseMessageKey]);
    } else {
        NSLog(@"[A2JITHelper] %@: %@", self.operation, error.localizedDescription ?: @"no answer");
    }
    completion(response, error);
}

@end

// ---------------------------------------------------------------------------
// 公开面
// ---------------------------------------------------------------------------
@implementation A2JITHelperBridge

+ (nullable NSString *)helperIdentifier {
    NSURL *plugins = NSBundle.mainBundle.builtInPlugInsURL;
    if (plugins == nil) return nil;
    NSURL *url = [plugins URLByAppendingPathComponent:A2JITHelperBundleName isDirectory:YES];
    // ★现取 appex 的 bundle id，不写死★：侧载器（SideStore/AltStore/Plume/Impactor）会给
    // 主 App 和 appex 一起加 team 后缀，写死的 id 在真机上必然找不到（Henge 同做法，
    // JITBuiltIn.swift:27-33 的注释写的就是这件事）。
    return [NSBundle bundleWithURL:url].bundleIdentifier;
}

+ (nullable NSString *)unavailableReason {
#if TARGET_OS_SIMULATOR
    return @"内建 JIT 只能在真机上用（模拟器没有 RemotePairing / DDI）";
#else
    if (@available(iOS 26.0, *)) {
        // 继续往下判
    } else {
        return @"内建 JIT 需要 iOS 26 或更高；更低版本请用 StikDebug";
    }
    // LiveContainer 里扩展起不来（Henge 同一判据，JITBuiltIn.swift:51-53）。
    if (getenv("LC_HOME_PATH") != NULL) {
        return @"内建 JIT 在 LiveContainer 里不可用；请用 StikDebug";
    }
    A2JITHelperLoadExtensionFramework();
    if (NSClassFromString(@"NSExtension") == nil) {
        return @"iOS 没有提供本扩展所需的 NSExtension API（iOS 26+ 才有）";
    }
    return nil;
#endif
}

+ (nullable NSData *)requestDataWithOperation:(A2JITHelperOperation)operation
                                   targetPID:(int32_t)targetPID
                                 pairingData:(NSData *)pairingData
                                scriptBase64:(NSString *)scriptBase64
                                     rsdPort:(NSNumber *)rsdPort
                                deviceAddress:(NSString *)deviceAddress
                                       error:(NSError *_Nullable *_Nullable)error {
    if (error) *error = nil;
    // operation 的 rawValue 就是 appex 那边 Codable 的 raw value，逐字一致（A2JITHelperMessages.swift）。
    NSString *name = nil;
    switch (operation) {
        case A2JITHelperOperationPrepare:
            name = @"prepare";
            if (pairingData.length == 0) {
                if (error) *error = A2JITHelperError(4, @"prepare 需要配对文件（pairingData 为空）");
                return nil;
            }
            break;
        case A2JITHelperOperationEnable:
            name = @"enable";
            if (targetPID <= 0) {
                if (error) *error = A2JITHelperError(4, @"enable 需要目标进程 pid");
                return nil;
            }
            if (pairingData.length == 0) {
                if (error) *error = A2JITHelperError(4, @"enable 需要配对文件（pairingData 为空）");
                return nil;
            }
            if (scriptBase64.length == 0) {
                if (error) *error = A2JITHelperError(4, @"enable 需要 JIT 脚本（scriptBase64 为空）");
                return nil;
            }
            break;
        case A2JITHelperOperationResetDDI:
            name = @"resetDDI";
            break;
    }
    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    json[@"operation"] = name;
    // 可选字段缺省就不写：Swift 侧是 `Int32?`/`Data?`/`String?`/`UInt16?`，缺键即 nil。
    if (operation == A2JITHelperOperationEnable) json[@"targetPID"] = @(targetPID);
    // ★Data → base64 字符串★：Swift 的 JSONEncoder 默认 dataEncodingStrategy = .base64，
    // 所以 ObjC 侧必须给同一个形状（原文 base64，无换行）。
    if (pairingData.length > 0) json[@"pairingData"] = [pairingData base64EncodedStringWithOptions:0];
    if (scriptBase64.length > 0) json[@"scriptBase64"] = scriptBase64;
    if (rsdPort != nil) json[@"rsdPort"] = rsdPort;
    // ★LocalDevVPN 回环地址★（默认 127.0.0.1）：Henge 也走这条，Bonjour 名字在 appex 里连不上。
    if (deviceAddress.length > 0) json[@"deviceAddress"] = deviceAddress;

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&jsonError];
    if (data == nil && error) {
        *error = A2JITHelperError(4, [NSString stringWithFormat:@"请求编不成 JSON：%@",
                                     jsonError.localizedDescription ?: @"未知"]);
    }
    return data;
}

+ (BOOL)startWithRequestData:(NSData *)requestData
                  completion:(void (^)(NSDictionary<NSString *, id> *_Nullable response,
                                       NSError *_Nullable error))completion {
    if (requestData.length == 0 || completion == nil) return NO;
    // 拉起 / 挂块 / begin 都在主线程做（Henge 用 @MainActor 表达；块回来也统一回主线程）。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)[self startWithRequestData:requestData completion:completion];
        });
        return YES;   // 已受理；失败原因一律走 completion
    }

    // 请求先自检：既拦住垃圾载荷，也拿到 operation 当日志标签（与 appex 的 operation 字段同名）。
    NSString *operation = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:requestData options:0 error:NULL];
    if ([parsed isKindOfClass:NSDictionary.class]) {
        id op = ((NSDictionary *)parsed)[@"operation"];
        if ([op isKindOfClass:NSString.class]) operation = op;
    }
    if (operation.length == 0) {
        completion(nil, A2JITHelperError(4, @"请求不是带 operation 的 JSON"));
        return NO;
    }

    NSString *why = [self unavailableReason];
    if (why.length > 0) {
        completion(nil, A2JITHelperError(1, why));
        return NO;
    }
    NSString *identifier = [self helperIdentifier];
    if (identifier.length == 0) {
        completion(nil, A2JITHelperError(2, @"包内缺少 JIT helper（PlugIns/Air2JITHelper.appex）；"
                                            @"重装 Air2 并保留它的 app extensions"));
        return NO;
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    if (extensionClass == Nil) {
        completion(nil, A2JITHelperError(3, @"iOS 没有提供 JIT helper 所需的扩展 API"));
        return NO;
    }
    NSError *lookupError = nil;
    id found = [(id<A2JITNSExtensionClass>)extensionClass extensionWithIdentifier:identifier
                                                                          error:&lookupError];
    if (found == nil) {
        completion(nil, A2JITHelperError(2, [NSString stringWithFormat:
            @"找不到 JIT helper（%@）：%@；重装 Air2", identifier,
            lookupError.localizedDescription ?: @"无原因"]));
        return NO;
    }

    A2JITHelperSession *session =
        [[A2JITHelperSession alloc] initWithExtension:found
                                          identifier:identifier
                                           operation:operation
                                          completion:completion];
    [A2JITHelperSessions() addObject:session];
    [session beginWithRequestData:requestData];
    return YES;
}

+ (nullable NSDictionary<NSString *, id> *)responseFromPayload:(NSData *)payload
                                                         error:(NSError *_Nullable *_Nullable)error {
    if (error) *error = nil;
    if (payload.length == 0) {
        if (error) *error = A2JITHelperError(8, @"JIT helper 结束了但没有带回应答");
        return nil;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) *error = A2JITHelperError(8, @"JIT helper 的应答不是 JSON 对象");
        return nil;
    }
    NSDictionary<NSString *, id> *json = parsed;
    // success/message 是协议里必有的两个字段（A2JITHelperMessages.swift 的 Response），
    // 缺了就是版本不匹配 / 截断 ⇒ 当失败，不要静默当成成功。
    if (![json[A2JITHelperResponseSuccessKey] isKindOfClass:NSNumber.class] ||
        ![json[A2JITHelperResponseCodeKey] isKindOfClass:NSNumber.class]) {
        if (error) *error = A2JITHelperError(8, @"JIT helper 的应答缺 success/code 字段");
        return nil;
    }
    // ★码 → 文本★（appex 不再回任意字符串：真机 ips 显示编码错误链里的 String 会崩）
    NSInteger code = [json[A2JITHelperResponseCodeKey] integerValue];
    NSString *text = nil;
    switch (code) {
        case 0:  text = @"开发者镜像缓存已重置"; break;
        case 1:  text = @"扩展没收到请求（IPC 版本不匹配）"; break;
        case 10: text = @"LocalDevVPN 可达，开发者镜像已就绪"; break;
        case 11: text = @"LocalDevVPN 不可达（请确认已连接）"; break;
        case 12: text = @"开发者镜像准备失败"; break;
        case 13: text = @"引擎返回未知的准备状态"; break;
        case 20: text = @"JIT 已开启（调试器已脱离）"; break;
        case 30: text = @"扩展执行失败（见 appex 日志）"; break;
        default: text = [NSString stringWithFormat:@"未知结果码 %ld", (long)code]; break;
    }
    NSMutableDictionary *out = [json mutableCopy];
    out[A2JITHelperResponseMessageKey] = text;
    return out;
}

@end
