//
//  A2Multiplayer.m
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
//
//  A2Multiplayer.m
//  Air2
//

#import "A2Multiplayer.h"
#import "A2Logger.h"
#import <UIKit/UIKit.h>

NSNotificationName const A2MultiplayerStateDidChangeNotification = @"A2MultiplayerStateDidChangeNotification";

/// libterracotta 的 C ABI（弱符号）。
///
/// 来源：burningtnt/Terracotta 的 iOS 移植，与 HMCL/FCL/ZL2 v0.4.2 同源。
/// 用 weak 声明：库不存在的符号是 NULL，调用前必须检查 available。
///
/// 当前工程里没有 libterracotta.xcframework，所以这些函数指针全为 NULL，
/// available 返回 NO，UI 会显示「联机组件未就绪」而不是崩溃。
extern int terracotta_ios_start(const char *dir, int logging_fd) __attribute__((weak));
extern char *terracotta_ios_get_state(void) __attribute__((weak));
extern void terracotta_ios_set_waiting(void) __attribute__((weak));
extern void terracotta_ios_set_scanning(const char *room, const char *player) __attribute__((weak));
extern int terracotta_ios_start_host_with_port(const char *room, uint16_t port, const char *player) __attribute__((weak));
extern int terracotta_ios_set_guesting(const char *room, const char *player) __attribute__((weak));
extern int terracotta_ios_verify_room_code(const char *code) __attribute__((weak));
extern char *terracotta_ios_get_metadata(void) __attribute__((weak));
extern void terracotta_ios_free_string(char *ptr) __attribute__((weak));

/// 状态轮询间隔
static const NSTimeInterval kPollInterval = 0.5;

#pragma mark - 玩家

@implementation A2MultiplayerPlayer
@end

#pragma mark - 管理器

@interface A2Multiplayer ()
@property (nonatomic, assign) A2MultiplayerStatus status;
@property (nonatomic, assign) A2MultiplayerRole role;
@property (nonatomic, assign) BOOL available;
@property (nonatomic, assign) BOOL started;

@property (nonatomic, copy, nullable) NSString *inviteCode;
@property (nonatomic, assign) uint16_t lanPort;
@property (nonatomic, copy, nullable) NSString *directConnectAddress;
@property (nonatomic, copy, nullable) NSString *stageDescription;
@property (nonatomic, copy) NSArray<A2MultiplayerPlayer *> *players;
@property (nonatomic, copy, nullable) NSString *lastError;

@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@end

@implementation A2Multiplayer

+ (instancetype)shared {
    static A2Multiplayer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2Multiplayer alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _workQueue = dispatch_queue_create("dev.airdevs.air2.multiplayer", DISPATCH_QUEUE_SERIAL);
    _players = @[];
    _status = A2MultiplayerStatusDisconnected;
    _role = A2MultiplayerRoleNone;
    return self;
}

#pragma mark - 可用性

/// 检查库是否链接成功。
/// 只要有一个核心符号为 NULL 就认为不可用 —— 避免调用到一半崩溃。
- (BOOL)checkAvailable {
    return (terracotta_ios_start != NULL &&
            terracotta_ios_get_state != NULL &&
            terracotta_ios_set_waiting != NULL &&
            terracotta_ios_set_scanning != NULL &&
            terracotta_ios_set_guesting != NULL &&
            terracotta_ios_set_guesting != NULL);
}

#pragma mark - 初始化

- (void)initializeIfNeeded {
    if (_started) return;

    _available = [self checkAvailable];
    if (!_available) {
        // 库没链接进来 —— 明确记录，UI 据此提示，而不是假装能用
        [A2Logger warning:@"A2Multiplayer"
                  message:@"libterracotta 未链接，联机功能不可用"];
        return;
    }

    _started = YES;

    dispatch_async(_workQueue, ^{
        // 工作目录用于持久化 machine-id（P2P 节点标识，必须稳定）
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dir = [docs stringByAppendingPathComponent:@"terracotta"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];

        int rc = terracotta_ios_start(dir.UTF8String, -1);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 0) {
                self.available = NO;
                [A2Logger error:@"A2Multiplayer" message:
                 [NSString stringWithFormat:@"terracotta 初始化失败 rc=%d", rc]];
            } else {
                [A2Logger info:@"A2Multiplayer" message:@"terracotta 已初始化"];
                [self printMetadata];
            }
        });
    });
}

