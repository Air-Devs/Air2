#import "utils.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"

NSNotificationName TerracottaManagerStateDidChangeNotification = @"TerracottaManagerStateDidChange";

/// ★ [MP-ROLE] 角色名（日志用）
static NSString *TerracottaRoleName(TerracottaRole role) {
    switch (role) {
        case TerracottaRoleHost:   return @"host";
        case TerracottaRoleClient: return @"guest";
        default:                   return @"none";
    }
}

@interface TerracottaManager ()
@property(nonatomic, assign) TerracottaStatus status;
@property(nonatomic, assign) TerracottaRole role;
@property(nonatomic, copy, nullable) NSString *currentInviteCode;
@property(nonatomic, assign) uint16_t currentPort;
@property(nonatomic, copy, nullable) NSString *stageDescription;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, assign) NSInteger currentProfileIndex;   // ★ [MP-ROLE]
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSString *lastError;
@property(nonatomic, assign) BOOL initialized;
@end

@implementation TerracottaManager {
    dispatch_source_t _pollTimer;
    NSInteger _lastStateKind;
    NSInteger _lastStateIndex;
    dispatch_queue_t _pollQueue;
}

#pragma mark - Singleton

+ (instancetype)shared {
    static TerracottaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TerracottaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = TerracottaStatusDisconnected;
        _role = TerracottaRoleNone;
        _currentProfileIndex = NSNotFound;   // ★ [MP-ROLE] 未知
        _pollQueue = dispatch_queue_create("terracotta.poll", dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        /* 单例触发 init 时自动初始化 Terracotta（若库可用） */
        [self initializeTerracotta];
    }
    return self;
}

#pragma mark - Initialization

- (void)initializeTerracotta {
    if (self.initialized) return;
    if (![TerracottaBridge isAvailable]) {
        NSLog(@"[TerracottaManager] libterracotta not linked, multiplayer disabled");
        return;
    }

    NSString *docsDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsDir == nil) docsDir = NSTemporaryDirectory();

    /* 用独立的 terracotta/ 子目录存放工作数据 */
    NSString *workDir = [docsDir stringByAppendingPathComponent:@"terracotta"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *logPath = [workDir stringByAppendingPathComponent:@"terracotta.log"];

    BOOL ok = [TerracottaBridge startWithWorkingDirectory:workDir loggingPath:logPath];
    if (!ok) {
        NSLog(@"[TerracottaManager] terracotta_ios_start failed");
        self.lastError = localize(@"i18n_str_996", nil);
        self.status = TerracottaStatusError;
        return;
    }
    NSLog(@"[TerracottaManager] Terracotta initialized at %@", workDir);
    self.initialized = YES;
}

#pragma mark - Session Control

- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(NSString *)inviteCode
                playerName:(NSString *)playerName {
    [self resetSessionState];
    self.role = TerracottaRoleHost;
    self.currentPort = port;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = localize(@"i18n_str_997", nil);
    self.lastError = nil;

    // ★ [MP-ROLE] 房主创建房间（房间号由核心生成）
    NSLog(@"[MP-ROLE] role=host event=create port=%u inviteCode=%@", port,
          inviteCode.length ? @"(provided)" : @"(auto-generated)");

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge startHostWithRoom:inviteCode
                                              port:port
                                        playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = localize(@"i18n_str_998", nil);
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return;
    }
    [self startPolling];
    [self notifyStateChanged];
}

- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(NSString *)playerName {
    if (![TerracottaBridge verifyRoomCode:inviteCode]) {
        self.lastError = localize(@"i18n_str_999", nil);
        return NO;
    }
    [self resetSessionState];
    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = localize(@"i18n_str_1000", nil);
    self.lastError = nil;

    // ★ [MP-ROLE] 房客凭房间号/邀请码加入
    NSLog(@"[MP-ROLE] role=guest event=join codeLen=%lu", (unsigned long)inviteCode.length);

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge setGuestingWithRoom:inviteCode playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = localize(@"i18n_str_1001", nil);
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return NO;
    }
    [self startPolling];
    [self notifyStateChanged];
    return YES;
}

