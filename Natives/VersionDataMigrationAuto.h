#pragma once

// ★ [VI-MIGRATE-AUTO] ========================================================
// 版本隔离「自动识别迁移」引擎：用户只指【一个文件夹】，引擎自动扫描其中每一项，
// 按【MC 版本 + 加载器】推断归属，分组后交给用户确认（勾选搬哪些；目标由引擎决定，无改归属）。
//
// 与既有 VersionDataMigration（复制式/幂等/原子/不静默覆盖/可中断重跑）的关系：
//   * 本文件只负责【识别 + 分组 + 匹配目标实例】，绝不搬动任何文件；
//   * 真正落盘仍走 VersionDataMigration 的 ameVDMExecuteItem（同一套语义），
//     由 ameVIAExecute 逐单元调用，保证「确认后走已有引擎执行」。
//
// 识别依据（逐一可解释，写进每个单元的 @"reason"）：
//   * mods/*.jar
//       - Fabric/Quilt：读 jar 内 fabric.mod.json → id + depends.minecraft（版本区间）；
//         有 quilt.mod.json 则判 quilt。
//       - Forge/NeoForge：读 META-INF/mods.toml 或 META-INF/neoforge.mods.toml →
//         modLoader / loaderVersion + [[dependencies.<modid>]] 里 modId="minecraft"
//         的 versionRange（**load不是** loaderVersion —— 那是 FML 构建号，不是 MC 版本）。
//       - 无可用元数据 ⇒ 退回文件名尾部版本号（"jei-1.20.1-15.x.jar" ⇒ 1.20.1）。
//       - 全都判不出 ⇒ 记「未识别」（不猜）。
//   * resourcepacks / datapacks（目录或 zip）：读 pack.mcmeta 的 pack.pack_format，
//     查 pack_format→MC 版本表；查不到退回文件名版本号。
//   * shaderpacks：无标准版本字段（Iris/OptiFine 光影不声明 MC 版本）⇒ 退回文件名，
//     判不出记「未识别」。
//   * saves/<世界>/level.dat：解 gzip+NBT，读 Data.DataVersion（表→MC 版本）或
//     Data.Version.Name（"1.20.1"）。
//   * config/*.toml|json：自身不带版本 ⇒ 默认「未识别」；若其文件名主干能唯一对上
//     某个已判定的 mod id，则「跟随同名 mod 的归属」（有依据才做）。
//   * 根散文件（options.txt / servers.dat…）：不带版本 ⇒ 未识别（但类别明确）。
//
// ★ [VI-ORIGIN] 【来源】维度（与上面的「类型 category」正交，判定优先级自高到低）：
//   ① 加载器自带（loader）：命中【加载器/原版基线表】——
//        顶层目录 logs/ crash-reports/ .fabric/ .mixin.out/（其内部项一并视为基线）、
//        加载器自身配置 config/fabric/*、
//        原版/启动器自生成根文件 options.txt / optionsof.txt / servers.dat(_old) /
//        usercache.json / usernamecache.json / launcher_profiles.json /
//        launcher_accounts.json / banned-*.json / ops.json / whitelist.json /
//        eula.txt / debug.log / realms_persistence.json / debug-profile.json。
//   ② mod 生成（mod）：名称（大小写与 - _ . 归一后）全等或前缀命中【某个已装 mod 的元数据 id】
//        （id 取自 mods/*.jar 的 fabric.mod.json / quilt.mod.json / mods.toml / neoforge.mods.toml），
//        典型如 config/<modid>.toml、config/<modid>-client.toml、config/<modid>/…。
//   ③ 玩家添加（player）：落在 mods/ saves/ resourcepacks/ shaderpacks/ datapacks/（玩家自己放入/创建）。
//   ④ 未识别（unknown）：以上都不命中 ⇒ 不猜（且默认不勾选、不参与迁移）。
//   备注：来源只在【自动识别页】用于呈现 + 筛选 + 默认勾选策略；不改变任何落盘路径。
//
// 目标实例来源：扫启动器实例根的 versions/*，从版本 id 与 <id>.json 推 (版本, 加载器)，
// 建「(版本, 加载器) → <实例根>/versions/<id>」映射表。匹配不到记「未匹配」。
//
// 硬约束：默认【不扫不搬】—— 只有用户主动打开本页并点确认才动；本文件所有函数
// 均为纯函数（只读磁盘 + 返回结构），不做任何写操作。

#import <Foundation/Foundation.h>

// 类别
FOUNDATION_EXPORT NSString *const ameVIACatMod;           // @"mods"
FOUNDATION_EXPORT NSString *const ameVIACatResourcePack;  // @"resourcepacks"
FOUNDATION_EXPORT NSString *const ameVIACatShaderPack;    // @"shaderpacks"
FOUNDATION_EXPORT NSString *const ameVIACatDataPack;      // @"datapacks"
FOUNDATION_EXPORT NSString *const ameVIACatWorld;         // @"saves"
FOUNDATION_EXPORT NSString *const ameVIACatConfig;        // @"config"
FOUNDATION_EXPORT NSString *const ameVIACatRoot;          // @"." 根散文件
FOUNDATION_EXPORT NSString *const ameVIACatOther;         // 其它

// 加载器
FOUNDATION_EXPORT NSString *const ameVIALoaderFabric;
FOUNDATION_EXPORT NSString *const ameVIALoaderQuilt;
FOUNDATION_EXPORT NSString *const ameVIALoaderForge;
FOUNDATION_EXPORT NSString *const ameVIALoaderNeoForge;
FOUNDATION_EXPORT NSString *const ameVIALoaderVanilla;