- (void)printMetadata {
    if (terracotta_ios_get_metadata == NULL) return;
    char *meta = terracotta_ios_get_metadata();
    if (!meta) return;

    NSString *s = [NSString stringWithUTF8String:meta];
    if (terracotta_ios_free_string) terracotta_ios_free_string(meta);

    if (s.length) {
        // 元数据是 NUL 分隔的三段：version / 编译时间 / easytier 版本
        NSArray<NSString *> *parts = [s componentsSeparatedByString:@"\0"];
        [A2Logger info:@"A2Multiplayer" message:
         [NSString stringWithFormat:@"terracotta 元数据: %@", [parts componentsJoinedByString:@" | "]]];
    }
}

#pragma mark - 会话控制

- (void)createRoomWithPort:(uint16_t)port inviteCode:(NSString *)inviteCode {
    if (!_available) {
        [self failWithMessage:@"联机组件未就绪"];
        return;
    }

    _role = A2MultiplayerRoleHost;
    [self setStatus:A2MultiplayerStatusConnecting withStage:@"正在创建房间…"];

    dispatch_async(_workQueue, ^{
        NSString *room = inviteCode.length ? inviteCode : nil;
        NSString *player = [self localPlayerName];

        if (port > 0) {
            // 手动端口模式
            int rc = terracotta_ios_start_host_with_port(
                room.UTF8String, port, player.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (rc != 1) {
                    [self failWithMessage:@"当前状态无法创建房间"];
                    return;
                }
                self.lanPort = port;
                [self startPolling];
            });
        } else {
            // 多播扫描模式 —— ZL2 的默认做法
            terracotta_ios_set_scanning(room.UTF8String, player.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self startPolling];
            });
        }
    });
}

- (BOOL)joinRoomWithCode:(NSString *)inviteCode {
    if (!_available) {
        [self failWithMessage:@"联机组件未就绪"];
        return NO;
    }
    if (![self isValidInviteCode:inviteCode]) {
        [self failWithMessage:@"邀请码格式无效"];
        return NO;
    }

    _role = A2MultiplayerRoleGuest;
    [self setStatus:A2MultiplayerStatusConnecting withStage:@"正在加入房间…"];

    dispatch_async(_workQueue, ^{
        NSString *player = [self localPlayerName];
        int rc = terracotta_ios_set_guesting(inviteCode.UTF8String, player.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 1) {
                [self failWithMessage:@"邀请码无效或当前状态无法加入"];
                return;
            }
            [self startPolling];
        });
    });
    return YES;
}

- (BOOL)isValidInviteCode:(NSString *)code {
    if (code.length == 0) return NO;
    if (!_available || terracotta_ios_verify_room_code == NULL) {
        // 库不可用时只做基本格式检查：非空且无空白
        return [code rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
    }
    // 库返回 3 表示合法的 Scaffolding 邀请码
    return terracotta_ios_verify_room_code(code.UTF8String) == 3;
}

- (void)stopSession {
    if (_available && terracotta_ios_set_waiting) {
        dispatch_async(_workQueue, ^{
            terracotta_ios_set_waiting();
        });
    }
    [self stopPolling];

    _role = A2MultiplayerRoleNone;
    _inviteCode = nil;
    _lanPort = 0;
    _directConnectAddress = nil;
    _players = @[];
    [self setStatus:A2MultiplayerStatusDisconnected withStage:nil];
}

#pragma mark - 状态轮询

/// 轮询底层状态并映射。
/// ZL2 是 8 个底层状态 → 4 个 UI 状态，这里保持一致。
- (void)startPolling {
    [self stopPolling];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        [self pollOnce];
    }];
}

- (void)stopPolling {
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)pollOnce {
    if (!_available || terracotta_ios_get_state == NULL) return;

    char *raw = terracotta_ios_get_state();
    if (!raw) return;

    NSString *json = [NSString stringWithUTF8String:raw];
    if (terracotta_ios_free_string) terracotta_ios_free_string(raw);
    if (json.length == 0) return;

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyState:state];
    });
}

