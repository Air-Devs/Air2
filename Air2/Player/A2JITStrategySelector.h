//
//  A2JITStrategySelector.h
//  Air2
//
//  Player —— 【按系统分级】的策略选择与 Provider 排序。
//
//  ★纯逻辑，无平台调用，可单测★：输入 A2JITFacts，输出 A2JITStrategy 与
//  尝试顺序（A2JITProviderKind 列表）。分级依据见 docs/JIT-PROVISIONING.md。
//
//  [JIT-IMPL] 本文件是【分级表的唯一实现】：26→内置手动、27→自动、17.4+→导入、
//  内核环境→内核、17.0–17.3→不可用；并同时给出【失败原因】（decisionForFacts:），
//  供 UI 按原因分流文案（不写万能文案）。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITStateMachine.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ★[JIT-IMPL] 一次分级判定的结果★：策略 + 失败原因（不可变值对象）。
/// 失败原因为 None 表示该策略在当前事实上「有一线可能」；为其它值表示必然不可用
/// （如 17.0–17.3 → SystemTooOld；纯签名 iOS 16- 落内核档但环境不具备 → KernelJITUnavailable）。
@interface A2JITStrategyDecision : NSObject

@property (nonatomic, readonly) A2JITStrategy strategy;
@property (nonatomic, readonly) A2JITFailureReason failureReason;

+ (instancetype)decisionWithStrategy:(A2JITStrategy)strategy
                       failureReason:(A2JITFailureReason)failureReason;

@end

/// 系统分级选择器。
@interface A2JITStrategySelector : NSObject

/// ★[JIT-IMPL] 分级判定（策略 + 失败原因）★（分级表唯一入口）。
+ (A2JITStrategyDecision *)decisionForFacts:(A2JITFacts *)facts;

/// 依本机事实选出策略（★内核级优先于版本号★：越狱 / TrollStore 即使在新系统也走内核级）。
+ (A2JITStrategy)strategyForFacts:(A2JITFacts *)facts;

/// 策略对应的 Provider 尝试顺序（元素为 A2JITProviderKind 的 NSNumber）。
+ (NSArray<NSNumber *> *)orderedProviderKindsForStrategy:(A2JITStrategy)strategy;

/// 策略的展示名（诊断 / 日志用）。
+ (NSString *)displayNameForStrategy:(A2JITStrategy)strategy;

@end

NS_ASSUME_NONNULL_END
