//
//  A2Settings.m
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
//  见头文件注释：收敛散落的设置 key，不新增任何外部依赖。
//  存储在 Documents/config.json（JSON 字典，key 与历史 UserDefaults 同名，
//  老用户首次启动一次性迁入，不丢值）。通知在写入线程直接 post，
//  UI 侧收到后自行切主线程（与 ThemeManager 一致）。
//

#import "A2Settings.h"

NSNotificationName const A2SettingsDidChangeNotification = @"A2SettingsDidChangeNotification";
NSString *const A2SettingsChangedKeyKey = @"key";

NSString *const A2SettingsKeyVersionIsolation = @"A2GlobalVersionIsolation";
NSString *const A2SettingsKeySkipIntegrityCheck = @"A2GlobalSkipIntegrityCheck";
NSString *const A2SettingsKeyRAMAllocationMB = @"A2GlobalRAM";
NSString *const A2SettingsKeyRenderer = @"A2GlobalRenderer";
NSString *const A2SettingsKeyPreferredContentPlatform = @"A2PreferredContentPlatform";
NSString *const A2SettingsKeyMirrorPriority = @"A2MirrorPriority";
NSString *const A2SettingsKeyMirrorEnabled = @"A2MirrorEnabled";
NSString *const A2SettingsKeyCurrentAccountID = @"A2CurrentAccountID";
NSString *const A2SettingsKeyCurrentVersionName = @"A2CurrentVersionName";
NSString *const A2SettingsKeyAutoLogin = @"A2AutoLogin";

/// 托管 key 全集（读写与迁移共用，增减设置只改这一处）。
static NSArray<NSString *> *A2SettingsAllKeys(void) {
    return @[
        A2SettingsKeyVersionIsolation,
        A2SettingsKeySkipIntegrityCheck,
        A2SettingsKeyRAMAllocationMB,
        A2SettingsKeyRenderer,
        A2SettingsKeyPreferredContentPlatform,
        A2SettingsKeyMirrorPriority,
        A2SettingsKeyMirrorEnabled,
        A2SettingsKeyCurrentAccountID,
        A2SettingsKeyCurrentVersionName,
        A2SettingsKeyAutoLogin,
    ];
}

@interface A2Settings ()
/// 内存镜像（文件内容的 authoritative copy，读写串行化）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *store;
@end

@implementation A2Settings

+ (instancetype)shared {
    static A2Settings *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2Settings alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    @synchronized (self) {
        _store = [[self loadStore] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    [self reloadAll];
    return self;
}

#pragma mark - 文件（唯一出口）

+ (NSString *)configPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"config.json"];
}

// 读文件；文件不存在则从 UserDefaults 一次性迁入（老用户不丢值），
// 迁完即落盘，下次不再读 UserDefaults。
- (NSDictionary<NSString *, id> *)loadStore {
    NSString *path = [A2Settings configPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) return json;
        // 坏文件不崩：改名备份后从空开始，避免每次读写都失败。
        NSString *broken = [path stringByAppendingString:@".broken"];
        [NSFileManager.defaultManager removeItemAtPath:broken error:nil];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:broken error:nil];
    }
    NSMutableDictionary<NSString *, id> *migrated = [NSMutableDictionary dictionary];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *k in A2SettingsAllKeys()) {
        id v = [d objectForKey:k];
        if (v) migrated[k] = v;
    }
    if (migrated.count > 0) {
        NSData *out = [NSJSONSerialization dataWithJSONObject:migrated options:0 error:nil];
        if (out) [out writeToFile:path atomically:YES];
    }
    return migrated;
}

// 调用方需已持有 @synchronized(self)。
- (void)saveStoreLocked {
    NSData *data = [NSJSONSerialization dataWithJSONObject:_store options:0 error:nil];
    if (data) [data writeToFile:[A2Settings configPath] atomically:YES];
}

- (void)reloadAll {
    // 直接读底层，让内存值与磁盘一致；触发 KVO 式的全量刷新由调用方决定，
    // 这里不 post 通知，避免初始化时刷屏。
    _versionIsolation = [self boolForKey:A2SettingsKeyVersionIsolation defaultValue:NO];
    _skipIntegrityCheck = [self boolForKey:A2SettingsKeySkipIntegrityCheck defaultValue:NO];
    _ramAllocationMB = [self ramFromStore];
    _renderer = [self stringForKey:A2SettingsKeyRenderer];
    _preferredContentPlatform = [self integerForKey:A2SettingsKeyPreferredContentPlatform
                                      defaultValue:A2SettingsPlatformModrinth];
    _mirrorPriority = [self integerForKey:A2SettingsKeyMirrorPriority
                             defaultValue:A2SettingsMirrorOfficialFirst];
    _mirrorEnabled = [self boolForKey:A2SettingsKeyMirrorEnabled defaultValue:YES];
    _currentAccountID = [self stringForKey:A2SettingsKeyCurrentAccountID];
    _currentVersionName = [self stringForKey:A2SettingsKeyCurrentVersionName];
    _autoLogin = [self boolForKey:A2SettingsKeyAutoLogin defaultValue:YES];
}

