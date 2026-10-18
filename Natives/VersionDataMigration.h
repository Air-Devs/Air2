#pragma once

// ★ [VER-ISOLATE-MIGRATE] ====================================================
// 版本隔离「数据迁移」引擎：把共享实例根里的存量数据，复制进某个版本的隔离
// 目录 <实例根>/versions/<版本 id>/（对齐 PCL-CE 的「实例隔离」语义 —— 隔离后
// gameDir 指针指到 versions/<id>/，旧数据若不搬就"看不见"了）。
//
// 设计约束（照任务口径）：
//   * 默认不自动搬 —— 本引擎只在用户【主动】调用时才动数据；启动期 / 版本次升级
//     一律不调用（不动 general.version_isolation 的既有 no-op 行为）。
//   * 复制式（copy，非 move）—— 源数据默认原样保留；只有 options[@"removeSource"]
//     = @YES（用户明确勾选"清理源"）时才在【校验通过】后删除源，绝不静默删数据。
//   * 可中断、可重跑（幂等）、失败可回滚 —— 目标整体不存在时先整树落到
//     <dstRoot>/.ame-iso-stage/ 再 moveItemAtPath 原子改名（一次 rename，中断不留
//     半成品）；目标已存在（上次中断残留）时逐文件 temp+rename 原子并入。目标已有
//     且与源一致（类型+大小+mtime 相同，用 <源相对路径> 逐项比对）视为"已迁移"直接
//     跳过 ⇒ 重跑零写入、结果一致 ⇒ 幂等。
//   * 不静默覆盖 —— 目标已存在同名但内容不一致时按 conflictPolicy 处理：
//       ameVDMConflictSkip  （默认）跳过并保留两边，计入 conflicts 报告；
//       ameVDMConflictRename 以 .ame-conflict-<时间戳> 改名保留两边。
//   * 源冲突未清空时【拒绝】 removeSource（保留两边，宁可多留也不丢）。
//
// 本文件只依赖 Foundation（不 import utils.h / UIKit），故可在 Mac 上单独编一个
// harness 直接验证「幂等 / 中断重跑 / 同名冲突」三条（见 _VER_ISOLATE_MIGRATE.md ④）。

#import <Foundation/Foundation.h>

/// 冲突策略：跳过（默认，保留两边） / 时间戳改名（保留两边）。
FOUNDATION_EXPORT NSInteger const ameVDMConflictSkip;    // 0
FOUNDATION_EXPORT NSInteger const ameVDMConflictRename;  // 1

/// 默认要迁移的项（以仓里 gameDir 实际消费者为准，见 utils.m 各消费点）：
///   目录：mods / config / saves / resourcepacks / shaderpacks / datapacks /
///         logs / crash-reports
///   文件：options.txt / servers.dat / servers.dat_old
NSArray<NSString *> *ameVDMDefaultItemNames(void);

/// 扫描单路径体量：@{@"files":@(n), @"bytes":@(b), @"dirs":@(d)}。
/// 隐藏项（"." 前缀，含本引擎自己的临时文件/目录）不计入。路径不存在返回全 0。
NSDictionary *ameVDMScanPath(NSString *path);

/// 迁移计划：只列出 srcRoot 下确实存在的项（不存在的不列）。
/// @[@{@"name":, @"src":, @"dst":, @"isDir":, @"files":, @"bytes":,
///     @"identical":, @"conflict":, @"new":}]
NSArray<NSDictionary *> *ameVDMPlan(NSString *srcRoot, NSString *dstRoot,
                                    NSArray<NSString *> *items);

/// 执行迁移（多项）。options 可省：
///   @{@"conflictPolicy": @(ameVDMConflictSkip|ameVDMConflictRename),
///     @"removeSource": @NO}
/// 返回报告：@{@"ok":@BOOL, @"copied":n, @"identical":n, @"conflicts":n,
///             @"renamed":n, @"removed":@BOOL, @"errors":@[..], @"items":@[itemReport..]}
/// itemReport：@{@"name":, @"status":@"done|absent|error", @"copied":, @"identical":,
///               @"conflict":, @"renamed":, @"bytes":, @"errors":@[..]}
NSDictionary *ameVDMExecute(NSString *srcRoot, NSString *dstRoot,
                            NSArray<NSString *> *items, NSDictionary *options);

/// 单项执行（供 UI 逐项调用）。
NSDictionary *ameVDMExecuteItem(NSString *srcRoot, NSString *dstRoot,
                                NSString *item, NSDictionary *options);

/// 清理上次中断残留的临时目录/文件（.ame-iso-stage / *.ame-iso-tmp*）；
/// 返回清除的条目数。幂等、安全（只删本引擎自己的命名空间）。
NSInteger ameVDMCleanupStaleTemps(NSString *dstRoot, NSArray<NSString *> *items);
