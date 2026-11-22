//
//  A2LaunchPrecheck.m
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
//  见头文件。所有方法都是同步的、只读的，由启动任务在自己的后台队列上调用。
//

#import "A2LaunchPrecheck.h"

#import "A2LaunchDiagnostics.h"
#import "A2VersionMetadata.h"
#import "A2RendererRegistry.h"
#import "A2VersionIsolation.h"
#import "A2Logger.h"

@implementation A2LaunchEnvReport

- (instancetype)init {
    self = [super init];
    if (self) {
        _modNames = @[];
    }
    return self;
}

- (nullable NSString *)loggingConfigPathForGameHome:(NSString *)gameHome {
    return [A2LaunchPrecheck loggingConfigPathForGameHome:gameHome
                                                       id:self.loggingConfigID ?: @""];
}

@end

@implementation A2LaunchPrecheck

#pragma mark - 模组

/// 对照 ZL2 GameLaunchFlow.kt checkMods（第 328~339 行）：
///   ZL2 会读 mod 元数据、检测 touchcontroller 并打开触摸代理，
///   还会在需要时给 lwjgl3ify 打补丁。Air2 目前没有这两套逻辑，
///   所以这里只做「数清楚有哪些 mod」，不假装做了别的。
///   读不出目录不阻断启动 —— mods 目录不存在是全新安装的正常状态。
+ (void)scanModsForVersion:(A2Version *)version report:(A2LaunchEnvReport *)report {
    if (!version || !report) return;

    NSString *modsDir = [version modsDirectory];
    NSArray<NSString *> *files = [NSFileManager.defaultManager
                                  contentsOfDirectoryAtPath:modsDir error:nil];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSInteger count = 0;
    for (NSString *name in files) {
        // 禁用中的模组也算「存在」：启动日志里能看到，排查问题时有用。
        if (![name hasSuffix:@".jar"] && ![name hasSuffix:@".disabled"]) continue;
        count += 1;
        if (names.count < 20) [names addObject:name];
    }

    [names sortUsingSelector:@selector(localizedStandardCompare:)];
    report.modCount = count;
    report.modNames = names;

    [A2Logger info:@"LaunchPrecheck"
           message:[NSString stringWithFormat:@"%@：mods 目录 %@，%ld 个模组",
                    version.name, modsDir, (long)count]];
}

#pragma mark - 渲染器

/// 对照 ZL2 GameLaunchFlow.kt checkRendererSupport（第 344~365 行）：
///   ZL2 先看 Vulkan 后端是否可用（可用就跳过版本检查），否则取
///   renderer.getMinMCVersion()/getMaxMCVersion() 与当前 MC 版本比较，
///   不兼容时挂起确认框。
///
///   Air2 没有「确认框后继续」的流程：版本不兼容就直接失败，
///   并明确告诉用户去「设置 → 渲染器」换一个，不假装能进游戏。
+ (BOOL)checkRendererForMCVersion:(NSString *)mcVersion
                           report:(A2LaunchEnvReport *)report
                            error:(NSError **)error {
    A2RendererRegistry *registry = A2RendererRegistry.shared;
    NSString *identifier = registry.selectedIdentifier;

    if (identifier.length == 0) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindRendererUnsupported,
                                      @"检查渲染器",
                                      @"没有选择渲染器。请到「设置 → 渲染器」选择一个可用渲染器。",
                                      nil, nil, NO);
        }
        return NO;
    }

    A2RendererEntry *entry = [registry rendererWithIdentifier:identifier];
    if (!entry) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindRendererUnsupported,
                                      @"检查渲染器",
                                      [NSString stringWithFormat:
                                       @"找不到已选择的渲染器「%@」（可能已被删除）。请重新选择。",
                                       identifier],
                                      nil, nil, NO);
        }
        return NO;
    }

    report.rendererName = entry.displayName;

    if (entry.availability != A2RendererAvailabilityAvailable) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindRendererUnsupported,
                                      @"检查渲染器",
                                      [NSString stringWithFormat:@"%@ 不可用：%@",
                                       entry.displayName,
                                       entry.unavailableReason ?: @"原因未知"],
                                      nil, nil, NO);
        }
        return NO;
    }

    if (![registry renderer:entry supportsMCVersion:mcVersion]) {
        NSString *range = [NSString stringWithFormat:@"%@ ~ %@",
                           entry.minMCVer ?: @"不限",
                           entry.maxMCVer ?: @"不限"];
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindRendererUnsupported,
                                      @"检查渲染器",
                                      [NSString stringWithFormat:
                                       @"%@ 不支持 Minecraft %@（支持范围 %@）。"
                                       @"请到「设置 → 渲染器」切换，或安装兼容的渲染器插件。",
                                       entry.displayName, mcVersion ?: @"?", range],
                                      nil, nil, NO);
        }
        return NO;
    }

    [A2Logger info:@"LaunchPrecheck"
           message:[NSString stringWithFormat:@"渲染器 %@（%@）支持 Minecraft %@",
                    entry.displayName, identifier, mcVersion ?: @"?"]];
    return YES;
}

#pragma mark - manifest

