//
//  A2HomeStore.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页布局落盘 / 备份 / 导入导出实现。协议说明见 A2HomeStore.h 顶部。
//
//  线程约定：本类只在主线程使用（主页的所有写都来自 UI 交互），所以不做额外的锁。
//  「进后台时 flush」由 UI 层调 `-flush`（本类不 import UIKit，保持 Core 不依赖 UI 框架）。
//

#import "A2HomeStore.h"

#import "A2Log.h"
#import "A2Settings.h"

#import <fcntl.h>
#import <stdio.h>
#import <unistd.h>

NSString *const A2HomeSettingsKeyHomeMode = @"homeMode";
NSString *const A2HomeSettingsKeyGridEnabled = @"home.ui.gridEnabled";

static NSString *const A2HomeStoreErrorDomain = @"A2HomeStore";

@interface A2HomeStore ()

@property (nonatomic, copy, readwrite) NSString *filePath;
@property (nonatomic, assign, readwrite) BOOL isReadOnly;
@property (nonatomic, assign, readwrite, getter=isLoadedFromBackup) BOOL loadedFromBackup;
@property (nonatomic, assign, readwrite) BOOL loadedFromCorrupt;
@property (nonatomic, strong, nullable) A2HomeDocument *pendingDocument;

@property (nonatomic, copy, readonly) NSString *backupPath;
@property (nonatomic, copy, readonly) NSString *corruptPath;
@property (nonatomic, copy, readonly) NSString *readOnlyBackupPath;

- (BOOL)writeJSONObject:(NSDictionary *)json error:(NSError **)error;
- (void)copyFileAtPath:(NSString *)from toPath:(NSString *)to;
- (void)logLoadResult:(A2HomeDocument *)document source:(NSString *)source;
- (void)fillError:(NSError **)error code:(NSInteger)code message:(NSString *)message;

@end

@implementation A2HomeStore {
    uint64_t _saveGeneration;
    /// 主文件当前是「读不出来的坏文件」。这种状态下**不许拿它去覆盖 .bak** ——
    /// 否则「从备份恢复」之后的第一次保存会把唯一的好备份换成坏文件，回滚能力就没了。
    BOOL _mainFileIsCorrupt;
}

+ (instancetype)shared {
    static A2HomeStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[A2HomeStore alloc] init]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        _filePath = [docs stringByAppendingPathComponent:@"home-layout.json"];
    }
    return self;
}

#pragma mark - 路径

- (NSString *)backupPath {
    return [self.filePath.stringByDeletingPathExtension stringByAppendingPathExtension:@"bak.json"];
}

- (NSString *)corruptPath {
    return [self.filePath.stringByDeletingPathExtension stringByAppendingPathExtension:@"corrupt.json"];
}

- (NSString *)readOnlyBackupPath {
    return [self.filePath.stringByDeletingPathExtension stringByAppendingPathExtension:@"readonly.json"];
}

#pragma mark - 主页模式

- (A2HomeMode)homeMode {
    return [A2Settings.shared boolForKey:A2HomeSettingsKeyHomeMode default:NO] ? A2HomeModeGrid
                                                                               : A2HomeModeClassic;
}

- (void)setHomeMode:(A2HomeMode)mode {
    [A2Settings.shared setBool:(mode == A2HomeModeGrid) forKey:A2HomeSettingsKeyHomeMode];
    [A2Log log:@"[A2-HOME] 主页模式=%@", (mode == A2HomeModeGrid) ? @"自定义网格" : @"经典"];
}

#pragma mark 主页网格（实验开关）

/// 默认 NO：读不到 key（老用户升级）就是经典三区 —— 与接线前逐字一致。
- (BOOL)gridEnabled {
    return [A2Settings.shared boolForKey:A2HomeSettingsKeyGridEnabled default:NO];
}

