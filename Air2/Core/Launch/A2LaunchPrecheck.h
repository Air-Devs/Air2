//
//  A2LaunchPrecheck.h
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
//  启动前环境检查（纯函数，不持有流程状态）。
//
//  ## 对照 ZL2 的哪几步
//
//  ZL2 GameLaunchFlow.kt 的「检查游戏环境」任务（第 213~242 行）一次做完：
//    · checkMods()              扫描 mods，识别 touchcontroller / lwjgl3ify
//      （第 328~339 行）
//    · checkRendererSupport()   渲染器可用性与 min/max MC 版本
//      （第 344~365 行）
//    · VersionInfoParser        解析并合并版本 manifest（第 225~231 行）
//
//  Air2 把这三件事拆成独立任务，便于 UI 逐项显示等待/进行中/失败。
//  本文件只负责「查」，不负责调度、不上报进度，失败一律用
//  A2LaunchDiagnostics 的字段格式返回，调用方补上任务名即可。
//
//  ## 和 ZL2 的差异（有意为之）
//
//    · Air2 没有「忽略渲染器不兼容继续启动」的确认框，所以版本不兼容
//      在这里直接失败，并告诉用户改哪个设置；不假装能继续。
//    · ZL2 的 touchcontroller / lwjgl3ify 补丁逻辑 Air2 尚未移植，
//      这里只统计、记录，不假装打了补丁。
//    · 日志配置（logging.client.file）ZL2 的下载函数是注释掉的
//      （BaseMinecraftDownloader.kt 第 189~199 行），Air2 把它补上：
//      启动时若声明了但本地缺失，就补下载（见 A2IntegrityRepairer 之外的
//      A2GameLaunchCoordinator 校验任务）。
//

#import <Foundation/Foundation.h>

#import "A2VersionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 一次环境检查的产物。各步骤按顺序填充，缺哪步就是哪步没跑。
@interface A2LaunchEnvReport : NSObject

/// mods 目录里 .jar / .jar.disabled 的数量
@property (nonatomic, assign) NSInteger modCount;
/// 模组文件名（最多 20 个，仅用于日志/诊断，不用于业务判断）
@property (nonatomic, copy) NSArray<NSString *> *modNames;
/// 当前选择的渲染器显示名（未选择时为 nil）
@property (nonatomic, copy, nullable) NSString *rendererName;
/// 解析并完成 iOS 适配后的 launch manifest（A2VersionMetadata 的输出）
@property (nonatomic, copy, nullable) NSDictionary *launchManifest;
/// 实际用于兼容性判断的 MC 版本
@property (nonatomic, copy, nullable) NSString *mcVersion;

/// 日志配置声明（版本 json 的 logging.client.file）
@property (nonatomic, copy, nullable) NSString *loggingConfigID;
@property (nonatomic, copy, nullable) NSString *loggingConfigURL;
@property (nonatomic, copy, nullable) NSString *loggingConfigSHA1;
/// 0 表示 json 未声明大小
@property (nonatomic, assign) long long loggingConfigSize;

/// 日志配置在本机的落盘路径：{assets}/log_configs/{id}
- (nullable NSString *)loggingConfigPathForGameHome:(NSString *)gameHome;

@end

@interface A2LaunchPrecheck : NSObject

/// 扫描 mods。目录不存在 / 读不出时按 0 个处理（不阻断启动）。
+ (void)scanModsForVersion:(A2Version *)version report:(A2LaunchEnvReport *)report;

/// 渲染器兼容性检查。
/// 失败时返回 NO 并通过 error 返回 A2LaunchDiagnostics 格式的错误。
+ (BOOL)checkRendererForMCVersion:(NSString *)mcVersion
                           report:(A2LaunchEnvReport *)report
                            error:(NSError **)error;

/// 解析版本 manifest（沿 inheritsFrom 合并 + iOS 适配），并做启动必需项校验：
///   · mainClass 存在
///   · libraries 非空
///   · 加载器版的版本 jar 存在（原版 jar 由完整性检查负责，不在这里挡）
///   · 提取 logging.client.file
///
/// @return 可直接用于启动的 manifest；失败返回 nil 并填 error。
+ (nullable NSDictionary *)parseManifestForVersion:(A2Version *)version
                                            report:(A2LaunchEnvReport *)report
                                             error:(NSError **)error;

/// 日志配置落盘路径（对 A2GameInstaller 也公开，避免两处拼路径不一致）。
+ (nullable NSString *)loggingConfigPathForGameHome:(NSString *)gameHome
                                                 id:(NSString *)configID;

@end

NS_ASSUME_NONNULL_END
