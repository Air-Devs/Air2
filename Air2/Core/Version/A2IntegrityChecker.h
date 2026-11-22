//
//  A2IntegrityChecker.h
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
//  游戏文件完整性检查。
//
//  ## 为什么需要（不是锦上添花）
//
//  启动失败的常见原因之一就是文件损坏：
//    · 下载时镜像给错区间（大小对、内容坏）
//    · 断点续传把两个版本的文件拼在一起
//    · 磁盘写满导致文件截断
//    · 用户手动改过 jar/mod
//
//  没有完整性检查时，这些错误表现为
//  「NoClassDefFoundError」「解压失败」「进不去游戏」——
//  用户完全看不出是文件问题。
//
//  ## 查什么（字段逐项对齐）
//
//  | 对象        | 路径                                  | 参与比较的字段            |
//  | ----------- | ------------------------------------- | ------------------------- |
//  | 版本 JSON   | versions/<id>/<id>.json               | 仅存在性（json 未提供自校验 sha1） |
//  | 客户端 jar  | versions/<id>/<id>.jar                | downloads.client.size + .sha1 |
//  | 依赖库      | libraries/<artifact.path>             | libraries[].downloads.artifact.size + .sha1 |
//  | 资源索引    | assets/indexes/<assets>.json          | assetIndex.size + .sha1    |
//  | 资源对象    | assets/objects/<h[0:2]>/<h>           | objects[].size + hash（hash 就是 sha1）|
//
//  ## 继承链（关键修正）
//
//  加载器版（Fabric/Forge/NeoForge）的 json 只有
//  {id, inheritsFrom, libraries}，jar / 半数依赖库 / 资源都在父版本里。
//  所以必须**沿 inheritsFrom 逐层向上收集**，按「子覆盖父」去重：
//    · 子层声明的库优先（加载器自己的 jar）
//    · 缺父 json = 整条链断，单独报（A2IntegrityReasonParentMissing）
//    · 环引用要能停下来（最多 16 层，记一条 Unreadable）
//
//  对照 ZL2：`createGameInstalledTask` 里合并 json 后按合并结果校验；
//  我们没有常驻的合并产物（每次启动现算），所以校验时现场解析继承链。
//
//  ## 不查什么（有意跳过，别当漏项）
//
//  · `natives` / `downloads.classifiers` —— iOS 不用原生库
//  · `org.lwjgl*` —— 由启动器自带 dylib 提供
//  · rules 判定为不适用的库
//  这三类在 A2VersionMetadata.m 的 tweakVersionJson 里同样打了 skip，
//  校验口径必须与启动口径一致，否则会「修不完的假问题」。
//
//  ## 两档检查
//
//    快速：只查文件是否存在 + 大小（秒级，几百个文件）
//    完整：逐个算 SHA1（分钟级，但能发现内容损坏）
//
//  默认用快速档 —— 多数情况够用；怀疑损坏时让用户选完整档。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 检查强度
typedef NS_ENUM(NSInteger, A2IntegrityCheckMode) {
    A2IntegrityCheckModeQuick = 0,   ///< 存在 + 大小
    A2IntegrityCheckModeFull,        ///< 逐个 SHA1
};

/// 问题分类。修复方式按类走（版本 json 缺了只能重装，库缺了能补下）。
typedef NS_ENUM(NSInteger, A2IntegritySection) {
    A2IntegritySectionVersionJSON = 0,  ///< 版本 json（含父版本 json）
    A2IntegritySectionClientJar,        ///< 客户端 jar
    A2IntegritySectionLibraries,        ///< 依赖库
    A2IntegritySectionAssetIndex,       ///< 资源索引
    A2IntegritySectionAssetObjects,     ///< 资源对象
};

/// 问题原因。用枚举而不是比字符串 —— 修复逻辑要靠它分流。
typedef NS_ENUM(NSInteger, A2IntegrityReason) {
    A2IntegrityReasonMissing = 0,       ///< 文件不存在
    A2IntegrityReasonSizeMismatch,      ///< 大小不符
    A2IntegrityReasonSHA1Mismatch,      ///< SHA1 不符（内容损坏）
    A2IntegrityReasonParentMissing,     ///< inheritsFrom 指向的父版本 json 缺失
    A2IntegrityReasonUnreadable,        ///< json 解析失败 / 继承成环 / 读不出
};

/// 检查范围。分成位掩码是因为「只查客户端」和「连资源一起查」
/// 的耗时差两个数量级，界面要能分开给按钮。
typedef NS_OPTIONS(NSUInteger, A2IntegrityScope) {
    A2IntegrityScopeNone         = 0,
    A2IntegrityScopeVersionJSON  = 1 << 0,
    A2IntegrityScopeClientJar    = 1 << 1,
    A2IntegrityScopeLibraries    = 1 << 2,
    A2IntegrityScopeAssetIndex   = 1 << 3,
    A2IntegrityScopeAssetObjects = 1 << 4,

    A2IntegrityScopeAll = (A2IntegrityScopeVersionJSON |
                           A2IntegrityScopeClientJar |
                           A2IntegrityScopeLibraries |
                           A2IntegrityScopeAssetIndex |
                           A2IntegrityScopeAssetObjects),
};

/// 分类的稳定键（用于按类聚合、持久化；不要拿中文展示名当键）
FOUNDATION_EXPORT NSString *A2IntegritySectionKey(A2IntegritySection section);
/// 分类的中文展示名
FOUNDATION_EXPORT NSString *A2IntegritySectionDisplayName(A2IntegritySection section);