/// 写穿透到 config.json，并由 A2Settings 发 `A2SettingsDidChangeNotification`（主页据此热应用）。
- (void)setGridEnabled:(BOOL)enabled {
    [A2Settings.shared setBool:enabled forKey:A2HomeSettingsKeyGridEnabled];
    [A2Log criterion:@"[A2-HOME] 主页网格开关=%@（key=%@）",
     enabled ? @"开" : @"关", A2HomeSettingsKeyGridEnabled];
}

#pragma mark - 读

- (A2HomeDocument *)loadDocument {
    self.isReadOnly = NO;
    self.loadedFromBackup = NO;
    self.loadedFromCorrupt = NO;
    _mainFileIsCorrupt = NO;

    NSData *data = [NSData dataWithContentsOfFile:self.filePath];
    if (data.length > 0) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        BOOL readOnly = NO;
        A2HomeDocument *doc = json ? [A2HomeDocument documentFromJSONObject:json readOnly:&readOnly] : nil;
        if (doc) {
            if (readOnly) {
                self.isReadOnly = YES;
                // 原文件在，但本版不认识：先留一份只读备份，之后一律禁写。
                [self copyFileAtPath:self.filePath toPath:self.readOnlyBackupPath];
                [A2Log log:@"[A2-HOME] 只读：原配置已备份 %@（不覆盖、不重置）",
                            self.readOnlyBackupPath.lastPathComponent];
            }
            [self logLoadResult:doc source:@"主文件"];
            self.pendingDocument = doc;
            return doc;
        }
        // 主文件在、但完全不可用：保留原件，绝不就地覆盖。
        [self copyFileAtPath:self.filePath toPath:self.corruptPath];
        self.loadedFromCorrupt = YES;
        _mainFileIsCorrupt = YES;
        [A2Log log:@"[A2-HOME] 主文件不可解析（%lu 字节）：已保留为 %@",
                    (unsigned long)data.length, self.corruptPath.lastPathComponent];
    }

    // 主文件坏了 → 试 .bak（「已从备份恢复」这一条）。
    NSData *bakData = [NSData dataWithContentsOfFile:self.backupPath];
    if (bakData.length > 0) {
        id bakJSON = [NSJSONSerialization JSONObjectWithData:bakData options:0 error:NULL];
        BOOL bakReadOnly = NO;
        A2HomeDocument *bakDoc = bakJSON ? [A2HomeDocument documentFromJSONObject:bakJSON readOnly:&bakReadOnly] : nil;
        if (bakDoc && !bakReadOnly) {
            self.loadedFromBackup = YES;
            [self logLoadResult:bakDoc source:@"备份"];
            [A2Log log:@"[A2-HOME] 已从备份恢复：%@", self.backupPath.lastPathComponent];
            self.pendingDocument = bakDoc;
            return bakDoc;
        }
    }

    // 都失败 → 出厂默认，★不立即写盘★（等用户第一次真正编辑）。
    A2HomeDocument *fallback = [A2HomeDocument defaultDocument];
    [A2Log log:@"[A2-HOME] 回退默认方案（未写盘）：%lu 张卡，等首次编辑才落盘",
                (unsigned long)[fallback activeProfile].cards.count];
    self.pendingDocument = fallback;
    return fallback;
}

- (void)logLoadResult:(A2HomeDocument *)document source:(NSString *)source {
    A2HomeProfile *p = [document activeProfile];
    [A2Log log:@"[A2-HOME] 读取命中（%@）：方案 %lu 个 / 当前『%@』/ 渲染 %lu 张卡 / 布局=%@",
                source, (unsigned long)document.profiles.count, p.name,
                (unsigned long)p.cards.count,
                (p.layout == A2HomeLayoutModeFree) ? @"自由" : @"网格"];
}

#pragma mark - 写

