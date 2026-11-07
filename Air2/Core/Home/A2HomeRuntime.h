//
//  A2HomeRuntime.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页的运行时数据源 —— 把卡片上的「引用」解析成真实实体，并给卡片提供内容列表。
//
//  为什么独立成文件：解析要读版本管理器 / 存档目录 / 账号，属于「读世界」；
//  数据模型（A2HomeLayout）必须保持纯函数零 IO 才能放在每次进主页的热路径上。
//
//  引用失效一律**软失败**：解析不出来只标状态 + 给一句原因，绝不动布局、绝不删卡
//  （docs/HOME-DESIGN.md §4.5）。存档路径存的是「相对 gameDir」，
//  所以版本隔离换档位后仍能跟着走；真的拼不到才降级。
//

#import <Foundation/Foundation.h>

#import "A2HomeLayout.h"
#import "A2VersionManager.h"   // A2Version（解析结果要带回调用方）

NS_ASSUME_NONNULL_BEGIN

/// 引用解析状态。
typedef NS_ENUM(NSInteger, A2HomeTargetState) {
    A2HomeTargetStateOK = 0,
    A2HomeTargetStateGameHomeMissing,   ///< 游戏目录已不在授权列表里
    A2HomeTargetStateVersionMissing,    ///< 版本被删 / 改名
    A2HomeTargetStateWorldMissing,      ///< 存档被删
};

@interface A2HomeResolvedTarget : NSObject

@property (nonatomic, assign) A2HomeTargetState state;
/// 解析到的版本（state == OK 时非空）。
@property (nonatomic, strong, nullable) A2Version *version;
/// 显示名：优先真实名字，失效时用存卡时的快照（fallbackLabel）。
@property (nonatomic, copy) NSString *label;
/// 副标题：加载器 / 存档名 / 服务器地址。
@property (nonatomic, copy) NSString *meta;
/// 失效原因（中文，直接给卡片当占位文案）；正常时为空串。
@property (nonatomic, copy) NSString *message;

@property (nonatomic, assign, readonly, getter=isUsable) BOOL usable;

@end

@interface A2HomeRuntime : NSObject

+ (instancetype)shared;

#pragma mark 引用解析

/// 解析一张卡的 target。永不返回 nil（解析失败也返回带 message 的对象）。
- (A2HomeResolvedTarget *)resolveTarget:(A2HomeCardTarget *)target kind:(A2HomeCardKind)kind;

/// (gameHome, versionName) → 已安装版本；找不到返回 nil。
- (nullable A2Version *)versionForTarget:(A2HomeCardTarget *)target;

#pragma mark 内容列表

/// 最近游玩（按 lastPlayed 倒序，没玩过的排后面）。
- (NSArray<A2Version *> *)recentVersionsLimitedTo:(NSInteger)limit;

/// 收藏版本 = 版本页里置顶过的版本（A2Version.isolation.isPinned）。
- (NSArray<A2Version *> *)pinnedVersions;

/// 某版本 gameDir 下的存档（名字 + 相对 gameDir 的路径），按修改时间倒序。
/// 失败返回空数组并填 error（调用方按「空态」渲染，不弹错）。
- (NSArray<NSDictionary<NSString *, id> *> *)worldsForVersion:(A2Version *)version
                                                        error:(NSError **)error;

#pragma mark 问候

/// 按时段问候（"早上好" / "下午好" …）；mode 为文本时返回用户文案。
- (NSString *)greetingTextForMode:(A2HomeGreetingMode)mode customText:(nullable NSString *)text;
/// 当前账号名（未登录返回 nil）。
- (nullable NSString *)currentAccountName;

@end

NS_ASSUME_NONNULL_END