- (void)stopSession {
    // ★ [MP-ROLE] 结束会话（角色回到 none）
    NSLog(@"[MP-ROLE] role=none event=stop (was role=%@)", TerracottaRoleName(self.role));
    [TerracottaBridge setWaiting];
    [self stopPolling];
    [[SilentAudioPlayer shared] stopKeepingAlive];
    [self resetSessionState];
    [self notifyStateChanged];
}

#pragma mark - State Reset

- (void)resetSessionState {
    self.role = TerracottaRoleNone;
    self.status = TerracottaStatusDisconnected;
    self.currentInviteCode = nil;
    self.currentPort = 0;
    self.stageDescription = nil;
    self.players = nil;
    self.directConnectURL = nil;
    self.currentProfileIndex = NSNotFound;   // ★ [MP-ROLE] 会话结束，未知
    /* lastError 不在此清除，让 UI 能在 stopSession 后仍看到上次错误（如果有） */
    _lastStateKind = -1;
    _lastStateIndex = -1;
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    /* dispatch_source_t 定时器，0.5s 间隔，QOS_CLASS_UTILITY 队列避免阻塞主线程 */
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pollQueue);
    dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_timer(_pollTimer, start,
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        TerracottaState *state = [TerracottaBridge pollState];
        if (state != nil) {
            [strongSelf applyState:state];
        }
    });
    dispatch_resume(_pollTimer);
}

- (void)stopPolling {
    if (_pollTimer != nil) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
}

#pragma mark - State Mapping

/// 把 Rust 侧 8 个底层状态映射到 4 个高层状态，更新所有 @property。
/// 状态去重：state.kind 和 state.index 都没变时跳过通知。
- (void)applyState:(TerracottaState *)state {
    if (state.kind == _lastStateKind && state.index == _lastStateIndex) {
        /* 状态没变，但玩家列表可能变化（新玩家加入），仍更新 */
        if (state.profiles != nil) self.players = state.profiles;
        return;
    }
    _lastStateKind = state.kind;
    _lastStateIndex = state.index;

    // ★ [MP-ROLE] 本地玩家下标（profile_index）+ 房主下标（profiles[].kind=="host"）
    self.currentProfileIndex = state.profileIndex;
    NSInteger hostIdx = NSNotFound;
    NSArray<TerracottaPlayerProfile *> *profiles = state.profiles;
    for (NSInteger i = 0; i < (NSInteger)profiles.count; i++) {
        if ([profiles[i].kind isEqualToString:@"host"]) { hostIdx = i; break; }
    }
    NSLog(@"[MP-ROLE] role=%@ phase=kind:%ld index:%ld selfIdx=%ld hostIdx=%ld players=%lu",
          TerracottaRoleName(self.role), (long)state.kind, (long)state.index,
          (long)self.currentProfileIndex, (long)hostIdx, (unsigned long)profiles.count);

    switch (state.kind) {
        case TerracottaStateKindWaiting:
            self.status = TerracottaStatusDisconnected;
            self.stageDescription = nil;
            break;
        case TerracottaStateKindHostScanning:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1002", nil);
            break;
        case TerracottaStateKindHostStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1003", nil);
            break;
        case TerracottaStateKindHostOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = localize(@"i18n_str_1004", nil);
            break;
        case TerracottaStateKindGuestConnecting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1005", nil);
            break;
        case TerracottaStateKindGuestStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1003", nil);
            break;
        case TerracottaStateKindGuestOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = localize(@"i18n_str_1006", nil);
            break;
        case TerracottaStateKindException:
            self.status = TerracottaStatusError;
            self.lastError = [TerracottaBridge describeException:state.exceptionType];
            self.stageDescription = self.lastError;
            /* 异常时停止轮询和保活 */
            [self stopPolling];
            [[SilentAudioPlayer shared] stopKeepingAlive];
            break;
    }

    /* 更新邀请码和直连地址（仅 Rust 侧有值时覆盖） */
    if (state.room.length > 0) self.currentInviteCode = state.room;
    if (state.directConnectURL.length > 0) self.directConnectURL = state.directConnectURL;
    if (state.profiles != nil) self.players = state.profiles;

    [self notifyStateChanged];
}

#pragma mark - Notification

- (void)notifyStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TerracottaManagerStateDidChangeNotification object:self];
    });
}

@end