- (BOOL)saveDocument:(A2HomeDocument *)document error:(NSError **)error {
    if (!document) {
        [self fillError:error code:1 message:@"没有可保存的布局"];
        return NO;
    }
    if (self.isReadOnly) {
        // 只读模式：用户的布局由更新版本创建，本版一个字节都不写。
        [self fillError:error code:2 message:@"此布局由更新版本的 Air2 创建，当前版本只读"];
        [A2Log log:@"[A2-HOME] 拒绝写入：只读模式"];
        return NO;
    }

    NSDictionary *json = [document JSONObject];
    BOOL roundTripReadOnly = NO;
    A2HomeDocument *roundTrip = [A2HomeDocument documentFromJSONObject:json readOnly:&roundTripReadOnly];
    if (!roundTrip || roundTripReadOnly) {
        [self fillError:error code:3 message:@"布局校验未通过（未写盘）"];
        [A2Log log:@"[A2-HOME] 写前自检失败：normalize 往返不成立，本次不落盘"];
        return NO;
    }

    NSError *writeError = nil;
    if (![self writeJSONObject:json error:&writeError]) {
        if (error) *error = writeError;
        [A2Log log:@"[A2-HOME] 保存失败：%@", writeError.localizedDescription ?: @"未知原因"];
        return NO;
    }
    self.pendingDocument = document;
    NSData *written = [NSData dataWithContentsOfFile:self.filePath];
    A2HomeProfile *p = [document activeProfile];
    [A2Log log:@"[A2-HOME] 保存成功：方案 %lu 个 / 当前『%@』/ %lu 张卡 / %lu 字节",
                (unsigned long)document.profiles.count, p.name,
                (unsigned long)p.cards.count, (unsigned long)written.length];
    return YES;
}

- (void)scheduleSaveDocument:(A2HomeDocument *)document {
    self.pendingDocument = document;
    _saveGeneration++;
    uint64_t generation = _saveGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 250ms 合并窗口：窗口内又改过就交给更晚的那一次，避免连点写出多版。
        if (self->_saveGeneration != generation) return;
        [self flush];
    });
}

- (void)flush {
    if (!self.pendingDocument) return;
    NSError *error = nil;
    if (![self saveDocument:self.pendingDocument error:&error]) {
        [A2Log log:@"[A2-HOME] flush 失败：%@", error.localizedDescription ?: @"未知原因"];
    }
}

#pragma mark 原子写

- (BOOL)writeJSONObject:(NSDictionary *)json error:(NSError **)error {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!data) {
        [self fillError:error code:4 message:@"序列化失败"];
        return NO;
    }

    NSString *tmp = [self.filePath stringByAppendingString:@".tmp"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
    if (![data writeToFile:tmp options:0 error:&jsonError]) {
        if (error) *error = jsonError;
        return NO;
    }
    // fsync：先把 tmp 落盘，再原子替换（避免断电时留下半截文件）。
    int fd = open(tmp.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }

    // 上一版滚动成 .bak（只保留最近一份）。
    // ★主文件是坏文件时不轮转★：那样会把「刚从 .bak 恢复出来的好备份」换成坏文件。
    if (!_mainFileIsCorrupt && [NSFileManager.defaultManager fileExistsAtPath:self.filePath]) {
        [self copyFileAtPath:self.filePath toPath:self.backupPath];
    }

    // rename(2) 同卷原子替换：要么旧文件、要么新文件，不会出现「半个 JSON」。
    if (rename(tmp.fileSystemRepresentation, self.filePath.fileSystemRepresentation) != 0) {
        [self fillError:error code:5 message:@"替换布局文件失败"];
        return NO;
    }
    _mainFileIsCorrupt = NO;   // 主文件已是刚写出的合法 JSON
    return YES;
}

- (void)copyFileAtPath:(NSString *)from toPath:(NSString *)to {
    if (![NSFileManager.defaultManager fileExistsAtPath:from]) return;
    [NSFileManager.defaultManager removeItemAtPath:to error:NULL];
    [NSFileManager.defaultManager copyItemAtPath:from toPath:to error:NULL];
}

#pragma mark - 恢复默认

