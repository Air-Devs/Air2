//
//  A2PluginManifest.h
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
//  manifest.json 解析与校验（插件系统 P1 数据层第一步）。
//
//  ## 这一层做什么、不做什么
//
//  做：把包根 manifest.json 变成**不可变**的模型对象，并把 `plugin.schema.json`
//      的约束用**手写校验**表达一遍（不引第三方 JSON Schema 库 —— 依赖越少，
//      安装链越不容易在真机上因为别人的库出问题）。
//
//  不做：不碰磁盘、不读 zip、不算哈希、不判组合风险（`launch.args` + `java.agent`
//      那类拒装组合由安装器第 ⑤ 步判定）、不查依赖是否已安装（那要读注册表）。
//      本层只回答一个问题：「这份 manifest 能不能进入安装流程？」。
//
//  ## 为什么「未知字段」必须拒
//
//  schema 里 additionalProperties 全为 false。放行的后果不是「多一个字段」，
//  而是「作者以为生效了」：把 `permissons` 拼错成 `permission` 的插件会装成功，
//  然后在运行时发现权限一个都没授予。宁可安装期报错并指出字段名。
//
//  ## 为什么路径穿越在「任一字符串」上查
//
//  manifest 里能塞路径的地方不止 `files[].path`：`entry`、`locales` 的值、
//  `ui.pages[].source`、`native.ios`。逐个字段写检查早晚会漏一个，
//  所以这里对整棵树做一遍「任何字符串含 `..` / 绝对路径 / 反斜杠 / 控制字符」
//  的兜底扫描，再对各路径字段做字符集与长度检查。宁可误拒一条 normal 文案，
//  也不能放过一个 `../../../Library/Preferences/...`。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 错误码

/// 安装失败原因的错误域。所有失败都带 `A2PluginErrorCodeKey`（机器可读码）
/// 与 `NSLocalizedDescriptionKey`（一句人话原因，直接进管理页）。
extern NSString *const A2PluginErrorDomain;

/// userInfo 键：机器可读错误码字符串（`E_*`），见 `A2PluginErrorCodeString`。
extern NSString *const A2PluginErrorCodeKey;

/// userInfo 键：出错的字段路径（如 `files[3].path`）。没有具体字段时不存在。
extern NSString *const A2PluginErrorFieldKey;

