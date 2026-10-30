//
//  PLProfiles.m
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
//  PLProfiles.m
//  Amethyst
//
//  Profile manager with JSON-safe save
//

#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "A2Settings.h"
#import "A2VersionManager.h"
#import "A2JREManager.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    id rawValue = profile[key];
    // 兼容 javaVersion 字段：Mojang 规范是 NSDictionary（{component, majorVersion}），
    // 但部分代码（如 ForgeDirectInstaller）也写入 NSDictionary。PLProfiles 期望返回 NSString。
    if ([rawValue isKindOfClass:[NSDictionary class]]) {
        // javaVersion: 返回 majorVersion 的字符串值；缺失则落入下方 valueDefaults
        id major = rawValue[@"majorVersion"];
        if (major) return [major description];
        // 落入下方 valueDefaults 逻辑，避免返回 nil 破坏调用方
    } else if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length] > 0) {
        return rawValue;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        // LWJGL 版本："auto" = MC 26.x 及以上用 3.4.1，其余用 3.3.3。
        // profile 里显式存 "333"/"341" 时以显式值为准。
        @"lwjglVersion": @"auto",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    // ---- 渲染器：优先 A2Settings，回落 Air1 的 video.renderer ----
    //
    // 之前只读 getPrefObject(@"video.renderer")，那是 Air1 的偏好键，
    // Air2 的渲染器设置存在 A2Settings.renderer 里 —— 两边不通，
    // 结果 resolveKeyForCurrentProfile:@"renderer" 返回 nil，
    // GameSurfaceView.layerClass 所有分支都不匹配，渲染器完全失效。
    if ([key isEqualToString:@"renderer"]) {
        NSString *r = A2Settings.shared.renderer;
        if (r.length > 0) return r;
    }

    // ---- javaVersion 同理：Air1 的 java.java_homes 偏好键，Air2 不用 ----
    //
    // JavaLauncher.m:1508 会读这个键：
    //     int preferredJavaVersion = [PLProfiles resolveKey:@"javaVersion"].intValue;
    //     if (preferredJavaVersion > 0) minVersion = preferredJavaVersion;
    //
    // 返回 0 时不会覆盖调用方的 minVersion，但也失去了兜底作用。
    // 这里返回 A2JREManager 对当前版本选中的 JRE 版本，让两边一致。
    if ([key isEqualToString:@"javaVersion"]) {
        A2Version *cur = A2VersionManager.shared.currentVersion;
        if (cur) {
            NSString *mc = cur.versionInfo.minecraftVersion ?: cur.name;
            A2JRE *jre = [A2JREManager.shared jreForVersionName:cur.name mcVersion:mc];
            if (jre.majorVersion > 0) {
                return [NSString stringWithFormat:@"%ld", (long)jre.majorVersion];
            }
        }
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer",
        // MC 26.2+ Graphics API（OpenGL/Vulkan 游戏内切换），缺省为 "default"
        // 该字段仅在 MC 26.2+ 生效，旧版本会被 MC 忽略，无副作用。
        @"graphicsApi": @"video.graphics_api"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];

    // ⚠️ getenv 可能返回 NULL —— @(NULL) 会变成
    // +[NSString stringWithUTF8String:]: NULL cString，直接崩。
    // Air1 靠 POJAV_GAME_DIR 环境变量拿游戏目录，我们的路径
    // 走 A2VersionManager，这个变量不一定被设过。
    const char *gameDirEnv = getenv("POJAV_GAME_DIR");
    NSString *gameDir = gameDirEnv ? [NSString stringWithUTF8String:gameDirEnv] : nil;
    if (gameDir.length == 0) {
        // 兜底：用 A2 的游戏目录
        gameDir = [A2VersionManager shared].gameHome ?: NSTemporaryDirectory();
    }
    self.profilePath = [gameDir stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    return self;
}

- (id)profiles {
    id profiles = self.profileDict[@"profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) {
        profiles = [NSMutableDictionary dictionary];
        self.profileDict[@"profiles"] = profiles;
    } else if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
        profiles = [profiles mutableCopy];
        self.profileDict[@"profiles"] = profiles;
    }
    return profiles;
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:name];
}

/// 递归清理 NSDate 等非法 JSON 类型，确保保存不崩溃
- (id)jsonSanitizedObject:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:obj];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            id safeKey = [key isKindOfClass:[NSDate class]] ? [self jsonSanitizedObject:key] : key;
            clean[safeKey] = [self jsonSanitizedObject:val];
        }];
        return clean;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id item in obj) {
            [clean addObject:[self jsonSanitizedObject:item]];
        }
        return clean;
    }
    return obj;
}

- (void)save {
    id sanitized = [self jsonSanitizedObject:self.profileDict];
    if ([NSJSONSerialization isValidJSONObject:sanitized]) {
        saveJSONToFile(sanitized, self.profilePath);
    } else {
        NSLog(@"[PLProfiles] save failed: profileDict still contains invalid JSON types after sanitization");
    }
}

- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name {
    if (!self.profileDict[@"profiles"]) {
        self.profileDict[@"profiles"] = [NSMutableDictionary dictionary];
    }
    self.profileDict[@"profiles"][name] = profile;
    [self save];
}

#pragma mark - 服务器地址（FCL 风格：启动后自动加入服务器）

// 获取当前选中 profile 的服务器地址，留空返回 @""
- (NSString *)serverIpForCurrentProfile {
    return [self serverIpForProfile:self.selectedProfileName];
}

// 获取指定 profile 的服务器地址，缺失或为空均返回 @""
- (NSString *)serverIpForProfile:(NSString *)profileName {
    NSString *ip = self.profiles[profileName][@"serverIp"];
    return ip ?: @"";
}

// 设置指定 profile 的服务器地址，nil 转为 @""
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName {
    NSMutableDictionary *profile = [self.profiles[profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"serverIp"] = serverIp ?: @"";
    self.profiles[profileName] = profile;
    [self save];
}

@end