- (BOOL)restoreDefaultContentOfProfile:(NSString *)profileID
                            inDocument:(A2HomeDocument *)document
                                 error:(NSError **)error {
    if (self.isReadOnly) {
        [self fillError:error code:2 message:@"此布局由更新版本的 Air2 创建，当前版本只读"];
        return NO;
    }
    if (!document) {
        [self fillError:error code:1 message:@"没有可恢复的布局"];
        return NO;
    }
    A2HomeProfile *profile = [document profileWithID:profileID];
    if (!profile) {
        [self fillError:error code:6 message:@"找不到要恢复的方案"];
        return NO;
    }
    // 恢复默认前先留备份，用户后悔时还有一份。
    [self backupCurrentLayoutWithError:NULL];
    [profile resetContentToDefaultCards];
    if (![self saveDocument:document error:error]) return NO;
    [A2Log log:@"[A2-HOME] 恢复默认：方案『%@』换成 %lu 张默认卡（其它方案不动，原配置已备份）",
                profile.name, (unsigned long)profile.cards.count];
    return YES;
}

- (BOOL)backupCurrentLayoutWithError:(NSError **)error {
    // 还没有文件时无需备份。
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath]) return YES;
    NSError *copyError = nil;
    [NSFileManager.defaultManager removeItemAtPath:self.backupPath error:NULL];
    if (![NSFileManager.defaultManager copyItemAtPath:self.filePath toPath:self.backupPath error:&copyError]) {
        if (error) *error = copyError;
        [A2Log log:@"[A2-HOME] 备份失败：%@", copyError.localizedDescription ?: @"未知原因"];
        return NO;
    }
    [A2Log log:@"[A2-HOME] 已备份当前配置 → %@", self.backupPath.lastPathComponent];
    return YES;
}

#pragma mark - 导出

- (nullable NSURL *)exportDocument:(A2HomeDocument *)document error:(NSError **)error {
    if (!document) {
        [self fillError:error code:1 message:@"没有可导出的布局"];
        return nil;
    }
    NSMutableDictionary *payload = [[document JSONObject] mutableCopy];
    payload[@"app"] = @"Air2";
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    payload[@"exportedAt"] = [formatter stringFromDate:NSDate.date];

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!data) {
        if (error) *error = jsonError;
        return nil;
    }

    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.dateFormat = @"yyyyMMdd-HHmm";
    NSString *name = [NSString stringWithFormat:@"Air2-Home-%@.json", [stamp stringFromDate:NSDate.date]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    if (![data writeToFile:path options:0 error:&jsonError]) {
        if (error) *error = jsonError;
        [A2Log log:@"[A2-HOME] 导出失败：%@", jsonError.localizedDescription ?: @"未知原因"];
        return nil;
    }
    NSUInteger cards = 0;
    for (A2HomeProfile *p in document.profiles) cards += p.cards.count;
    [A2Log log:@"[A2-HOME] 导出 文件名=%@ 方案数=%lu 卡片数=%lu 字节=%lu",
                name, (unsigned long)document.profiles.count, (unsigned long)cards, (unsigned long)data.length];
    return [NSURL fileURLWithPath:path];
}

#pragma mark - 导入