// ★ [VI-ORIGIN] 来源（某项「从哪来」），与类型 category 正交：
FOUNDATION_EXPORT NSString *const ameVIAOriginLoader;   // @"loader"  加载器/原版自带（基线产物）
FOUNDATION_EXPORT NSString *const ameVIAOriginPlayer;   // @"player"  玩家自己添加/创建
FOUNDATION_EXPORT NSString *const ameVIAOriginMod;      // @"mod"     mod 运行时自己生成
FOUNDATION_EXPORT NSString *const ameVIAOriginUnknown;  // @"unknown" 判不出（不猜）

/// 版本/区间匹配：concrete 是否落在 range 描述内。
/// 支持：nil/@"*" 全匹配；精确 @"1.20.1"；区间 "[1.20.1,1.20.2)" / "[1.20.1,)" /
/// "(,1.21]"；Maven 风格 ">=1.21 <1.22"；波浪号 "~1.21"（= >=1.21 <1.22）；
/// Fabric 风格 ">=1.21- <1.22"（尾部 "-" 忽略）。无法解析时保守返回 NO。
BOOL ameVIAVersionInRange(NSString *concrete, NSString *range);

/// 从任意字符串里抽出第一个 MC 版本号（"1.20.1" / "26.3" / "1.20" / 快照 "24w14a"）。
/// 抽不到返回 nil。
NSString *ameVIAExtractMCVersion(NSString *s);

/// 从版本 id / 文件名里判加载器（fabric/quilt/forge/neoforge/vanilla）。
/// 判不出返回 nil。
NSString *ameVIAExtractLoader(NSString *s);

/// 分类单个「迁移单元」（文件或目录），只读、不搬。
/// @{ @"unit": relPath, @"abs": absPath, @"isDir": @BOOL, @"category": NSString,
///    @"files": @(n), @"bytes": @(b),
///    @"mcVersion": NSString|NSNull, @"mcRange": NSString|NSNull,
///    @"loader": NSString|NSNull, @"reason": NSString }
NSDictionary *ameVIAClassifyUnit(NSString *srcRoot, NSString *relPath);

/// 扫描一个文件夹：按已知顶层类别枚举「迁移单元」。
/// @{ @"units": @[unitRec...], @"scanned": @(n) }
NSDictionary *ameVIAScanFolder(NSString *srcRoot);

/// ★ [VI-ORIGIN] 给已分类单元补「来源」（origin / originReason，可能还有 originModId）。
/// 仅把 classify 判为「未识别」的项，用【已装 mod 的元数据 id】匹配其名称；
/// 命中即升级为「mod 生成」，否则维持「未识别」。加载器自带 / 玩家添加 不会被覆盖。
/// 只读、不改任何路径；ameVIAScanFolder 已内部调用（此处导出便于 harness 单独验证）。
NSArray<NSDictionary *> *ameVIAAnnotateOrigins(NSArray<NSDictionary *> *units);

/// 扫启动器实例根 versions/*，建「(版本, 加载器) → 实例目录」映射。
/// @[ @{ @"version": NSString, @"loader": NSString, @"dir": NSString, @"reason": NSString } ]
NSArray<NSDictionary *> *ameVIAEnumerateTargets(NSString *instanceRoot);

/// 把扫描出的单元分组（组键 = MC 版本 + 加载器 + 类别），并匹配目标实例。
/// @[ @{ @"mcVersion": NSString|NSNull, @"mcRange":, @"loader": NSString|NSNull,
///       @"category": NSString, @"units": @[unitRec..], @"files": @(n), @"bytes": @(b),
///       @"reason": NSString, @"target": @{...}|NSNull, @"targetDir": NSString|NSNull,
///       @"match": @"exact|range|none|unrecognized" } ]
NSArray<NSDictionary *> *ameVIAGroupUnits(NSArray<NSDictionary *> *units,
                                          NSArray<NSDictionary *> *targets);

/// 执行：units 为已确认的单元（每个须带 @"unit" 相对路径 + @"dstRoot" 目标实例目录）。
/// options: @{ @"conflictPolicy": @(ameVDMConflictSkip|Rename), @"removeSource": @(BOOL) }
/// 逐单元走既有 ameVDMExecuteItem（复制式/幂等/原子/不静默覆盖），聚合报告。
/// 返回：@{ @"ok":@BOOL, @"copied":n, @"identical":n, @"conflicts":n, @"renamed":n,
///          @"removed":@BOOL, @"errors":@[..], @"items":@[itemReport..] }
NSDictionary *ameVIAExecute(NSString *srcRoot, NSArray<NSDictionary *> *units,
                            NSDictionary *options);

// ===== 供 harness 直接验证的底层原语 =====

/// 读 zip/jar 内某个条目的原始字节（自带 inflate，无需 zlib）。找不到返回 nil。
NSData *ameVIAReadZipEntry(NSString *zipPath, NSString *entryName);

/// 解析 pack.mcmeta 里的 pack_format（－1 表示无/不可解析）。支持目录或 zip。
NSInteger ameVIAPackFormatAtPath(NSString *path);

/// 读 level.dat 的 (DataVersion, Version.Name)；返回 @{@"dataVersion":@(n)|NSNull,
/// @"versionName":NSString|NSNull}；失败返回 nil。
NSDictionary *ameVIAReadLevelDat(NSString *levelDatPath);
