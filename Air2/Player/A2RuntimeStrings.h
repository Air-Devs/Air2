//
//  A2RuntimeStrings.h
//  Air2
//
//  Player —— 「运行环境（渲染器 / Java 运行时）」面板的【四语】文案表（zh-Hans / zh-Hant / en / ja）。
//
//  ★为什么放在这里（而不是 .lproj）★：与 A2JITStrings 同一决策 ——
//    · 本仓目前没有 i18n 基建（无 .lproj / 无 Localizable.strings）；
//    · 放在 Player 的纯逻辑件里 ⇒ ★可单测★：单测断言「每个 key 在四语里都存在且非空」
//      「每个渲染器候选 / 每个 JRE 档位的文案 key 都在表里」⇒ 把「四语文案齐」变成机器判据；
//    · key 稳定（runtime.*），将来迁 .lproj 时不用改调用点。
//
//  ★谁用它★：
//    · `Air2/UI/Screens/Settings/A2RuntimeSettings.m` —— 分组标题 / 行标题 / 候选名 / 提示
//    · `Air2/Player/A2LaunchSession.m` —— 阻断文案 + 判据行里的「源」字
//
//  ★纯逻辑、无 UIKit、无网络★。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 支持的界面语言（★顺序即 allLanguageCodes 的顺序★；与 A2JITLanguage 同序）。
typedef NS_ENUM(NSInteger, A2RuntimeLanguage) {
    A2RuntimeLanguageZhHans = 0,  ///< 简体中文
    A2RuntimeLanguageZhHant = 1,  ///< 繁體中文
    A2RuntimeLanguageEnglish = 2, ///< English
    A2RuntimeLanguageJapanese = 3,///< 日本語
};

@interface A2RuntimeStrings : NSObject

/// 全部 key（稳定顺序）。
+ (NSArray<NSString *> *)allKeys;

/// 全部语言代码（稳定顺序：zh-Hans / zh-Hant / en / ja）。
+ (NSArray<NSString *> *)allLanguageCodes;

/// 语言代码字符串。
+ (NSString *)codeForLanguage:(A2RuntimeLanguage)language;

/// 按系统首选语言选语言（zh-Hant/zh-TW/zh-HK/zh-MO → 繁中；ja → 日；其余 → en）。
+ (A2RuntimeLanguage)languageForSystemLocale;

/// 取指定语言的文案；key 或语言缺失返回 nil。
+ (nullable NSString *)stringForKey:(NSString *)key language:(A2RuntimeLanguage)language;

/// 取系统语言的文案；key 缺失时回退 zh-Hans，再回退 key 本身（绝不返回 nil / 空串）。
+ (NSString *)stringForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
