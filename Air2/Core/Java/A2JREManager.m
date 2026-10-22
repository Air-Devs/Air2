//
//  A2JREManager.m
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
//  A2JREManager.m
//  Air2
//

#import "A2JREManager.h"
#import "A2Logger.h"

NSNotificationName const A2JREsDidChangeNotification = @"A2JREsDidChangeNotification";

static NSString *const kImportedJREKey = @"A2ImportedJREs";     // [{id, name, path}]
static NSString *const kVersionJREKey  = @"A2VersionJRE";       // {versionName: jreIdentifier}

@interface A2JRE ()
@property (nonatomic, assign, readwrite) BOOL valid;
@property (nonatomic, copy, nullable, readwrite) NSString *invalidReason;
@end

@implementation A2JRE
@end

@interface A2JREManager ()
@property (nonatomic, strong) NSMutableArray<A2JRE *> *jres;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *versionAssignments;
@end

@implementation A2JREManager

+ (instancetype)shared {
    static A2JREManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2JREManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _jres = [NSMutableArray array];
    [self reload];
    return self;
}

#pragma mark - 扫描

/// 内置 JRE 目录：App bundle 里的 java_runtimes
- (NSString *)builtinJRERoot {
    NSString *path = [NSBundle.mainBundle.resourcePath
                      stringByAppendingPathComponent:@"java_runtimes"];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    // 打包脚本把它放在 .app 根目录
    NSString *alt = [[NSBundle.mainBundle.bundlePath
                      stringByAppendingPathComponent:@"java_runtimes"] copy];
    if ([NSFileManager.defaultManager fileExistsAtPath:alt]) return alt;
    return nil;
}

/// 用户导入的 JRE 放在沙盒 Documents/Air2/JREs/
- (NSString *)importedJRERoot {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Air2/JREs"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)reload {
    NSMutableArray<A2JRE *> *found = [NSMutableArray array];

    // ---- 内置 ----
    NSString *builtinRoot = [self builtinJRERoot];
    if (builtinRoot) {
        [found addObjectsFromArray:[self scanDirectory:builtinRoot builtin:YES]];
    }

    // ---- 用户导入 ----
    [found addObjectsFromArray:[self scanDirectory:[self importedJRERoot] builtin:NO]];

    // 按主版本号排序
    [found sortUsingComparator:^NSComparisonResult(A2JRE *a, A2JRE *b) {
        if (a.majorVersion != b.majorVersion) {
            return a.majorVersion < b.majorVersion ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.displayName compare:b.displayName];
    }];

    self.jres = found;

    // 读版本分配
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kVersionJREKey];
    self.versionAssignments = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];

    [NSNotificationCenter.defaultCenter postNotificationName:A2JREsDidChangeNotification
                                                      object:nil];

    [A2Logger info:@"JREManager"
           message:[NSString stringWithFormat:@"扫描到 %lu 个 JRE（%lu 个可用）",
                    (unsigned long)found.count,
                    (unsigned long)[self validJREs].count]];
}

- (NSArray<A2JRE *> *)validJREs {
    NSMutableArray *out = [NSMutableArray array];
    for (A2JRE *j in self.jres) if (j.valid) [out addObject:j];
    return out;
}

- (NSArray<A2JRE *> *)scanDirectory:(NSString *)root builtin:(BOOL)builtin {
    NSMutableArray<A2JRE *> *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil];

    for (NSString *name in entries) {
        NSString *full = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (!isDir) continue;

        // 有效 JRE 的标志：lib/server/libjvm.dylib
        NSString *libjvm = [[full stringByAppendingPathComponent:@"lib/server"]
                            stringByAppendingPathComponent:@"libjvm.dylib"];

        A2JRE *jre = [A2JRE new];
        jre.identifier = name;
        jre.path = full;
        jre.builtin = builtin;

        // 从目录名推版本：java-17-openjdk → 17
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"java-(\\d+)" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:name options:0
                                                   range:NSMakeRange(0, name.length)];
        if (m && m.numberOfRanges > 1) {
            jre.majorVersion = [[name substringWithRange:[m rangeAtIndex:1]] integerValue];
        } else {
            jre.majorVersion = 0;
        }
        jre.displayName = jre.majorVersion > 0
            ? [NSString stringWithFormat:@"Java %ld", (long)jre.majorVersion]
            : name;

        // 从 release 文件读架构
        NSString *release = [full stringByAppendingPathComponent:@"release"];
        if ([fm fileExistsAtPath:release]) {
            NSString *content = [NSString stringWithContentsOfFile:release
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
            if ([content containsString:@"aarch64"]) jre.arch = @"arm64";
            else if ([content containsString:@"x86_64"]) jre.arch = @"x86_64";
        }

        jre.valid = [fm fileExistsAtPath:libjvm];
        jre.invalidReason = jre.valid ? nil
            : @"缺少 lib/server/libjvm.dylib —— 不是有效的 JRE 目录";

        [out addObject:jre];
    }
    return out;
}