- (void)resetAllToDefaults {
    @synchronized (self) {
        [_store removeAllObjects];
        [self saveStoreLocked];
    }
    [self reloadAll];
    [[NSNotificationCenter defaultCenter] postNotificationName:A2SettingsDidChangeNotification
                                                        object:self
                                                      userInfo:nil];
}

#pragma mark - 取值 helpers（缺 key 时给默认值；类型不对也给默认值，不崩）

- (id)objectForKey:(NSString *)key {
    @synchronized (self) {
        return _store[key];
    }
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self objectForKey:key];
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    return def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self objectForKey:key];
    if ([v isKindOfClass:NSNumber.class]) return [v integerValue];
    return def;
}

- (NSString *)stringForKey:(NSString *)key {
    id v = [self objectForKey:key];
    if ([v isKindOfClass:NSString.class]) return v;
    return nil;
}

- (NSInteger)ramFromStore {
    // 缺省 2048；存在则钳到下限，避免读到 0 导致启动即 OOM 配置。
    id v = [self objectForKey:A2SettingsKeyRAMAllocationMB];
    if (![v isKindOfClass:NSNumber.class]) return 2048;
    return MAX([v integerValue], A2SettingsMinRAMMB);
}

- (void)setObject:(id)value forKey:(NSString *)key {
    @synchronized (self) {
        if (value) {
            _store[key] = value;
        } else {
            [_store removeObjectForKey:key];
        }
        [self saveStoreLocked];
    }
    [self notifyKey:key];
}

- (void)notifyKey:(NSString *)key {
    [[NSNotificationCenter defaultCenter] postNotificationName:A2SettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{A2SettingsChangedKeyKey: key}];
}

#pragma mark - 属性存取（写穿透到 config.json，保证进程重启不丢）

- (void)setVersionIsolation:(BOOL)v {
    _versionIsolation = v;
    [self setObject:@(v) forKey:A2SettingsKeyVersionIsolation];
}

- (void)setSkipIntegrityCheck:(BOOL)v {
    _skipIntegrityCheck = v;
    [self setObject:@(v) forKey:A2SettingsKeySkipIntegrityCheck];
}

- (void)setRamAllocationMB:(NSInteger)v {
    // 钳到下限：ZL2 同款 min = 256，0/负数配下去 JVM 起不来。
    v = MAX(v, A2SettingsMinRAMMB);
    _ramAllocationMB = v;
    [self setObject:@(v) forKey:A2SettingsKeyRAMAllocationMB];
}

- (void)setRenderer:(NSString *)v {
    _renderer = [v copy];
    [self setObject:v forKey:A2SettingsKeyRenderer];
}

- (void)setPreferredContentPlatform:(NSInteger)v {
    // 只接受两种取值，脏数据回落到 Modrinth，避免越界。
    if (v != A2SettingsPlatformCurseForge) v = A2SettingsPlatformModrinth;
    _preferredContentPlatform = v;
    [self setObject:@(v) forKey:A2SettingsKeyPreferredContentPlatform];
}

- (void)setMirrorPriority:(NSInteger)v {
    if (v != A2SettingsMirrorFirst) v = A2SettingsMirrorOfficialFirst;
    _mirrorPriority = v;
    [self setObject:@(v) forKey:A2SettingsKeyMirrorPriority];
}

- (void)setMirrorEnabled:(BOOL)v {
    _mirrorEnabled = v;
    [self setObject:@(v) forKey:A2SettingsKeyMirrorEnabled];
}

- (void)setCurrentAccountID:(NSString *)v {
    _currentAccountID = [v copy];
    [self setObject:v forKey:A2SettingsKeyCurrentAccountID];
}

- (void)setCurrentVersionName:(NSString *)v {
    _currentVersionName = [v copy];
    [self setObject:v forKey:A2SettingsKeyCurrentVersionName];
}

- (void)setAutoLogin:(BOOL)v {
    _autoLogin = v;
    [self setObject:@(v) forKey:A2SettingsKeyAutoLogin];
}

@end
