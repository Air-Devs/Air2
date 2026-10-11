//
//  A2JITStrings.h
//  Air2
//
//  Player —— JIT 面板的【四语】文案表（zh-Hans / zh-Hant / en / ja）。
//
//  ★为什么放在这里（而不是 .lproj）★：
//    · 本仓目前【没有任何 i18n 基建】（无 .lproj、无 Localizable.strings，
//      UI 文案一律硬编码中文）；JIT 面板是本单第一个需要四语的地方。
//    · .lproj 需要改资源打包（scripts/gen_xcodeproj.py 的 collect_resources 与
//      knownRegions），本单不动打包链路，避免把「文案」和「构建」两件事一起赌。
//    · 放在 Player 的纯逻辑件里 ⇒ ★可单测★：单测能断言「每个 key 在四语里都存在
//      且非空」「七个 verdict 的原因/动作 key 互不相同」，把「四语齐全」变成机器判据。
//    · ★便于后续迁移★：key 是稳定的（jit.verdict.* / jit.row.* / jit.toast.*），
//      将来接入 .lproj 时把本表灌进 Localizable.strings 即可，调用点不用改。
//
//  ★纯逻辑、无 UIKit、无网络★。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 支持的界面语言（★顺序即 allLanguageCodes 的顺序★）。
typedef NS_ENUM(NSInteger, A2JITLanguage) {
    A2JITLanguageZhHans = 0,  ///< 简体中文
    A2JITLanguageZhHant = 1,  ///< 繁體中文
    A2JITLanguageEnglish = 2, ///< English
    A2JITLanguageJapanese = 3,///< 日本語
};

/// JIT 面板文案表（四语）。
@interface A2JITStrings : NSObject

/// 全部 key（稳定顺序：面板 → 判据原因 → 判据动作 → 提示）。
+ (NSArray<NSString *> *)allKeys;

/// 全部语言代码（稳定顺序：zh-Hans / zh-Hant / en / ja）。
+ (NSArray<NSString *> *)allLanguageCodes;

/// 语言代码字符串。
+ (NSString *)codeForLanguage:(A2JITLanguage)language;

/// 语言展示名（诊断用，非本地化）。
+ (NSString *)displayNameForLanguage:(A2JITLanguage)language;

/// 按系统首选语言选语言（zh-Hant/zh-TW/zh-HK → 繁中；ja → 日；其余 → en）。
+ (A2JITLanguage)languageForSystemLocale;

/// 取指定语言的文案；key 或语言缺失返回 nil。
+ (nullable NSString *)stringForKey:(NSString *)key language:(A2JITLanguage)language;

/// 取系统语言的文案；key 缺失时回退 zh-Hans，再回退 key 本身（绝不返回 nil / 空串）。
+ (NSString *)stringForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
