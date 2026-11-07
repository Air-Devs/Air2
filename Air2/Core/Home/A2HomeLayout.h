//
//  A2HomeLayout.h
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
//  自定义主页 —— 数据模型 + 规范化 + 装箱（纯 Foundation，不 import UIKit）。
//
//  五段式卡片：kind（是什么卡）/ size（档位）/ target（指向谁）/ options（细项）
//  / position（仅自由布局）。设计参考见 docs/HOME-DESIGN.md §4.1。
//
//  三条不变式（本文件是它们的唯一实现点）：
//    ① 顺序即布局：网格模式不存坐标，排布由「从左上角逐格找空位」算出来
//       ⇒ 永远不会有空洞以外的重叠，也不会出现「多份坐标」；
//    ② 显示位置 ≠ 存储位置：自由布局的显示坐标每次渲染都重算（nearestFree），
//       窄屏被挤开的坐标**不写回**，回宽屏后原坐标自动复原；
//    ③ 档位是「全局池 + 每类型白名单」，窄屏只压列不压行 —— 压列结果同样不落盘。
//
//  规范化（+documentFromJSONObject:readOnly:）是「校验器 + 修复器」二合一：
//  每次进主页跑一遍，坏一张卡丢一张、好卡照留；整篇版本号更高时**只读**、
//  不覆盖、不静默重置（这一条与参考实现相反，见 docs/HOME-DESIGN.md §2.2.7）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 文档版本。整篇门槛：更高版本 ⇒ 只读（不覆盖用户的新版布局）。
FOUNDATION_EXPORT NSInteger const A2HomeSchemaVersion;

/// ---- 布局断点常量（docs/HOME-DESIGN.md §4.3）----
FOUNDATION_EXPORT NSInteger const A2HomeMaxColumns;    // 3
FOUNDATION_EXPORT CGFloat const A2HomeCardMinWidth;    // 300
FOUNDATION_EXPORT CGFloat const A2HomeCardRowHeight;   // 168
FOUNDATION_EXPORT CGFloat const A2HomeGridGap;         // 12  ← 与 A2CardSpacing 同值（Core 不 import UIKit，故在此复述）
FOUNDATION_EXPORT NSInteger const A2HomeMaxPositionRow; // 512

#pragma mark - 枚举

/// 卡片类型。裸值 token（JSON 用）见 A2HomeCardKindToken()。
typedef NS_ENUM(NSInteger, A2HomeCardKind) {
    A2HomeCardKindGreeting = 0,      ///< 问候（单例语义）
    A2HomeCardKindRecent,            ///< 最近游玩
    A2HomeCardKindCalendar,          ///< 日历（单例语义）
    A2HomeCardKindPinnedVersions,    ///< 收藏版本（版本自身的置顶标记）
    A2HomeCardKindPinnedWorlds,      ///< 收藏存档（当前版本尚无钉选存储，见实现说明）
    A2HomeCardKindPinnedServers,     ///< 收藏服务器（同上）
    A2HomeCardKindShortcutVersion,   ///< 单项快捷：某个版本
    A2HomeCardKindShortcutWorld,     ///< 单项快捷：某个存档
    A2HomeCardKindShortcutServer,    ///< 单项快捷：某台服务器
    A2HomeCardKindShortcutCustom,    ///< 自定义入口：图标 + 标题 + 跳转目标（内置页 / 网址）
};

/// 尺寸档位（全局池，共 6 档）。每类卡片只能取白名单里的几档。
typedef NS_ENUM(NSInteger, A2HomeCardSize) {
    A2HomeCardSizeOneByOne = 0,
    A2HomeCardSizeTwoByOne,
    A2HomeCardSizeOneByTwo,
    A2HomeCardSizeTwoByTwo,
    A2HomeCardSizeThreeByOne,
    A2HomeCardSizeThreeByTwo,
};

/// 卡片区的排布模式。
typedef NS_ENUM(NSInteger, A2HomeLayoutMode) {
    A2HomeLayoutModeGrid = 0,   ///< 流式装箱，不存坐标
    A2HomeLayoutModeFree,       ///< 自由坐标，存 position
};

/// 跨列/跨行。
typedef struct {
    NSInteger columns;
    NSInteger rows;
} A2HomeSpan;

