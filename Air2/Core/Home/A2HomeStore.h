//
//  A2HomeStore.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页布局的落盘层 —— Documents/home-layout.json（独立文件，不进 config.json）。
//
//  为什么独立文件（不是塞进 A2Settings 的 config.json，见 docs/HOME-DESIGN.md §4.2）：
//    ① 设置注册表是「一 key 一标量 + 一个默认值」的模型，嵌套文档塞进去会破坏它；
//    ② 写盘频率不同：设置页低频显式提交，主页编辑每次拖动都写；
//    ③ 失败隔离：布局文件坏了不该连累主题 / 账号等设置。
//  用到的两个标量（主页模式、当前方案）里，模式进设置，方案指针在文档自己身上。
//
//  读写协议（★比参考实现严谨的地方★）：
//    写：encode → 自己的 normalize 往返校验 → 写 .tmp → fsync → 轮转 .bak → rename
//    读：parse + normalize
//          ├ 成功            → 用
//          ├ 失败 → 试 .bak  → 成功则用，并提示「已从备份恢复」
//          ├ 更高 schema     → ★只读★：备份为 .readonly.json，禁写、不覆盖
//          └ 全失败          → 默认方案（★不立即写盘★，等用户第一次真正编辑）
//
//  高频写：所有改动先落内存 + 250ms 合并窗口，`-flush` 立即写（进后台/离开页面时调）。
//

#import <Foundation/Foundation.h>

#import "A2HomeLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// 主页模式（经典 / 自定义网格）。存 Documents/config.json（A2Settings 托管），
/// 默认关闭 ⇒ 老用户升级后看到的还是原来的主页。
FOUNDATION_EXPORT NSString *const A2HomeSettingsKeyHomeMode;

/// ★主页网格（实验）开关★：键 `home.ui.gridEnabled`，默认 **NO**。
/// 与 `homeMode` 是两件事：`homeMode` 是「经典/网格」的模式标量（Core 语义），
/// 这里这一条只控制**主页内容区**是否改用 `A2HomeGridView` 渲染（UI 实验开关）。
/// 默认关 ⇒ 主页跑的还是原来那套三区布局，一个像素都不变。
FOUNDATION_EXPORT NSString *const A2HomeSettingsKeyGridEnabled;

/// 主页模式取值。
typedef NS_ENUM(NSInteger, A2HomeMode) {
    A2HomeModeClassic = 0,
    A2HomeModeGrid,
};

/// 导入结果。
typedef NS_ENUM(NSInteger, A2HomeImportOutcome) {
    A2HomeImportOutcomeOK = 0,             ///< 已合并进当前文档并落盘
    A2HomeImportOutcomeHigherSchema,       ///< 文件由更新版本创建：只读提示，不覆盖
    A2HomeImportOutcomeMalformed,          ///< 结构损坏 / 不是 JSON：明确报错，不动现有配置
    A2HomeImportOutcomeEmpty,              ///< 文件里没有任何可用方案
};

@interface A2HomeStore : NSObject

+ (instancetype)shared;

/// Documents/home-layout.json
@property (nonatomic, copy, readonly) NSString *filePath;

/// 只读模式（文件版本高于本版）。只读时 `-saveDocument:error:` 一律拒绝写入。
@property (nonatomic, assign, readonly) BOOL isReadOnly;
/// 上次读取时主文件坏了、实际用的是 .bak。
@property (nonatomic, assign, readonly, getter=isLoadedFromBackup) BOOL loadedFromBackup;
/// 上次读取时主文件存在但完全不可用（已保留为 .corrupt.json，且未写盘覆盖）。
@property (nonatomic, assign, readonly) BOOL loadedFromCorrupt;

#pragma mark 主页模式（标量，走设置）

- (A2HomeMode)homeMode;
- (void)setHomeMode:(A2HomeMode)mode;

/// ★主页网格（实验）★：`home.ui.gridEnabled`，默认 NO。
/// 读写都只走这条属性（唯一落点），键的字符串只在本实现里出现一次。
@property (nonatomic, assign) BOOL gridEnabled;

#pragma mark 读

/// 读文档。**永不返回 nil**：文件缺失/损坏时给出厂默认（且不写盘）。
- (A2HomeDocument *)loadDocument;

#pragma mark 写

/// 整篇写。只读模式直接失败。写前跑一遍自己的 normalize 做往返校验。
- (BOOL)saveDocument:(A2HomeDocument *)document error:(NSError **)error;

/// 内存态已改、还没落盘的改动立即写（进后台 / 退出主页时调）。
- (void)flush;

/// 变更后调用：250ms 合并窗口内只写最后一次（拖动过程中只改内存）。
- (void)scheduleSaveDocument:(A2HomeDocument *)document;

#pragma mark 恢复默认

/// 把某个方案的内容重置为默认卡片（写盘）。只读模式返回 NO。
/// **只动这一个方案**：整篇重置会把用户另外几套方案一起抹掉（多方案下那是数据丢失）。
- (BOOL)restoreDefaultContentOfProfile:(NSString *)profileID
                            inDocument:(A2HomeDocument *)document
                                 error:(NSError **)error;

#pragma mark 导出 / 导入

/// 导出整篇（方案列表 + 每张卡 + 版本号 + 导出时间）到临时目录，返回可分享的 URL。
/// 调用方用系统分享面板把它交给「文件」App。失败返回 nil 并填 error。
- (nullable NSURL *)exportDocument:(A2HomeDocument *)document error:(NSError **)error;

/// 导入一个 .json 文件。
/// 规则（对应用户口径）：
///   · 版本号高于本版 ⇒ A2HomeImportOutcomeHigherSchema，**只读提示、不覆盖**；
///   · 结构损坏 / 非法 JSON ⇒ A2HomeImportOutcomeMalformed，现有配置一动不动；
///   · 通过校验 ⇒ **先备份当前配置为 .bak**，再把导入的方案合并追加（不覆盖同名方案）。
/// @param outMessage 面向用户的说明（成败都给）。
- (A2HomeImportOutcome)importFromURL:(NSURL *)url
                             message:(NSString *_Nullable *_Nullable)outMessage
                           document:(A2HomeDocument *_Nullable *_Nullable)outDocument;

/// 当前配置备份到 home-layout.bak.json（导入前 / 恢复默认前显式调）。
- (BOOL)backupCurrentLayoutWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
