//
//  ForgeProcessorExecutor.h
//  Amethyst
//
//  新格式 Forge/NeoForge 直装的 install_profile processors 执行器（共用核心）。
//
//  参照 ZalithLauncher2 / HMCL 的 ForgeNewInstallTask：在本地执行
//  install_profile.json 的 processors（binarypatcher、jarsplitter、
//  ForgeAutoRenamingTool、installertools 等），生成 FML 运行时必需的
//  PATCHED / MC_SRG / MC_EXTRA 等 artifact。
//
//  iOS 沙箱禁止 fork/exec，无法为每个 processor spawn 子 JVM，
//  因此命令被序列化为 commands.json，由进程内 headless JVM 中的
//  net.kdt.pojavlaunch.tools.ForgeProcessorRunner 逐条执行
//  （见 JavaApp/src/launcher/net/kdt/pojavlaunch/tools/ForgeProcessorRunner.java
//   与 JavaLauncher.m 的 launchHeadlessJVM）。
//
//  注意：执行过 processors 后进程内 JVM 已创建，再次创建 JVM 会崩溃，
//  游戏启动前必须重启 app（见 jvmUsedThisProcess 与 JavaLauncher.m 的
//  gJvmUsedInProcess 防御检查）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ForgeProcessorExecutorErrorDomain;

typedef NS_ENUM(NSInteger, ForgeProcessorExecutorErrorCode) {
    ForgeProcessorExecutorErrorInvalidProfile     = 1, // install_profile 数据缺失/非法
    ForgeProcessorExecutorErrorMissingLibrary     = 2, // processor jar/classpath 库文件缺失
    ForgeProcessorExecutorErrorDownloadFailed     = 3, // mappings / 原版 client.jar 下载失败
    ForgeProcessorExecutorErrorLaunchFailed       = 4, // headless JVM 启动失败
    ForgeProcessorExecutorErrorProcessingFailed   = 5, // processor 执行失败（含 sha1 校验失败）
    ForgeProcessorExecutorErrorJvmAlreadyUsed     = 6, // 本进程已跑过 processors，需重启 app
};

@interface ForgeProcessorExecutor : NSObject

/// 执行新格式 Forge/NeoForge 的 install_profile processors（仅 client side）。
///
/// 前置条件（由调用方保证）：
///   - install_profile.libraries 中的库已下载/解压到 <mainGameDir>/libraries/
///     （processor 的 jar 与 classpath 全部来自这份清单）
///
/// 内部流程：
///   1. 构建 vars（data.*.client + SIDE/MINECRAFT_JAR/ROOT/INSTALLER/LIBRARY_DIR，
///      plain 值从安装器 zip 解压到 .temp/forge_installer_cache/）
///   2. 预下载原版 client.jar（MINECRAFT_JAR，sha1 校验）
///   3. 预下载 client mappings（替代 DOWNLOAD_MOJMAPS processor，sha1 校验）
///   4. 构建 client side 命令清单（outputs 已就绪的命令跳过，支持断点续装）
///   5. 写 commands.json，调用 launchHeadlessJVM 运行 ForgeProcessorRunner，
///      并行轮询 status.json 上报进度
///   6. 读终态校验结果，成功后清理 .temp/forge_installer_cache
///
/// @param installProfile   已解析的 install_profile.json
/// @param installerPath    安装器 jar 路径（vars 的 plain 值解压来源、INSTALLER 变量）
/// @param minecraftVersion 原版 MC 版本（如 "1.20.1"，用于定位 versions/{mc}/{mc}.json/.jar）
/// @param mainGameDir      主目录（POJAV_GAME_DIR，libraries/versions 所在地）
/// @param baseProgress     进度区间起点（processor 执行阶段映射到 [base, base+span]）
/// @param progressSpan     进度区间跨度
+ (BOOL)runProcessorsWithProfile:(NSDictionary *)installProfile
                   installerPath:(NSString *)installerPath
                minecraftVersion:(NSString *)minecraftVersion
                      mainGameDir:(NSString *)mainGameDir
                    baseProgress:(double)baseProgress
                   progressSpan:(double)progressSpan
                        progress:(nullable void (^)(double progress, NSString *stageMessage))progress
                           error:(NSError **)error;

/// 当前进程是否已用 headless JVM 跑过 processors。
/// 为 YES 时游戏启动必须重启 app（进程内 JVM 只能创建一次）。
+ (BOOL)jvmUsedThisProcess;

NS_ASSUME_NONNULL_END

@end