/// 问候卡的文案模式。
typedef NS_ENUM(NSInteger, A2HomeGreetingMode) {
    A2HomeGreetingModeAuto = 0,  ///< 按时段自动问候
    A2HomeGreetingModeText,      ///< 只用用户自己的文案
};

#pragma mark - 自定义卡片的跳转目标

/// 跳转目标类型。内置页走主页的 `-fix2PushTab:` 统一入口（同一导航栈 push），
/// 网址交给系统打开 —— 两条路都不许发通知去替换主页内容（串台铁律）。
typedef NS_ENUM(NSInteger, A2HomeJumpKind) {
    A2HomeJumpKindPage = 0,   ///< 内置页（枚举，见 A2HomeJumpPage）
    A2HomeJumpKindURL,        ///< http / https 网址
};

/// 内置页枚举。**token 是契约**（会进 JSON 落到用户磁盘）：可以加新值、可以改显示名，
/// 但不能改已有 token —— 改了已存的卡片就跳不动了。
typedef NS_ENUM(NSInteger, A2HomeJumpPage) {
    A2HomeJumpPageUnknown = -1,   ///< 未知 / 已被本版移除：软失败（卡片留着，跳转失效）
    A2HomeJumpPageVersions = 0,
    A2HomeJumpPageVersionSettings,
    A2HomeJumpPageDownload,
    A2HomeJumpPageAccount,
    A2HomeJumpPageMultiplayer,
    A2HomeJumpPageFiles,
    A2HomeJumpPageSettings,
};

#pragma mark - 纯函数（token / 白名单 / 断点）

/// kind ↔ JSON token（"greeting" / "shortcutWorld" …）。未知 token 返回 NO。
FOUNDATION_EXPORT NSString *A2HomeCardKindToken(A2HomeCardKind kind);
FOUNDATION_EXPORT BOOL A2HomeCardKindFromToken(NSString *token, A2HomeCardKind *out);

/// size ↔ JSON token（"1x1" "3x2" …）。
FOUNDATION_EXPORT NSString *A2HomeCardSizeToken(A2HomeCardSize size);
FOUNDATION_EXPORT BOOL A2HomeCardSizeFromToken(NSString *token, A2HomeCardSize *out);

/// 档位 → 跨度（列, 行）。
FOUNDATION_EXPORT A2HomeSpan A2HomeSpanForSize(A2HomeCardSize size);

/// 该类型的允许档位（白名单，升序）。默认档 = 白名单里的 A2HomeDefaultSizeForKind。
FOUNDATION_EXPORT NSArray<NSNumber *> *A2HomeSizesForKind(A2HomeCardKind kind);
FOUNDATION_EXPORT A2HomeCardSize A2HomeDefaultSizeForKind(A2HomeCardKind kind);

/// 该类型是否必须带 target（kind 段判定，规范化与 picker 共用）。
FOUNDATION_EXPORT BOOL A2HomeKindRequiresTarget(A2HomeCardKind kind);
/// 该类型是否「单例语义」（同一种只该有一张：问候 / 日历）。
FOUNDATION_EXPORT BOOL A2HomeKindIsSingleton(A2HomeCardKind kind);
/// 当前版本是否已接通该类型的真实数据源（未接通的不出现在 picker 里）。
FOUNDATION_EXPORT BOOL A2HomeKindIsAvailable(A2HomeCardKind kind);
FOUNDATION_EXPORT NSString *A2HomeKindDisplayName(A2HomeCardKind kind);
FOUNDATION_EXPORT NSString *A2HomeKindSummary(A2HomeCardKind kind);
/// 系统图标名（SF Symbol），卡片与 picker 共用。
FOUNDATION_EXPORT NSString *A2HomeKindSymbolName(A2HomeCardKind kind);

/// 列数公式：clamp(floor((width + gap) / (minWidth + gap)), 1, maxColumns)。
FOUNDATION_EXPORT NSInteger A2HomeColumnCountForWidth(CGFloat width);
/// 窄屏压缩：列压到 columns，**行不动**（档位值本身不变）。
FOUNDATION_EXPORT A2HomeSpan A2HomeSpanCompressedToColumns(A2HomeSpan span, NSInteger columns);

