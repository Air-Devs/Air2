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
//  见头文件注释：收敛散落的 NSUserDefaults key，不新增任何外部依赖。
//  通知在写入线程直接 post，UI 侧收到后自行切主线程（与 ThemeManager 一致）。
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

@interface A2Settings ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation A2Settings

+ (instancetype)shared {
    static A2Settings *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2Settings alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    });
    return shared;
}

// 内部初始化点，便于单测注入独立的 suite。
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults;
    [self reloadAll];
    return self;
}

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults];
}

- (void)reloadAll {
    // 直接读底层，让内存值与磁盘一致；触发 KVO 式的全量刷新由调用方决定，
    // 这里不 post 通知，避免初始化时刷屏。
    _versionIsolation = [self boolForKey:A2SettingsKeyVersionIsolation defaultValue:NO];
    _skipIntegrityCheck = [self boolForKey:A2SettingsKeySkipIntegrityCheck defaultValue:NO];
    _ramAllocationMB = [self ramFromDefaults];
    _renderer = [self.defaults stringForKey:A2SettingsKeyRenderer];
    _preferredContentPlatform = [self integerForKey:A2SettingsKeyPreferredContentPlatform
                                      defaultValue:A2SettingsPlatformModrinth];
    _mirrorPriority = [self integerForKey:A2SettingsKeyMirrorPriority
                             defaultValue:A2SettingsMirrorOfficialFirst];
    _mirrorEnabled = [self boolForKey:A2SettingsKeyMirrorEnabled defaultValue:YES];
    _currentAccountID = [self.defaults stringForKey:A2SettingsKeyCurrentAccountID];
    _currentVersionName = [self.defaults stringForKey:A2SettingsKeyCurrentVersionName];
    _autoLogin = [self boolForKey:A2SettingsKeyAutoLogin defaultValue:YES];
}

- (void)resetAllToDefaults {
    NSArray<NSString *> *keys = @[
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
    for (NSString *k in keys) {
        [self.defaults removeObjectForKey:k];
    }
    [self reloadAll];
    [[NSNotificationCenter defaultCenter] postNotificationName:A2SettingsDidChangeNotification
                                                        object:self
                                                      userInfo:nil];
}

#pragma mark - 取值 helpers（处理“缺 key 时的默认值”，boolForKey 会把缺 key 当 NO）

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    // 缺 key 时用默认值，而不是 boolForKey 的 NO。
    if ([self.defaults objectForKey:key] == nil) return def;
    return [self.defaults boolForKey:key];
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    if ([self.defaults objectForKey:key] == nil) return def;
    return [self.defaults integerForKey:key];
}

- (NSInteger)ramFromDefaults {
    // 历史 key 缺省时 2048；存在则钳到下限，避免读到 0 导致启动即 OOM 配置。
    if ([self.defaults objectForKey:A2SettingsKeyRAMAllocationMB] == nil) return 2048;
    NSInteger v = [self.defaults integerForKey:A2SettingsKeyRAMAllocationMB];
    return MAX(v, A2SettingsMinRAMMB);
}

- (void)notifyKey:(NSString *)key {
    [[NSNotificationCenter defaultCenter] postNotificationName:A2SettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{A2SettingsChangedKeyKey: key}];
}

#pragma mark - 属性存取（写穿透到 NSUserDefaults，保证进程重启不丢）

- (void)setVersionIsolation:(BOOL)v {
    _versionIsolation = v;
    [self.defaults setBool:v forKey:A2SettingsKeyVersionIsolation];
    [self notifyKey:A2SettingsKeyVersionIsolation];
}

- (void)setSkipIntegrityCheck:(BOOL)v {
    _skipIntegrityCheck = v;
    [self.defaults setBool:v forKey:A2SettingsKeySkipIntegrityCheck];
    [self notifyKey:A2SettingsKeySkipIntegrityCheck];
}

- (void)setRamAllocationMB:(NSInteger)v {
    // 钳到下限：ZL2 同款 min = 256，0/负数配下去 JVM 起不来。
    v = MAX(v, A2SettingsMinRAMMB);
    _ramAllocationMB = v;
    [self.defaults setInteger:v forKey:A2SettingsKeyRAMAllocationMB];
    [self notifyKey:A2SettingsKeyRAMAllocationMB];
}

- (void)setRenderer:(NSString *)v {
    _renderer = [v copy];
    if (v) {
        [self.defaults setObject:v forKey:A2SettingsKeyRenderer];
    } else {
        [self.defaults removeObjectForKey:A2SettingsKeyRenderer];
    }
    [self notifyKey:A2SettingsKeyRenderer];
}

- (void)setPreferredContentPlatform:(NSInteger)v {
    // 只接受两种取值，脏数据回落到 Modrinth，避免越界。
    if (v != A2SettingsPlatformCurseForge) v = A2SettingsPlatformModrinth;
    _preferredContentPlatform = v;
    [self.defaults setInteger:v forKey:A2SettingsKeyPreferredContentPlatform];
    [self notifyKey:A2SettingsKeyPreferredContentPlatform];
}

- (void)setMirrorPriority:(NSInteger)v {
    if (v != A2SettingsMirrorFirst) v = A2SettingsMirrorOfficialFirst;
    _mirrorPriority = v;
    [self.defaults setInteger:v forKey:A2SettingsKeyMirrorPriority];
    [self notifyKey:A2SettingsKeyMirrorPriority];
}

- (void)setMirrorEnabled:(BOOL)v {
    _mirrorEnabled = v;
    [self.defaults setBool:v forKey:A2SettingsKeyMirrorEnabled];
    [self notifyKey:A2SettingsKeyMirrorEnabled];
}

- (void)setCurrentAccountID:(NSString *)v {
    _currentAccountID = [v copy];
    if (v) {
        [self.defaults setObject:v forKey:A2SettingsKeyCurrentAccountID];
    } else {
        [self.defaults removeObjectForKey:A2SettingsKeyCurrentAccountID];
    }
    [self notifyKey:A2SettingsKeyCurrentAccountID];
}

- (void)setCurrentVersionName:(NSString *)v {
    _currentVersionName = [v copy];
    if (v) {
        [self.defaults setObject:v forKey:A2SettingsKeyCurrentVersionName];
    } else {
        [self.defaults removeObjectForKey:A2SettingsKeyCurrentVersionName];
    }
    [self notifyKey:A2SettingsKeyCurrentVersionName];
}

- (void)setAutoLogin:(BOOL)v {
    _autoLogin = v;
    [self.defaults setBool:v forKey:A2SettingsKeyAutoLogin];
    [self notifyKey:A2SettingsKeyAutoLogin];
}

@end