/// 把底层 JSON 状态映射到 UI 状态。
///
/// 底层状态（对应 ZL2 的 TerracottaState）：
///   waiting / host-scanning / host-starting / host-ok
///   guest-connecting / guest-starting / guest-ok / exception
- (void)applyState:(NSDictionary *)state {
    NSString *s = state[@"state"];
    if (![s isKindOfClass:NSString.class]) return;

    // 邀请码与端口
    NSString *room = state[@"room"];
    if ([room isKindOfClass:NSString.class] && room.length) _inviteCode = room;

    NSNumber *portNum = state[@"port"];
    if ([portNum isKindOfClass:NSNumber.class] && portNum.integerValue > 0) {
        _lanPort = (uint16_t)portNum.integerValue;
    }

    // 玩家列表
    NSArray *profiles = state[@"profiles"];
    if ([profiles isKindOfClass:NSArray.class]) {
        NSNumber *selfIndex = [state[@"profile_index"] isKindOfClass:NSNumber.class]
            ? state[@"profile_index"] : nil;
        NSMutableArray<A2MultiplayerPlayer *> *list = [NSMutableArray array];
        for (NSUInteger i = 0; i < profiles.count; i++) {
            NSDictionary *p = profiles[i];
            A2MultiplayerPlayer *player = [A2MultiplayerPlayer new];
            player.name = [p isKindOfClass:NSDictionary.class]
                ? (p[@"name"] ?: [NSString stringWithFormat:@"玩家 %lu", (unsigned long)(i + 1)])
                : [NSString stringWithFormat:@"玩家 %lu", (unsigned long)(i + 1)];
            player.isSelf = (selfIndex && selfIndex.integerValue == (NSInteger)i);
            [list addObject:player];
        }
        _players = [list copy];
    }

    // 状态映射
    if ([s isEqualToString:@"waiting"]) {
        [self setStatus:A2MultiplayerStatusDisconnected withStage:@"未联机"];
    } else if ([s isEqualToString:@"host-scanning"]) {
        [self setStatus:A2MultiplayerStatusConnecting
              withStage:@"正在扫描局域网端口…"];
    } else if ([s isEqualToString:@"host-starting"]) {
        [self setStatus:A2MultiplayerStatusConnecting withStage:@"正在启动房间…"];
    } else if ([s isEqualToString:@"host-ok"]) {
        [self setStatus:A2MultiplayerStatusConnected withStage:@"房间已就绪"];
    } else if ([s isEqualToString:@"guest-connecting"]) {
        [self setStatus:A2MultiplayerStatusConnecting withStage:@"正在连接房主…"];
    } else if ([s isEqualToString:@"guest-starting"]) {
        [self setStatus:A2MultiplayerStatusConnecting withStage:@"正在建立通道…"];
    } else if ([s isEqualToString:@"guest-ok"]) {
        [self setStatus:A2MultiplayerStatusConnected withStage:@"已连接到房主"];
        [self updateDirectConnectAddress];
    } else if ([s isEqualToString:@"exception"]) {
        NSString *msg = state[@"message"] ?: @"联机出错";
        [self failWithMessage:msg];
    }
}

/// 房客的连接地址：本机转发端口，MC 里直接连这个
- (void)updateDirectConnectAddress {
    if (_role != A2MultiplayerRoleGuest) return;
    // terracotta 会在本地监听，MC 里连 localhost 即可
    _directConnectAddress = @"127.0.0.1";
}

#pragma mark - 工具

- (NSString *)localPlayerName {
    // 用当前账号名，没有则用设备名
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:@"A2CurrentAccountName"];
    if (name.length) return name;
    return UIDevice.currentDevice.name ?: @"Player";
}

- (void)setStatus:(A2MultiplayerStatus)status withStage:(NSString *)stage {
    BOOL changed = (_status != status);
    _status = status;
    _stageDescription = [stage copy];

    if (status == A2MultiplayerStatusConnected) {
        _lastError = nil;
    }

    if (changed) {
        [NSNotificationCenter.defaultCenter postNotificationName:A2MultiplayerStateDidChangeNotification
                                                          object:self];
    }
}

- (void)failWithMessage:(NSString *)message {
    _lastError = [message copy];
    [self stopPolling];
    [self setStatus:A2MultiplayerStatusError withStage:message];
    [A2Logger error:@"A2Multiplayer" message:message];
}

@end