/// 安装期错误码。机器码是**本枚举**给出的那套；每条后面的「文档码」标注它对应
/// `docs/PLUGIN-AUTHORING.md` 第十二节失败原因表里的哪一行 —— 一个文档码可能被
/// 拆成多个机器码（作者看到更具体的原因），但**不存在**没有文档行的机器码。
/// 管理页展示机器码，作者文档按文档码查表。
typedef NS_ENUM(NSInteger, A2PluginError) {
    A2PluginErrorNone = 0,
    /// JSON 整体不成立：空文件、带 BOM、语法错、根节点不是对象。
    /// 文档码：`E_SCHEMA`（包根缺 manifest.json 时另见 `E_MANIFEST_MISSING`，同归此码）。
    A2PluginErrorFormat,
    /// 字段层不成立：缺必填、类型不符、未知字段、取值非法、重复项。
    /// 文档码：`E_SCHEMA`。
    A2PluginErrorField,
    /// 包格式版本不受支持（< 2 或 > 宿主最大值）。
    /// 文档码：`E_FORMAT_VERSION`。
    A2PluginErrorFormatVersion,
    /// `permissions` 里出现目录之外的权限 id。
    /// 文档码：`E_SCHEMA`（权限枚举值非法）。
    A2PluginErrorPermUnknown,
    /// 路径穿越：任一字符串含 `..` / 绝对路径 / 反斜杠 / 控制字符。
    /// 文档码：`E_PATH_ESCAPE`（符号链接条目另见安装器的 `E_LINK`）。
    A2PluginErrorPath,
    /// 超出上限：文件数、路径长度、单文件大小、包体大小。
    /// 文档码：`E_SIZE_LIMIT`。
    A2PluginErrorSize,
    /// `type` 不是 `json` / `js`（`native` 属 P5 的附加字段，不是 type 值）。
    /// 文档码：`E_TYPE_UNSUPPORTED` / `E_NATIVE_UNSUPPORTED`。
    A2PluginErrorTypeUnsupported,
    /// `platforms` 不含当前平台（宿主只承诺 ios）。
    /// 文档码：`E_PLATFORM`。
    A2PluginErrorPlatform,
    /// `type: json` 申请了只有 JS 才能用的运行时权限。
    /// 文档码：`E_JSON_PERM`。
    A2PluginErrorJsonPerm,
    /// 包根出现了已移除的签名文件（`AIR2SIG.json`）。
    /// 文档码：`E_LEGACY_SIGNATURE`。
    A2PluginErrorLegacySignature,

    // ---- 以下为安装器（zip 层与版本规则）新增 ----

    /// zip 条目路径会落到包目录之外（`..` 段 / 绝对路径 / 盘符 / 反斜杠），
    /// 或中央目录与本地文件头声明的名字不一致。
    /// 文档码：`E_PATH_ESCAPE`。
    A2PluginErrorZipSlip,
    /// 包内出现符号链接 / 硬链接条目（zip 的外部属性位标记）。
    /// 文档码：`E_PATH_ESCAPE`（「包里有符号链接」那一行）。
    A2PluginErrorLink,
    /// 装的是低于已装版本的包，且未开开发者模式。
    /// 文档码：`E_DOWNGRADE`。
    A2PluginErrorDowngrade,
    /// 同 id 同版本但内容摘要不同 —— 包被换过。
    /// 文档码：`E_SAME_VERSION_DIFFERENT_CONTENT`。
    A2PluginErrorSameVersionDifferentContent,
    /// `manifest.files` 与包内实际文件集合不一致。
    /// 文档码：`E_FILE_SET_MISMATCH`。
    A2PluginErrorFileSetMismatch,
    /// 包内某个文件的 SHA-256 / 字节数与 `manifest.files` 声明不符。
    /// 文档码：`E_HASH_MISMATCH`。
    A2PluginErrorHashMismatch,
    /// 宿主侧 IO 失败：建目录 / 换目录 / 删目录 / 写注册表。
    /// 文档码：无对应行（不是包的问题，是宿主的磁盘或权限问题）。
    A2PluginErrorIO,
    /// 没有可回退的上一版（未安装，或上一版目录已不在）。
    /// 文档码：无对应行（宿主状态，不是包的问题）。
    A2PluginErrorNoPreviousVersion,
    /// 该插件随 App 打包，不允许卸载。
    /// 文档码：无对应行（宿主策略，不是包的问题）。
    A2PluginErrorBuiltin,
};

/// 错误码的字符串形式（`E_FORMAT` / `E_FIELD` / …）。
FOUNDATION_EXPORT NSString *A2PluginErrorCodeString(A2PluginError code);