/// 服务器地址归一化（小写、去空白、去默认端口 25565）。
FOUNDATION_EXPORT NSString *A2HomeNormalizedServerAddress(NSString *address);

#pragma mark - 自定义卡片的跳转目标（token / 选择表）

/// 可选的内置页（升序，全部可用；Unknown 不在表里）。
FOUNDATION_EXPORT NSArray<NSNumber *> *A2HomeJumpPagesAll(void);
FOUNDATION_EXPORT NSString *A2HomeJumpPageToken(A2HomeJumpPage page);
FOUNDATION_EXPORT A2HomeJumpPage A2HomeJumpPageFromToken(NSString *token);
FOUNDATION_EXPORT NSString *A2HomeJumpPageDisplayName(A2HomeJumpPage page);
FOUNDATION_EXPORT NSString *A2HomeJumpPageSymbolName(A2HomeJumpPage page);

FOUNDATION_EXPORT NSString *A2HomeJumpKindToken(A2HomeJumpKind kind);
FOUNDATION_EXPORT A2HomeJumpKind A2HomeJumpKindFromToken(NSString *token);

/// 自定义卡片可选的内置图标（SF Symbol 名）。只收本版确实存在的符号；
/// 白名单之外的值在规范化时回默认 —— 否则用户手改 JSON 就能写进任意字符串。
FOUNDATION_EXPORT NSArray<NSString *> *A2HomeCustomSymbolChoices(void);
FOUNDATION_EXPORT NSString *A2HomeCustomDefaultSymbol(void);

/// 只接受 http / https 且有 host 的网址（其它 scheme 一律不认，避免自定义卡片变成任意 URL 调用口）。
FOUNDATION_EXPORT NSURL *_Nullable A2HomeWebURLFromString(NSString *_Nullable string);

/// 标题裁剪上限（字），自定义卡片标题超出即截断。
FOUNDATION_EXPORT NSInteger const A2HomeCustomTitleMaxLength;

#pragma mark - 卡片引用目标

/// 卡片指向的实体。所有引用都带 fallbackLabel（存卡时的名字快照）——
/// 没有兜底名的引用不允许存在，这是「实体没了卡片还能显示它本来是什么」的前提。
///
/// 版本用 (gameHome, versionName) 二元组标识：版本名在不同游戏根目录下会重名。
/// 存档存**相对 gameDir 的路径**（不是绝对路径）：版本隔离档位会改变 gameDir，
/// 绝对路径在切档位后就失效了。
@interface A2HomeCardTarget : NSObject <NSCopying>

@property (nonatomic, copy) NSString *gameHome;
@property (nonatomic, copy) NSString *versionName;
/// 存档相对路径（相对 gameDir），非存档卡为 nil。
@property (nonatomic, copy, nullable) NSString *worldPath;
/// 服务器地址（已归一化），非服务器卡为 nil。
@property (nonatomic, copy, nullable) NSString *address;
/// 存卡时的显示名快照。
@property (nonatomic, copy) NSString *fallbackLabel;

+ (instancetype)targetWithGameHome:(NSString *)gameHome
                       versionName:(NSString *)versionName
                         worldPath:(nullable NSString *)worldPath
                           address:(nullable NSString *)address
                     fallbackLabel:(NSString *)fallbackLabel;

/// 规范化：gameHome / versionName / fallbackLabel 任一为空白 ⇒ nil（引用作废）。
+ (nullable instancetype)targetFromJSONObject:(nullable id)json;

- (NSDictionary *)JSONObject;

@end

#pragma mark - 卡片选项

/// 按 kind 解释的散装参数。未识别的键原样留在 unknownOptions 里，
/// 写回时合并 —— 这样「新版本加了参数、用户降级再升级」不会丢字段。
@interface A2HomeCardOptions : NSObject <NSCopying>

@property (nonatomic, assign) A2HomeGreetingMode greetingMode;
@property (nonatomic, copy) NSString *greetingText;     // ≤120 字
@property (nonatomic, assign) NSInteger greetingFontSize; // 16…32
@property (nonatomic, assign) NSInteger recentLimit;      // 2 / 4 / 6 / 8
@property (nonatomic, strong, nullable) NSDictionary *unknownOptions;