#pragma mark - 查询

- (NSArray<A2JRE *> *)allJREs {
    return [self.jres copy];
}

/// MC 版本 → 需要的 Java 主版本
- (NSInteger)requiredJavaVersionForMC:(NSString *)mcVersion {
    if (mcVersion.length == 0) return 17;

    // 取前两段：1.21.4 → 1.21
    NSArray<NSString *> *parts = [mcVersion componentsSeparatedByString:@"."];
    NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;
    NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 1;

    if (major >= 26) return 25;          // 26.x 是新的版本命名
    if (minor >= 21) return 21;
    if (minor >= 17) return 17;
    return 8;
}

- (A2JRE *)jreForMCVersion:(NSString *)mcVersion {
    NSInteger need = [self requiredJavaVersionForMC:mcVersion];
    NSArray<A2JRE *> *valid = [self validJREs];

    // 优先精确匹配
    for (A2JRE *j in valid) {
        if (j.majorVersion == need) return j;
    }
    // 其次找 >= 需求的最低版本（Java 向后兼容）
    A2JRE *best = nil;
    for (A2JRE *j in valid) {
        if (j.majorVersion >= need && (!best || j.majorVersion < best.majorVersion)) {
            best = j;
        }
    }
    return best ?: valid.firstObject;
}

- (A2JRE *)jreForVersionName:(NSString *)versionName mcVersion:(NSString *)mcVersion {
    // 用户手动指定优先
    NSString *assigned = self.versionAssignments[versionName];
    if (assigned.length) {
        for (A2JRE *j in self.jres) {
            if ([j.identifier isEqualToString:assigned] && j.valid) return j;
        }
    }
    return [self jreForMCVersion:mcVersion];
}

- (BOOL)assignJRE:(A2JRE *)jre forVersionName:(NSString *)versionName error:(NSError **)error {
    if (versionName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2JREManager" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"版本名为空"}];
        }
        return NO;
    }

    if (jre) {
        if (!jre.valid) {
            if (error) {
                *error = [NSError errorWithDomain:@"A2JREManager" code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        jre.invalidReason ?: @"JRE 不可用"}];
            }
            return NO;
        }
        self.versionAssignments[versionName] = jre.identifier;
    } else {
        [self.versionAssignments removeObjectForKey:versionName];
    }

    [NSUserDefaults.standardUserDefaults setObject:self.versionAssignments
                                            forKey:kVersionJREKey];
    [NSNotificationCenter.defaultCenter postNotificationName:A2JREsDidChangeNotification
                                                      object:nil];
    return YES;
}

#pragma mark - 导入 / 删除

- (BOOL)importJREFromURL:(NSURL *)url error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    // 校验：必须是有效 JRE
    NSString *libjvm = [[url.path stringByAppendingPathComponent:@"lib/server"]
                        stringByAppendingPathComponent:@"libjvm.dylib"];
    if (![fm fileExistsAtPath:libjvm]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2JREManager" code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"选中的目录不是有效的 JRE（缺 lib/server/libjvm.dylib）"}];
        }
        return NO;
    }

    // 复制进沙盒
    NSString *dest = [[self importedJRERoot] stringByAppendingPathComponent:url.lastPathComponent];
    if ([fm fileExistsAtPath:dest]) {
        [fm removeItemAtPath:dest error:nil];
    }

    // 外部目录需要安全作用域
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtPath:url.path toPath:dest error:&copyErr];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!ok) {
        if (error) *error = copyErr;
        return NO;
    }

    [self reload];
    return YES;
}

- (BOOL)removeJRE:(A2JRE *)jre error:(NSError **)error {
    if (jre.builtin) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2JREManager" code:4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"内置 JRE 不能删除（随 App 打包）"}];
        }
        return NO;
    }

    NSError *rmErr = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:jre.path error:&rmErr]) {
        if (error) *error = rmErr;
        return NO;
    }

    // 清掉指向它的版本分配
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSString *ver in self.versionAssignments) {
        if ([self.versionAssignments[ver] isEqualToString:jre.identifier]) {
            [toRemove addObject:ver];
        }
    }
    [self.versionAssignments removeObjectsForKeys:toRemove];
    [NSUserDefaults.standardUserDefaults setObject:self.versionAssignments
                                            forKey:kVersionJREKey];

    [self reload];
    return YES;
}

@end