- (A2HomeImportOutcome)importFromURL:(NSURL *)url
                             message:(NSString *_Nullable *_Nullable)outMessage
                            document:(A2HomeDocument *_Nullable *_Nullable)outDocument {
    NSString *fileName = url.lastPathComponent ?: @"(未命名)";
    void (^report)(NSString *) = ^(NSString *text) {
        if (outMessage) *outMessage = text;
        [A2Log log:@"[A2-HOME] 导入 文件名=%@ 结果=%@", fileName, text];
    };

    // 沙盒外的文件（「文件」App）必须包在安全作用域里读。
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (data.length == 0) {
        report(@"文件读不出来或内容为空");
        return A2HomeImportOutcomeMalformed;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!json || ![json isKindOfClass:NSDictionary.class]) {
        report(@"不是合法的 JSON 布局文件，未改动现有配置");
        return A2HomeImportOutcomeMalformed;
    }

    // 版本号门槛：更高 ⇒ 只读提示、绝不覆盖。
    NSInteger schema = A2HomeSchemaVersion;
    NSNumber *rawSchema = ((NSDictionary *)json)[@"schema"];
    if ([rawSchema isKindOfClass:NSNumber.class]) schema = rawSchema.integerValue;
    if (schema > A2HomeSchemaVersion) {
        report([NSString stringWithFormat:@"此布局由更新版本的 Air2 创建（schema %ld），当前版本无法导入，未改动现有配置",
                                          (long)schema]);
        return A2HomeImportOutcomeHigherSchema;
    }

    if (![((NSDictionary *)json)[@"profiles"] isKindOfClass:NSArray.class]) {
        report(@"文件里没有方案列表（profiles），未改动现有配置");
        return A2HomeImportOutcomeMalformed;
    }

    BOOL incomingReadOnly = NO;
    A2HomeDocument *incoming = [A2HomeDocument documentFromJSONObject:json readOnly:&incomingReadOnly];
    if (!incoming || incomingReadOnly) {
        report(@"布局结构损坏，未改动现有配置");
        return A2HomeImportOutcomeMalformed;
    }

    NSUInteger incomingCards = 0;
    for (A2HomeProfile *p in incoming.profiles) incomingCards += p.cards.count;
    if (incomingCards == 0) {
        report(@"导入文件里没有任何可用卡片，未改动现有配置");
        return A2HomeImportOutcomeEmpty;
    }

    A2HomeDocument *current = self.pendingDocument ?: [self loadDocument];
    if (self.isReadOnly) {
        report(@"当前配置处于只读模式（由更新版本创建），无法写入导入结果");
        return A2HomeImportOutcomeHigherSchema;
    }

    // ★导入前先备份当前配置★（覆盖成最近一份 .bak；导入失败也不会丢原文件）。
    [self backupCurrentLayoutWithError:NULL];

    // 合并：追加导入的方案（新 id、名字去重），现有方案一张卡都不动。
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (A2HomeProfile *p in current.profiles) [names addObject:p.name ?: @""];

    NSUInteger added = 0;
    for (A2HomeProfile *src in incoming.profiles) {
        A2HomeProfile *copy = [src copy];
        copy.profileID = NSUUID.UUID.UUIDString;
        NSString *baseName = copy.name.length ? copy.name : @"导入方案";
        NSString *name = baseName;
        NSInteger suffix = 2;
        while ([names containsObject:name]) {
            name = [NSString stringWithFormat:@"%@（导入 %ld）", baseName, (long)suffix];
            suffix++;
        }
        copy.name = name;
        [names addObject:name];
        // 卡片 id 也要重发，避免与现有方案里的 id 撞车（id 是全局唯一标识）。
        for (A2HomeCard *card in copy.cards) card.cardID = NSUUID.UUID.UUIDString;
        [current.profiles addObject:copy];
        added++;
    }
    current.activeProfileID = current.profiles.lastObject.profileID;

    NSError *saveError = nil;
    if (![self saveDocument:current error:&saveError]) {
        report([NSString stringWithFormat:@"导入后写盘失败：%@", saveError.localizedDescription ?: @"未知原因"]);
        return A2HomeImportOutcomeMalformed;
    }
    if (outDocument) *outDocument = current;
    report([NSString stringWithFormat:@"已导入 %lu 个方案 / %lu 张卡（原配置已备份为 home-layout.bak.json）",
                                      (unsigned long)added, (unsigned long)incomingCards]);
    return A2HomeImportOutcomeOK;
}

#pragma mark - 错误

- (void)fillError:(NSError **)error code:(NSInteger)code message:(NSString *)message {
    if (!error) return;
    *error = [NSError errorWithDomain:A2HomeStoreErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