/// 一个有问题（缺失 / 损坏）的文件
@interface A2IntegrityIssue : NSObject

/// 绝对路径
@property (nonatomic, copy) NSString *path;
/// 人类可读类别（"客户端" / "依赖库" / "资源" ...）—— 兼容旧字段
@property (nonatomic, copy) NSString *kind;
/// 人类可读原因（"缺失" / "大小不符（…）" / "SHA1 不符（内容损坏）"）—— 兼容旧字段
@property (nonatomic, copy) NSString *reason;
/// 分类（程序分流用）
@property (nonatomic, assign) A2IntegritySection section;
/// 原因（程序分流用）
@property (nonatomic, assign) A2IntegrityReason reasonKind;
/// 期望 SHA1（未知时为 nil）
@property (nonatomic, copy, nullable) NSString *expectedSHA1;
/// 期望大小（0 表示 json 未声明）
@property (nonatomic, assign) long long expectedSize;
/// 实测大小（缺失时为 -1）
@property (nonatomic, assign) long long actualSize;
/// 可用的下载地址（已展开镜像候选）；空数组 = 不能自动修复，只能重装/手动处理
@property (nonatomic, copy) NSArray<NSString *> *downloadURLs;
/// 该文件归属的版本层（继承链上的某一层 id）
@property (nonatomic, copy, nullable) NSString *versionID;
/// 修复时是否需要先删旧文件（大小/SHA1 不符 → YES，缺失 → NO）
@property (nonatomic, readonly) BOOL needsRemovalBeforeRepair;

@end

/// 检查结果
@interface A2IntegrityReport : NSObject

/// 参与比较的文件总数（含版本 json 各层）
@property (nonatomic, assign) NSInteger totalFiles;
/// 通过的文件数
@property (nonatomic, assign) NSInteger okFiles;
/// 问题清单（按「版本 json → 客户端 → 依赖库 → 资源索引 → 资源」收集）
@property (nonatomic, copy) NSArray<A2IntegrityIssue *> *issues;
/// 耗时（秒）
@property (nonatomic, assign) NSTimeInterval elapsed;
/// 全部通过
@property (nonatomic, readonly) BOOL clean;

/// 继承链解析结果，自身 → 根原版（如 @[@"1.21.5-fabric", @"1.21.5"]）
@property (nonatomic, copy) NSArray<NSString *> *versionChain;
/// 继承链是否断开（缺父 json / 成环 / json 读不出）
@property (nonatomic, assign) BOOL chainBroken;

/// 缺失（含父版本缺失）数量
@property (nonatomic, readonly) NSInteger missingCount;
/// 损坏（大小/SHA1 不符）数量
@property (nonatomic, readonly) NSInteger corruptedCount;
/// 不可自动修复（没有下载地址）的数量
@property (nonatomic, readonly) NSInteger unrepairableCount;

/// 按分类聚合的问题数，key 为 A2IntegritySectionKey 的返回值
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *issueCountsBySection;

/// 一行中文摘要（日志 / 提示条用）
- (NSString *)summaryText;

@end

@interface A2IntegrityChecker : NSObject

/// 检查某个版本（全范围，含资源对象）。
///
/// @param versionName 版本名（可以是加载器版，内部沿 inheritsFrom 向上查）
/// @param gameHome 游戏根目录
/// @param mode 检查强度
/// @param progress 进度回调（0~1，当前文件名；主线程）
/// @param completion 结果（主线程）
- (void)checkVersion:(NSString *)versionName
            gameHome:(NSString *)gameHome
                mode:(A2IntegrityCheckMode)mode
            progress:(nullable void (^)(double progress, NSString *currentFile))progress
          completion:(void (^)(A2IntegrityReport *report))completion;

/// 指定范围的检查。checkVersion: 是它的全范围包装。
///
/// @param scope 位掩码，控制查哪几类（资源对象最耗时，可按需关闭）
- (void)verifyVersion:(NSString *)versionName
             gameHome:(NSString *)gameHome
                 mode:(A2IntegrityCheckMode)mode
                scope:(A2IntegrityScope)scope
             progress:(nullable void (^)(double progress, NSString *currentFile))progress
           completion:(void (^)(A2IntegrityReport *report))completion;

/// 解析版本继承链（自身 → 根）。遇到缺父 / 成环时停在那里。
///
/// 抽成类方法是因为修复器和 modifyVersion 也要走同一条链，
/// 三处各写一遍必然有一天不一致。
///
/// @param broken 出参，可为 NULL。链是否断开
+ (NSArray<NSString *> *)resolvedVersionChainFor:(NSString *)versionName
                                        gameHome:(NSString *)gameHome
                                          broken:(BOOL * _Nullable)broken;

/// 文件 SHA1（小写十六进制）。读不出时返回 nil。
/// 公开是因为修复后复检、modifyVersion 的 journal 校验都要用同一份实现。
+ (nullable NSString *)sha1OfFile:(NSString *)path;

/// 兼容旧接口：把报告里「损坏」的文件删掉，让下次下载重新拉。
///
/// 注意：这只删文件，**不下载**。真正带下载的修复是 A2IntegrityRepairer。
/// 保留它是因为启动流程里还有一处依赖（A2GameLaunchCoordinator）。
///
/// @return 删除成功的文件数
- (NSInteger)repairReport:(A2IntegrityReport *)report;

@end

NS_ASSUME_NONNULL_END