/// 对照 ZL2 GameLaunchFlow.kt 第 225~231 行：
///     VersionInfoParser(version).setInheriting(skipIfNotExists = true).build()
/// 以及 MinecraftDownloader.kt 第 150~167 行沿 inheritsFrom 递归解析。
///
/// Air2 的等价实现是 A2VersionMetadata.launchTargetForVersion:gameHome:
/// （合并父版本 + tweakVersionJson）。它返回 nil 就说明链断了 / json 坏了。
+ (nullable NSDictionary *)parseManifestForVersion:(A2Version *)version
                                            report:(A2LaunchEnvReport *)report
                                             error:(NSError **)error {
    if (!version) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                      @"解析版本清单", @"版本对象为空", nil, nil, NO);
        }
        return nil;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:version.gameHome];
    NSString *jsonPath = [path versionJSONPath:version.name];

    NSDictionary *manifest = [A2VersionMetadata launchTargetForVersion:version.name
                                                              gameHome:version.gameHome];
    if (![manifest isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                      @"解析版本清单",
                                      @"版本 JSON 缺失、无法解析，或 inheritsFrom 指向的父版本不存在。",
                                      jsonPath, nil, NO);
        }
        return nil;
    }

    // mainClass 缺失时 JVM 根本没有入口类，启动必然失败。
    // 放在检查阶段报，比让 JVM 抛 ClassNotFoundException 好排查。
    id mainClass = manifest[@"mainClass"];
    if (![mainClass isKindOfClass:NSString.class] || [mainClass length] == 0) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                      @"解析版本清单",
                                      @"版本 JSON 缺少 mainClass（无法确定游戏入口类）。",
                                      jsonPath, nil, NO);
        }
        return nil;
    }

    id libraries = manifest[@"libraries"];
    if (![libraries isKindOfClass:NSArray.class] || [(NSArray *)libraries count] == 0) {
        if (error) {
            *error = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                      @"解析版本清单",
                                      @"版本 JSON 的 libraries 为空（依赖库清单丢失）。",
                                      jsonPath, nil, NO);
        }
        return nil;
    }

    NSString *mcVersion = version.versionInfo.minecraftVersion;
    if (mcVersion.length == 0) {
        id jsonID = manifest[@"id"];
        mcVersion = [jsonID isKindOfClass:NSString.class] && [jsonID length]
                    ? jsonID : version.name;
    }
    report.mcVersion = mcVersion;
    report.launchManifest = manifest;

    // ---- 加载器版的版本 jar ----
    // 完整性检查只校验「声明了 downloads.client 的层」的 jar；Fabric/Forge
    // 的 profile 不声明 client，它的 jar 是安装时从原版硬链/复制过来的
    // （A2ModLoaderInstaller）。这个文件不在 A2IntegrityChecker 的检查范围里，
    // 却会被 A2VersionMetadata 作为 ../versions/<id>/<id>.jar 加进 classpath，
    // 所以必须在启动前单独确认。
    NSString *manifestID = manifest[@"id"];
    if (![manifestID isKindOfClass:NSString.class] || [manifestID length] == 0) {
        manifestID = version.name;
    }
    // 继承版本（加载器版）必然有自己的版本 jar；纯原版只在名字被改过时才
    // 需要单独查自己的 jar。判定用 inheritsFrom 或名字差异，任一成立都查。
    BOOL hasParent = [manifest[@"inheritsFrom"] isKindOfClass:NSString.class] &&
                     [manifest[@"inheritsFrom"] length] > 0;
    if (hasParent || ![version.name isEqualToString:mcVersion]) {
        NSString *loaderJar = [path versionJarPath:manifestID];
        if (![NSFileManager.defaultManager fileExistsAtPath:loaderJar]) {
            if (error) {
                *error = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                          @"解析版本清单",
                                          [NSString stringWithFormat:
                                           @"加载器版本 %@ 的客户端 jar 缺失。"
                                           @"这通常是安装没走完；请用「修改版本」重装加载器，"
                                           @"或删除该版本后重新安装。",
                                           version.name],
                                          loaderJar, nil, NO);
            }
            return nil;
        }
    }

    // ---- 日志配置 ----
    // 版本 json 的 logging.client.file（1.12+ 才有）。启动器通常把
    // ${path} 展开成 {assets}/log_configs/{id}；Air2 的 JVM 参数里
    // 目前不硬编码 log4j 配置，但把文件补齐，避免后续接参数时缺文件。
    id logging = manifest[@"logging"];
    if ([logging isKindOfClass:NSDictionary.class]) {
        id client = ((NSDictionary *)logging)[@"client"];
        if ([client isKindOfClass:NSDictionary.class]) {
            id file = ((NSDictionary *)client)[@"file"];
            if ([file isKindOfClass:NSDictionary.class]) {
                NSDictionary *f = file;
                id url = f[@"url"];
                id sha1 = f[@"sha1"];
                id configID = f[@"id"];
                id size = f[@"size"];

                report.loggingConfigURL = [url isKindOfClass:NSString.class] ? url : nil;
                report.loggingConfigSHA1 = [sha1 isKindOfClass:NSString.class] ? sha1 : nil;
                report.loggingConfigID = [configID isKindOfClass:NSString.class] && [configID length]
                                         ? configID : nil;
                report.loggingConfigSize = [size isKindOfClass:NSNumber.class]
                                           ? [size longLongValue] : 0;
            }
        }
    }

    [A2Logger info:@"LaunchPrecheck"
           message:[NSString stringWithFormat:
                    @"%@ 就绪：MC %@，libraries %lu，日志配置 %@",
                    version.name, mcVersion,
                    (unsigned long)[(NSArray *)libraries count],
                    report.loggingConfigID ?: @"(无)"]];
    return manifest;
}

#pragma mark - 路径

+ (nullable NSString *)loggingConfigPathForGameHome:(NSString *)gameHome
                                                 id:(NSString *)configID {
    if (gameHome.length == 0 || configID.length == 0) return nil;

    // 日志配置是 Vanilla 启动器的约定：{assets}/log_configs/{id}。
    // A2GamePath 还没有 logConfigsHome 出口（本次改动范围不含 Core/Path），
    // 所以这里和 A2GameInstaller 共用本方法，避免两处各拼一次。
    A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
    NSString *dir = [[path assetsHome] stringByAppendingPathComponent:@"log_configs"];
    return [dir stringByAppendingPathComponent:configID];
}

@end