/// ---- 自定义卡片（kind == A2HomeCardKindShortcutCustom）----
@property (nonatomic, copy) NSString *customTitle;    ///< ≤ A2HomeCustomTitleMaxLength 字；空则用类型名
@property (nonatomic, copy) NSString *customSymbol;   ///< 图标（A2HomeCustomSymbolChoices 内）
@property (nonatomic, assign) A2HomeJumpKind jumpKind;
@property (nonatomic, assign) A2HomeJumpPage jumpPage;      ///< jumpKind == Page 时有效
@property (nonatomic, copy) NSString *jumpURLString;        ///< jumpKind == URL 时有效

/// 跳转是否可用。不可用时 outReason 给一句中文 —— 卡片**不删**，由渲染层软失败提示。
- (BOOL)isJumpUsableWithReason:(NSString *_Nullable *_Nullable)outReason;

/// 按 kind 规范化（枚举回默认、字符串裁剪、数值钳制）。
+ (instancetype)optionsFromJSONObject:(nullable id)json kind:(A2HomeCardKind)kind;
- (NSDictionary *)JSONObjectForKind:(A2HomeCardKind)kind;

@end

#pragma mark - 卡片

/// 一张卡。position 只有自由布局才有；网格模式下 hasPosition 恒为 NO。
@interface A2HomeCard : NSObject <NSCopying>

@property (nonatomic, copy) NSString *cardID;   // UUID 字符串，重复即重发
@property (nonatomic, assign) A2HomeCardKind kind;
@property (nonatomic, assign) A2HomeCardSize size;
@property (nonatomic, strong, nullable) A2HomeCardTarget *target;
@property (nonatomic, strong) A2HomeCardOptions *options;
@property (nonatomic, assign) BOOL hasPosition;
@property (nonatomic, assign) NSInteger column;
@property (nonatomic, assign) NSInteger row;

+ (instancetype)cardWithKind:(A2HomeCardKind)kind;
/// 规范化单卡。不合格返回 nil（丢卡保篇），并可通过 reason 拿到原因做日志。
+ (nullable instancetype)cardFromJSONObject:(nullable id)json reason:(NSString *_Nullable *_Nullable)reason;
- (NSDictionary *)JSONObjectIncludingPosition:(BOOL)includePosition;

/// 该卡片当前档位的跨度（未压缩）。列数已知时请用 A2HomeSpanCompressedToColumns 再压。
- (A2HomeSpan)span;

@end

#pragma mark - 布局方案

/// 一套布局方案（profiles[] 的一项）。
@interface A2HomeProfile : NSObject <NSCopying>

@property (nonatomic, copy) NSString *profileID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) A2HomeLayoutMode layout;
@property (nonatomic, strong) NSMutableArray<A2HomeCard *> *cards;

/// 默认方案：问候 3x1 / 最近游玩 2x2 / 收藏版本 2x1 / 日历 1x2 …
/// 顺序即布局，所以这里的书写顺序就是默认主页的视觉顺序。
+ (instancetype)defaultProfileWithID:(NSString *)profileID name:(NSString *)name;

- (nullable A2HomeCard *)cardWithID:(NSString *)cardID;
- (BOOL)containsKind:(A2HomeCardKind)kind;

/// 把本方案的内容重置为「默认那套卡片」：方案 id 与名字保留（其它方案完全不受影响）。
/// 多方案下的「恢复默认」只该动当前方案 —— 整篇重置会把用户另外几套方案一起抹掉。
- (void)resetContentToDefaultCards;

- (NSDictionary *)JSONObject;

@end

#pragma mark - 文档

/// 整篇：{ schema, activeProfile, profiles[] }。只做整篇校验，不做逐字段迁移。
@interface A2HomeDocument : NSObject

@property (nonatomic, assign) NSInteger schema;
@property (nonatomic, copy) NSString *activeProfileID;
@property (nonatomic, strong) NSMutableArray<A2HomeProfile *> *profiles;

/// 出厂默认文档（一个「默认」方案）。
+ (instancetype)defaultDocument;

