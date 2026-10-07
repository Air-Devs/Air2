//
//  A2JITStrategySelector.h
//  Air2
//
//  Player —— 【按系统分级】的策略选择与 Provider 排序。
//
//  ★纯逻辑，无平台调用，可单测★：输入 A2JITFacts，输出 A2JITStrategy 与
//  尝试顺序（A2JITProviderKind 列表）。分级依据见 docs/JIT-PROVISIONING.md。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// 系统分级选择器。
@interface A2JITStrategySelector : NSObject

/// 依本机事实选出策略（★内核级优先于版本号★：越狱 / TrollStore 即使在新系统也走内核级）。
+ (A2JITStrategy)strategyForFacts:(A2JITFacts *)facts;

/// 策略对应的 Provider 尝试顺序（元素为 A2JITProviderKind 的 NSNumber）。
+ (NSArray<NSNumber *> *)orderedProviderKindsForStrategy:(A2JITStrategy)strategy;

/// 策略的展示名（诊断 / 日志用）。
+ (NSString *)displayNameForStrategy:(A2JITStrategy)strategy;

@end

NS_ASSUME_NONNULL_END
