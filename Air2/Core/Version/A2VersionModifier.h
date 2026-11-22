//
//  A2VersionModifier.h
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
//  在**已安装**的版本上更换 / 追加模组加载器，不重装游戏本体。
//
//  ## 为什么不能直接调 A2ModLoaderInstaller
//
//  A2ModLoaderInstaller 会「读原版 json → 合并 → 直接写 versions/<name>/<name>.json」。
//  对着已安装版本用就是就地覆盖：中途失败、被杀进程、磁盘满，
//  版本里就只剩半个 json —— 用户原本的版本也没了。
//  所以这里把它当成「生成器」用：喂一个临时 gameHome，产物落在临时目录，
//  确认能解析、能对得上，才动真目录。
//
//  ## 流程（对照 ZL2 的 getModifyTaskPhase / createVersionModifiedTask）
//
//  ZL2 的顺序是：
//    清理临时目录 → 下载原版到临时目录 → 装加载器 → 合并 json 到临时输出目录
//    → 迁移 libraries → 复制新 mods → swapVersionFiles（备份 + 替换 + 失败还原）
//
//  Air2 的顺序（少一步「下载原版」，因为原版已在盘上且要复用）：
//    1. 恢复上次中断（有 journal 就按 journal 决定还原或清理）
//    2. 解析目标版本的继承链，拿到基底原版版本名（root）
//    3. 在 Caches 下建临时 gameHome，把基底原版的 json/jar 放进去
//       —— A2ModLoaderInstaller 只认 versions/<mc>/ 这一份原版
//    4. 用临时 gameHome 跑 A2ModLoaderInstaller，产物落在临时目录
//    5. 校验产物（能解析 / 有 mainClass / id 正确）
//    6. 把临时 libraries 并进真实 libraries（不覆盖更不删除已有文件）
//    7. 备份真实 json/jar → 原子 rename 换入新文件 → 校验 → 删备份
//       任何一步失败：从备份还原，并把错误如实抛出
//    8. 清临时目录
//
//  ## 原版就地加加载器（target == 基底原版）
//
//  ZL2 的 mergeGameJson 在「自定义名 == 游戏版本名」时会把两层合并成一份
//  自包含 json（不加 inheritsFrom）—— 否则就是自己继承自己，启动必然崩。
//  这里同样处理：把基底 json 内联进产物再写回，规则见 .m 里的
//  A2InlineMergeVersionJSON。注意这只动 json/jar，**不动** saves/mods。
//
//  ## 不支持的类型（明确拒绝，不假装成功）
//
//  OptiFine / LiteLoader / Rift / Babric 走不了自动安装
//  （A2ModLoaderInstallerSupportsAutoInstall 为 NO，ZL2 也标 autoDownloadable=false）。
//  传进来会直接失败并说明原因，不会把版本改坏。
//

#import <Foundation/Foundation.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

/// 修改阶段（UI 分步清单直接用这个）
typedef NS_ENUM(NSInteger, A2VersionModifyStage) {
    A2VersionModifyStagePrepare = 0,    ///< 检查版本、恢复中断、建临时目录
    A2VersionModifyStageResolveLoader,  ///< 查询加载器可用版本
    A2VersionModifyStageInstallLoader,  ///< 在临时目录装加载器
    A2VersionModifyStageMergeLibraries, ///< 并入库文件
    A2VersionModifyStageSwapFiles,      ///< 备份 + 原子替换 json/jar
    A2VersionModifyStageFinalize,       ///< 清理临时目录
    A2VersionModifyStageCount,
};

/// 阶段中文名
FOUNDATION_EXPORT NSString *A2VersionModifyStageName(A2VersionModifyStage stage);

/// 修改请求
@interface A2VersionModifyRequest : NSObject

/// 要修改的**已安装**版本名（版本目录必须存在）
@property (nonatomic, copy) NSString *versionName;
/// 游戏根目录
@property (nonatomic, copy) NSString *gameHome;
/// 目标加载器类型。只能用 A2ModLoaderIsLoader 为 YES 的类型
@property (nonatomic, assign) A2ModLoaderType loaderType;
/// 加载器版本；nil 表示自动取最新稳定版
@property (nonatomic, copy, nullable) NSString *loaderVersion;

@end

/// 修改器
@interface A2VersionModifier : NSObject

/// 修改版本（异步）。
///
/// @param progress 阶段进度（主线程）
/// @param completion 完成回调（主线程）。失败时 error 说明具体原因
- (void)modifyVersion:(A2VersionModifyRequest *)request
             progress:(nullable void (^)(A2VersionModifyStage stage,
                                         double progress,
                                         NSString *message))progress
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 取消。
///
/// 取消只在阶段边界生效（加载器安装本身没有取消接口）。
/// 已经进入替换阶段时不会中止 —— 换文件要么做完要么回滚，中途停下比失败更糟。
- (void)cancel;

/// 恢复一次被中断的替换。
///
/// 替换前会写 `.a2_modify_journal.json`（含新 json 的 SHA1）。
/// 下次进版本页 / 启动前调一次：
///   · 目标 json 的 SHA1 与新文件一致 → 说明替换已完成，清掉残留备份
///   · 不一致 → 从 `.a2bak` 还原
/// 没有 journal 时直接返回 YES（无事可做）。
+ (BOOL)recoverInterruptedModifyForVersion:(NSString *)versionName
                                  gameHome:(NSString *)gameHome
                                     error:(NSError **)error;

/// 是否有未完成的替换（UI 可据此提示「上次修改未完成」）
+ (BOOL)hasPendingModifyForVersion:(NSString *)versionName gameHome:(NSString *)gameHome;

@end

NS_ASSUME_NONNULL_END