/// **唯一入口**：JSON → 文档。
/// @param outReadOnly 文件版本高于本版时为 YES —— 调用方必须据此禁写、只读渲染。
/// 返回 nil 表示结构无法使用（非字典 / profiles 不是数组 / 解析异常）。
+ (nullable instancetype)documentFromJSONObject:(nullable id)json readOnly:(BOOL *)outReadOnly;

/// 当前生效方案（activeProfileID 找不到时取第一个；profiles 为空时造默认）。
- (A2HomeProfile *)activeProfile;

/// 输出规范化 JSON（写盘 / 导出共用）。
- (NSDictionary *)JSONObject;

/// 方案增删（多方案）。
- (A2HomeProfile *)addProfileNamed:(NSString *)name;
/// 默认方案不可删；删当前方案后 activeProfileID 落到第一个。
- (BOOL)removeProfileWithID:(NSString *)profileID;
- (nullable A2HomeProfile *)profileWithID:(NSString *)profileID;

@end

#pragma mark - 落位结果

/// 一张卡的落位（0 基列/行）。columnSpan 是**压缩后**的列跨度（窄屏时可能小于档位）。
@interface A2HomePlacement : NSObject

@property (nonatomic, copy) NSString *cardID;
@property (nonatomic, assign) NSInteger column;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger columnSpan;
@property (nonatomic, assign) NSInteger rowSpan;

@end

/// 装箱与吸附（纯函数，全部可单测，零 IO）。
@interface A2HomePacker : NSObject

/// 网格模式：从左上角逐格找空位（流式装箱）。返回顺序与入参一致。
/// ⇒ 不存坐标、不留洞以外的重叠。
+ (NSArray<A2HomePlacement *> *)gridPlacementsForCards:(NSArray<A2HomeCard *> *)cards
                                               columns:(NSInteger)columns;

/// 网格拖拽排序（纯函数）：把 movingCardID 的落点 (targetColumn, targetRow) 换成新顺序。
///   · 落点压在某张卡上 ⇒ 移到那张卡原来的位置（互换视觉位置，不推动其它卡的相对次序）；
///   · 落点在空格       ⇒ 移到「行优先严格排在落点之前」的张数处；
///   · 落点就是自己     ⇒ 原序返回（避免无意义的写盘）。
/// 入参数组与卡片对象都不被修改；返回的是新数组（元素是原对象）。
/// 排序逻辑放在 Core 而不是视图里，是因为它是**行为**，必须能被单测钉住。
+ (NSArray<A2HomeCard *> *)cardsByMovingCardID:(NSString *)movingCardID
                                            in:(NSArray<A2HomeCard *> *)cards
                                    placements:(NSArray<A2HomePlacement *> *)placements
                                      toColumn:(NSInteger)targetColumn
                                           row:(NSInteger)targetRow;

/// 自由布局的**显示**落位：按存储坐标吸附到最近空格。
/// 结果只用于显示，绝不写回存储坐标（显示位置 ≠ 存储位置）。
+ (NSArray<A2HomePlacement *> *)freeDisplayPlacementsForCards:(NSArray<A2HomeCard *> *)cards
                                                      columns:(NSInteger)columns;

/// 单个期望坐标的吸附：先试 (column,row)，被占则按曼哈顿距离由近到远扫。
/// @param occupied 已占格（行优先索引 row*columns+column），只读。
+ (void)nearestFreeColumn:(NSInteger *)column
                      row:(NSInteger *)row
                  forSpan:(A2HomeSpan)span
                  columns:(NSInteger)columns
                 occupied:(NSSet<NSNumber *> *)occupied;

/// 网格 → 自由布局的坐标初始化（切到自由布局时调用一次，随后落盘）。
+ (void)seedFreePositionsForCards:(NSArray<A2HomeCard *> *)cards columns:(NSInteger)columns;

/// 已占格索引集合（行优先 row*columns+column）。
/// 拖拽吸附时用它排除「自己」，这样自己原来的格子可以被自己占回来。
+ (NSSet<NSNumber *> *)occupiedIndexesForPlacements:(NSArray<A2HomePlacement *> *)placements
                                        excludingID:(nullable NSString *)cardID
                                            columns:(NSInteger)columns;

@end

NS_ASSUME_NONNULL_END
