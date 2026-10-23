//
//  A2SearchKeywords.h
//  Air2
//
//  中文搜索词 → 英文关键词映射。
//
//  为什么需要：CurseForge / Modrinth 的检索接口只认英文（`query=minimap`），
//  直接在中文输入框里搜「小地图」几乎必然 0 结果。上游 herbrine8403 的
//  `feat(download): CF 中文搜索关键词映射` 就是做这件事，这里按同样思路自研一份。
//
//  设计：
//   · 纯查表替换，不做分词/翻译模型（离线、可预测、无网络依赖）
//   · 中文词在句中出现即替换成对应英文词；ASCII 部分原样保留
//   · 命不中任何词条时原样返回（交给服务端按原文搜）
//   · 只做「常用词」——冷门词加进表即可，不改调用方
//
//  调用点：A2AggregateSearchService.m 的 -searchWithFilter:…（下发检索前翻译）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2SearchKeywords : NSObject

/// 把查询串里的中文词替换成英文关键词。
/// @return 翻译后的查询串；若没有任何命中，返回原串。
+ (NSString *)translateQuery:(NSString *)query;

/// 命中的词条（诊断用：日志里能看出「中文被翻译成了什么」）。
+ (NSArray<NSString *> *)matchedTermsInQuery:(NSString *)query;

/// 是否含中日韩字符（用于决定要不要翻译）。
+ (BOOL)containsCJK:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