/// 构造一条安装期错误：域 + `E_*` 机器码 + 可选字段路径 + 一句话原因。
/// 校验层、解包层、安装器共用这一处构造 —— 管理页只认这一套 userInfo，
/// 各处各拼一遍的话，早晚有一个地方漏掉 `A2PluginErrorCodeKey`，失败就变成没有码的弹窗。
/// @param field 出错的字段路径（如 `files[3].path`），没有具体字段时传 nil
FOUNDATION_EXPORT NSError *A2PluginErrorMake(A2PluginError code,
                                             NSString *_Nullable field,
                                             NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

#pragma mark - 权限风险级

/// 权限风险级。取值与 `docs/PLUGIN-SECURITY.md` 第二节权限目录一致。
/// `A2PluginRiskUnknown` 表示「不在目录里」，正常的 manifest 不会走到这里。
typedef NS_ENUM(NSInteger, A2PluginRisk) {
    A2PluginRiskUnknown = 0,
    A2PluginRiskLow,
    A2PluginRiskMedium,
    A2PluginRiskCritical,
};

/// 权限 id → 风险级。目录外的 id 返回 `A2PluginRiskUnknown`。
/// 这张表是「权限集」规范串（registry 的 `permissionSet`）的唯一来源：
/// critical 授权绑定的是 `id:risk` 集合，风险级变了就是权限集变了。
FOUNDATION_EXPORT A2PluginRisk A2PluginRiskForPermission(NSString *permissionId);

/// 风险级的字符串形式（`low` / `medium` / `critical` / `unknown`），
/// 用于拼「权限集」规范串与落盘。
FOUNDATION_EXPORT NSString *A2PluginRiskName(A2PluginRisk risk);

#pragma mark - 标识与版本

/// 插件 id 是否合法：小写字母/数字/点/下划线/连字符，至少两段，3～128 字符。
/// 注册表的写入校验与 manifest 校验共用这一处，避免两边规则漂移。
FOUNDATION_EXPORT BOOL A2PluginIsValidIdentifier(NSString *identifier);

/// 插件版本是否合法：`x.y.z` 或 `x.y.z-<prerelease>`（不允许 01.0.0）。
FOUNDATION_EXPORT BOOL A2PluginIsValidVersion(NSString *version);

/// 按语义化版本比较两个合法版本：`a < b` 返回负数，相等返回 0，`a > b` 返回正数
/// （与 `strcmp` 同约定，便于直接当比较器用）。
/// 判定「降级安装」只有这一处口径 —— 字符串比大小会把 `1.10.0` 判得比 `1.9.0` 小。
/// 传入不合法的版本返回 0（调用方在解析阶段已经拒过非法版本）。
FOUNDATION_EXPORT NSInteger A2PluginCompareVersions(NSString *a, NSString *b);

#pragma mark - 路径

/// 包内相对路径的判定结果。安装器与 manifest 校验共用这一处规则 ——
/// 两边各写一套的后果是「zip 放行了、manifest 拒了」这种只有用户才会遇到的怪状态。
typedef NS_ENUM(NSInteger, A2PluginPathVerdict) {
    A2PluginPathVerdictOK = 0,
    /// 会跑到包目录之外：含 `..`、以 `/` 开头、盘符形式（`C:`）、反斜杠、控制字符。
    A2PluginPathVerdictEscaping,
    /// 超过长度上限。
    A2PluginPathVerdictTooLong,
    /// 字符集外（只允许字母数字 `.` `_` `-` `/`），或以 `.` 开头（隐藏文件）。
    A2PluginPathVerdictIllegalCharacters,
};

/// 判定一条包内相对路径。
/// @param path 不带前导 `/` 的包内路径；目录条目请先去掉尾随 `/`
/// @param maxLength 路径长度上限（字节数按 UTF-8 算，与 `PLUGIN-SYSTEM.md` 3.3 一致）
FOUNDATION_EXPORT A2PluginPathVerdict A2PluginInspectPackagePath(NSString *path,
                                                                NSUInteger maxLength);

#pragma mark - 上限

/// 安装期上限。由安装器传入（它才知道包体与条目数），本层只提供判定入口。
/// 取值就是 `docs/PLUGIN-SYSTEM.md` 3.3「硬性上限」表对外承诺的数字
/// —— 文档是唯一口径，代码不另立更严或有别的值。
///
/// 一行对应 3.3 的一行：
///   maxPackageBytes       包文件大小        64 MB
///   maxExtractedBytes     解压后总大小     256 MB   （zip 层用）
///   maxFileCount          文件数           4096
///   maxSingleFileBytes    单文件解压后大小  32 MB   （zip 层用）
///   maxPathLength         路径长度         255 字节
///   maxPathDepth          路径深度         8 层    （zip 层用）
///   maxCompressionRatio   单文件压缩比     100:1   （zip 层用）
///
/// 用 `A2PluginDefaultLimits()` 填，不要自己逐个摆字段：漏填的 0 会被当成
/// 「上限为零」，那时所有包都会被拒，而错误信息看起来像是包的问题。
typedef struct A2PluginLimits {
    unsigned long long maxPackageBytes;
    unsigned long long maxExtractedBytes;
    NSUInteger maxFileCount;
    unsigned long long maxSingleFileBytes;
    NSUInteger maxPathLength;
    NSUInteger maxPathDepth;
    NSUInteger maxCompressionRatio;
} A2PluginLimits;

/// 默认上限（就是 3.3 那张表的数字：64 MB / 256 MB / 4096 / 32 MB / 255 / 8 / 100）。
FOUNDATION_EXPORT A2PluginLimits A2PluginDefaultLimits(void);

#pragma mark - 依赖

/// 一条 `depends` 声明。安装期由安装器解析（缺失 / 版本不符 / 循环 → 拒装）。
@interface A2PluginDependency : NSObject

/// 被依赖插件的 id。
@property (nonatomic, copy, readonly) NSString *pluginId;

/// 版本约束原文：`x.y.z` / `=x.y.z` / `>=x.y.z` / `^x.y.z` / `~x.y.z`。
@property (nonatomic, copy, readonly) NSString *versionConstraint;

@end

#pragma mark - 文件清单

/// `manifest.files` 的一条。安装器的完整性校验按这份清单逐条算 SHA-256。
@interface A2PluginFileEntry : NSObject

/// 包内相对路径（不允许 `..`、绝对路径、反斜杠）。
@property (nonatomic, copy, readonly) NSString *path;

/// 64 位小写 hex（不带 `sha256:` 前缀）。
@property (nonatomic, copy, readonly) NSString *sha256;

/// 解压后字节数。
@property (nonatomic, assign, readonly) unsigned long long size;

@end

#pragma mark - manifest

/// 包格式版本里 `type` 的两个合法值。`native` 不是 type 值（P5 走 `native` 字段）。
typedef NS_ENUM(NSInteger, A2PluginType) {
    A2PluginTypeJSON = 0,
    A2PluginTypeJS,
};

/// 解析并校验过的一份 manifest。不可变：构造完就不再改，调用方可以随意传递。
@interface A2PluginManifest : NSObject

/// 包格式版本：2（P1/P2/P3a 基线）或 3（P3b 起）。不是 API 版本，也不是插件版本。
@property (nonatomic, assign, readonly) NSInteger formatVersion;

/// 全局唯一插件 id（反向域名风格）。
@property (nonatomic, copy, readonly) NSString *pluginId;

/// 展示名（未本地化时的回退值）。
@property (nonatomic, copy, readonly) NSString *name;

/// 插件自身语义化版本。
@property (nonatomic, copy, readonly) NSString *version;

/// 插件三型里的两型（`json` / `js`）。
@property (nonatomic, assign, readonly) A2PluginType type;

/// 一句话说明（管理页展示）。
@property (nonatomic, copy, readonly, nullable) NSString *summary;

/// 作者名 —— **作者自述**，不是身份认证，展示时必须标注「自述」。
@property (nonatomic, copy, readonly, nullable) NSString *authorName;

/// 作者主页（可选，`http(s)://`）。
@property (nonatomic, copy, readonly, nullable) NSString *authorURL;

/// 项目主页（可选）。
@property (nonatomic, copy, readonly, nullable) NSString *homepage;

/// SPDX 标识或 `FreeText:<文本>`。
@property (nonatomic, copy, readonly, nullable) NSString *license;

/// 插件使用的宿主 API 主版本，v1 只允许 1。
@property (nonatomic, assign, readonly) NSInteger apiVersion;

/// 宿主版本下限（含），可为空。
@property (nonatomic, copy, readonly, nullable) NSString *minHostVersion;

/// 宿主版本上限（含），可为空。
@property (nonatomic, copy, readonly, nullable) NSString *maxHostVersion;

/// 目标平台（`ios` / `android` / `desktop`），必然含 `ios`（否则解析就失败）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *platforms;

/// 申请的权限 id（已去重、保序）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *permissions;

/// `depends`（已去重）。
@property (nonatomic, copy, readonly) NSArray<A2PluginDependency *> *dependencies;

/// `type: js` 的入口脚本相对路径；`type: json` 时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *entry;

/// 除 manifest.json 外的全部包内文件。
@property (nonatomic, copy, readonly) NSArray<A2PluginFileEntry *> *files;

/// BCP-47 语言标记 → locales 目录下的包内路径。
@property (nonatomic, copy, readonly, nullable) NSDictionary<NSString *, NSString *> *locales;

/// 从 `manifest.json` 的字节解析。失败返回 nil 并给出 `A2PluginError`。
/// @param limits 文件数与路径长度上限（安装器按包体量传入，通常用默认值）
+ (nullable instancetype)manifestWithData:(NSData *)data
                                   limits:(A2PluginLimits)limits
                                    error:(NSError **)error;

/// 从已解析的字典校验并构造（安装器可能先做一次 JSON 解析用于展示）。
+ (nullable instancetype)manifestWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                         limits:(A2PluginLimits)limits
                                          error:(NSError **)error;

/// 是否申请了某个权限。
- (BOOL)hasPermission:(NSString *)permissionId;

/// 「权限集」规范串：`id:risk` 按 id 排序后用 `\n` 连接（registry 的 `permissionSet`）。
- (NSString *)canonicalPermissionSet;

/// 同上，但作用于任意权限 id 数组（用于「旧权限集 vs 新权限集」比较）。
+ (NSString *)canonicalPermissionSetForPermissions:(NSArray<NSString *> *)permissions;

/// 包体量判定（本层不碰磁盘，字节数与条目数由安装器量完后传进来）。
/// 只判「包太大 / 文件太多 / 清单声明得比实际还多」，逐条目的大小在解析时已判过。
- (BOOL)validatePackageEnvelopeWithBytes:(unsigned long long)bytes
                               fileCount:(NSUInteger)fileCount
                                  limits:(A2PluginLimits)limits
                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
