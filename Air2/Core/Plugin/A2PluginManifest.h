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
};

/// 错误码的字符串形式（`E_FORMAT` / `E_FIELD` / …）。
FOUNDATION_EXPORT NSString *A2PluginErrorCodeString(A2PluginError code);

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

#pragma mark - 上限

/// 安装期上限。由安装器传入（它才知道包体与条目数），本层只提供判定入口。
/// 取值就是 `docs/PLUGIN-SYSTEM.md` 3.3「硬性上限」表对外承诺的数字
/// （包 64 MB / 文件数 4096 / 路径 255 字节）—— 文档是唯一口径，代码不另立更严或有别的值。
typedef struct A2PluginLimits {
    unsigned long long maxPackageBytes;
    NSUInteger maxFileCount;
    NSUInteger maxPathLength;
} A2PluginLimits;

/// 默认上限（64 MB / 4096 文件 / 255 字节路径）。
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
