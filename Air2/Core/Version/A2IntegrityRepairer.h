//
//  A2IntegrityRepairer.h
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
//  完整性修复 —— 把 A2IntegrityChecker 报出来的缺失/损坏文件补回来。
//
//  ## 为什么单独一个类
//
//  校验要能跑在启动前的快路径上（几百次 stat，秒级），
//  修复则必然拖动网络栈、镜像解析、并发调度。
//  把一个「只读」检查器塞进下载依赖，等于让所有调用方都被迫链接下载栈。
//
//  ## 做法（对照 ZL2）
//
//  ZL2 在 MinecraftDownloader(mode = VERIFY_AND_REPAIR) 里把
//  「计划下载」直接铺进同一批任务：校验与补下载共用 scheduleDownload，
//  引擎在【开始前】按本地 SHA1 判断能否复用，不能就下。
//
//  Air2 的 A2DownloadEngine 恰好也是这个语义（startRequest 前先校验本地文件），
//  所以修复器的做法就是：
//    1. 把报告里的问题项翻译成 A2DownloadRequest（带 sha1 + size + 镜像候选）
//    2. 损坏的先删（大小/SHA1 不符的文件留着只会让引擎白算一遍 SHA1）
//    3. 交给 A2BatchDownloader 并发跑
//    4. 跑完用同一档强度复检，把「还没修好的」放进 postReport 交给界面
//
//  ## 修不了的情况（如实返回，不假装成功）
//
//  · 版本 json 缺失 / 父版本 json 缺失 / json 损坏
//    —— json 里没有它自己的下载地址（根版本可以查版本清单，加载器 profile 不行），
//       只能重装该版本。这类项进 unrepairableIssues。
//  · 依赖库条目本身没给 url 且推导不出 —— 同样进 unrepairableIssues。
//
//  ## 线程
//
//  progress / completion 都在主线程回调。
//  同一实例只应发起一次修复；需要并发修多个版本就建多个实例。
//

#import <Foundation/Foundation.h>
#import "A2IntegrityChecker.h"

NS_ASSUME_NONNULL_BEGIN

/// 修复阶段（UI 拿它决定显示「清理损坏文件」还是「下载」）
typedef NS_ENUM(NSInteger, A2IntegrityRepairPhase) {
    A2IntegrityRepairPhaseRemoveCorrupted = 0,  ///< 删损坏文件（很快）
    A2IntegrityRepairPhaseDownload,             ///< 批量补下载
    A2IntegrityRepairPhaseVerify,               ///< 修完复检
};

/// 修复结果
@interface A2IntegrityRepairResult : NSObject

/// 删掉的损坏文件数（缺失的不算删除）
@property (nonatomic, assign) NSInteger removedCorruptedFiles;
/// 进入下载队列的文件数
@property (nonatomic, assign) NSInteger scheduledFiles;
/// 下载成功的文件数
@property (nonatomic, assign) NSInteger succeededFiles;
/// 下载失败的文件：path → error
@property (nonatomic, copy) NSDictionary<NSString *, NSError *> *failuresByPath;
/// 无法自动修复的项（版本 json 缺失等），需要重装
@property (nonatomic, copy) NSArray<A2IntegrityIssue *> *unrepairableIssues;
/// 修复后的复检报告（未复检时为 nil，例如被取消 / 没有版本名）
@property (nonatomic, strong, nullable) A2IntegrityReport *postReport;
/// 是否被取消
@property (nonatomic, assign) BOOL cancelled;

/// 修复后是否干净（没复检过时为 NO —— 没验过不能算干净）
@property (nonatomic, readonly) BOOL clean;
/// 复检后仍存在的问题（没复检时为空）
@property (nonatomic, readonly) NSArray<A2IntegrityIssue *> *remainingIssues;

/// 一行中文摘要
- (NSString *)summaryText;

@end

@interface A2IntegrityRepairer : NSObject

/// 校验 + 修复一条龙。
///
/// @param versionName 版本名
/// @param gameHome 游戏根目录
/// @param verifyMode 校验/复检强度（修复后按同一档复检）
/// @param scope 校验范围（与 A2IntegrityChecker 一致）
/// @param progress 进度（主线程）
/// @param completion 结果（主线程）
- (void)repairVersion:(NSString *)versionName
             gameHome:(NSString *)gameHome
           verifyMode:(A2IntegrityCheckMode)verifyMode
                scope:(A2IntegrityScope)scope
             progress:(nullable void (^)(A2IntegrityRepairPhase phase,
                                         double fraction,
                                         NSString *message))progress
           completion:(void (^)(A2IntegrityRepairResult *result))completion;

/// 对一份已有报告做修复（省掉重新扫描）。
///
/// 注意：gameHome 与 scope 仍要传 —— 修复后要复检，
/// 复检必须用同一份路径根与同一份范围，否则「修好了没」判断不准。
- (void)repairReport:(A2IntegrityReport *)report
            gameHome:(NSString *)gameHome
          verifyMode:(A2IntegrityCheckMode)verifyMode
               scope:(A2IntegrityScope)scope
            progress:(nullable void (^)(A2IntegrityRepairPhase phase,
                                        double fraction,
                                        NSString *message))progress
          completion:(void (^)(A2IntegrityRepairResult *result))completion;

/// 取消。只影响本实例发起的批量下载，不会去动别人正在下的文件。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
