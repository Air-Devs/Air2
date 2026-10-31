//
//  A2RuntimeStrings.m
//  Air2
//
//  [RENDER-SEL]/[JRE-SEL] 四语文案表实现：一张静态字典，无任何平台调用。
//  ★新增 key 必须同时补齐四语★（单测 allKeys × allLanguageCodes 全量断言，
//  漏一门语言就 FAIL —— 这是本表能长期不腐化的唯一保证）。
//
//  key 分区：
//    runtime.section.* / runtime.row.*  面板骨架与行
//    runtime.tier.* / runtime.bundled*  档位与内置状态
//    runtime.pick.* / runtime.toast.*   选择器与提示
//    runtime.source.*                   判据行里的「源」
//    runtime.blocked.*                  阻断文案（未内置 / 不合格）
//    runtime.renderer.*                 渲染器候选名（key 由 A2RendererCatalog 生成）
//    runtime.jre.*                      运行时档位名与「适合哪些 MC」（key 由 A2JavaRuntimeCatalog 生成）
//

#import "A2RuntimeStrings.h"
#import <dispatch/dispatch.h>

@implementation A2RuntimeStrings

#pragma mark - 表本体

/// key → @{ @"zh-Hans": …， @"zh-Hant": …， @"en": …， @"ja": … }
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *A2RuntimeStringTable(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
        // ---------------- 分组骨架 ----------------
        @"runtime.section.title": @{
            @"zh-Hans": @"运行环境",
            @"zh-Hant": @"執行環境",
            @"en": @"Runtime",
            @"ja": @"実行環境",
        },
        @"runtime.section.footer": @{
            @"zh-Hans": @"选中的渲染器由启动链显式加载；选中的 Java 运行时成为启动计划的 javaHome。未内置的项仍可见，选中后启动会如实阻断（不静默回退）。",
            @"zh-Hant": @"選中的渲染器由啟動鏈顯式載入；選中的 Java 執行環境成為啟動計畫的 javaHome。未內建的項目仍可見，選中後啟動會如實阻斷（不靜默回退）。",
            @"en": @"The selected renderer is loaded explicitly by the launch chain; the selected Java runtime becomes the plan's javaHome. Non-bundled entries stay visible — picking one blocks the launch honestly (no silent fallback).",
            @"ja": @"選択したレンダラーは起動チェーンが明示的に読み込み、選択した Java ランタイムが起動プランの javaHome になります。未同梱の項目も表示され、選択すると起動は正直にブロックされます（暗黙のフォールバックなし）。",
        },

        // ---------------- 行 ----------------
        @"runtime.row.renderer": @{
            @"zh-Hans": @"渲染器",
            @"zh-Hant": @"渲染器",
            @"en": @"Renderer",
            @"ja": @"レンダラー",
        },
        @"runtime.row.jre": @{
            @"zh-Hans": @"Java 运行时",
            @"zh-Hant": @"Java 執行環境",
            @"en": @"Java runtime",
            @"ja": @"Java ランタイム",
        },
        @"runtime.row.scale": @{
            @"zh-Hans": @"渲染分辨率",
            @"zh-Hant": @"渲染解析度",
            @"en": @"Render resolution",
            @"ja": @"レンダリング解像度",
        },
        @"runtime.row.scale.detail": @{
            @"zh-Hans": @"降低内部分辨率以提升帧率（逻辑尺寸不变）",
            @"zh-Hant": @"降低內部解析度以提升幀率（邏輯尺寸不變）",
            @"en": @"Lower internal resolution for more fps (logical size unchanged)",
            @"ja": @"内部解像度を下げてフレームレートを上げます（論理サイズは不変）",
        },

        // ---------------- 档位 / 内置状态 ----------------
        @"runtime.tier.recommended": @{
            @"zh-Hans": @"主推",
            @"zh-Hant": @"主推",
            @"en": @"Recommended",
            @"ja": @"推奨",
        },
        @"runtime.tier.compat": @{
            @"zh-Hans": @"兼容底",
            @"zh-Hant": @"相容底",
            @"en": @"Compatibility",
            @"ja": @"互換用",
        },
        @"runtime.tier.experimental": @{
            @"zh-Hans": @"实验",
            @"zh-Hant": @"實驗",
            @"en": @"Experimental",
            @"ja": @"実験的",
        },
        @"runtime.bundled": @{
            @"zh-Hans": @"已内置",
            @"zh-Hant": @"已內建",
            @"en": @"Bundled",
            @"ja": @"同梱済み",
        },
        @"runtime.notBundled": @{
            @"zh-Hans": @"未内置",
            @"zh-Hant": @"未內建",
            @"en": @"Not bundled",
            @"ja": @"未同梱",
        },

        // ---------------- 选择器 ----------------
        @"runtime.pick.renderer.title": @{
            @"zh-Hans": @"渲染器",
            @"zh-Hant": @"渲染器",
            @"en": @"Renderer",
            @"ja": @"レンダラー",
        },
        @"runtime.pick.renderer.message": @{
            @"zh-Hans": @"未内置的项仍可选中，但启动时会如实阻断",
            @"zh-Hant": @"未內建的項目仍可選中，但啟動時會如實阻斷",
            @"en": @"Non-bundled entries can be picked, but the launch will block honestly",
            @"ja": @"未同梱の項目も選択できますが、起動時に正直にブロックされます",
        },
        @"runtime.pick.jre.title": @{
            @"zh-Hans": @"Java 运行时",
            @"zh-Hant": @"Java 執行環境",
            @"en": @"Java runtime",
            @"ja": @"Java ランタイム",
        },
        @"runtime.pick.jre.message": @{
            @"zh-Hans": @"未内置的档位仍可选中，但启动时会如实阻断（不自动换档）",
            @"zh-Hant": @"未內建的檔位仍可選中，但啟動時會如實阻斷（不自動換檔）",
            @"en": @"Non-bundled entries can be picked, but the launch will block honestly (no auto-switch)",
            @"ja": @"未同梱の項目も選択できますが、起動時に正直にブロックされます（自動切替なし）",
        },
        @"runtime.scale.native": @{
            @"zh-Hans": @"原生",
            @"zh-Hant": @"原生",
            @"en": @"Native",
            @"ja": @"ネイティブ",
        },
        @"runtime.pick.scale.title": @{
            @"zh-Hans": @"渲染分辨率",
            @"zh-Hant": @"渲染解析度",
            @"en": @"Render resolution",
            @"ja": @"レンダリング解像度",
        },
        @"runtime.pick.scale.message": @{
            @"zh-Hans": @"内部分辨率越低越省性能；逻辑尺寸（界面/触摸）不变",
            @"zh-Hant": @"內部解析度越低越省效能；邏輯尺寸（介面/觸控）不變",
            @"en": @"A lower internal resolution costs less; logical size (UI/touch) is unchanged",
            @"ja": @"内部解像度が低いほど軽くなります（論理サイズ＝UI/タッチは不変）",
        },
        @"runtime.toast.selected": @{
            @"zh-Hans": @"已选择「%@」",
            @"zh-Hant": @"已選擇「%@」",
            @"en": @"Selected \"%@\"",
            @"ja": @"「%@」を選択しました",
        },

        // ---------------- 判据行里的「源」 ----------------
        @"runtime.source.user": @{
            @"zh-Hans": @"用户选择",
            @"zh-Hant": @"使用者選擇",
            @"en": @"user choice",
            @"ja": @"ユーザー選択",
        },
        @"runtime.source.default": @{
            @"zh-Hans": @"默认",
            @"zh-Hant": @"預設",
            @"en": @"default",
            @"ja": @"既定",
        },

        // ---------------- 阻断 ----------------
        @"runtime.blocked.renderer": @{
            @"zh-Hans": @"所选渲染器未内置：%@（包内缺 Frameworks/%@）⇒ 已阻断启动，请改选已内置的渲染器",
            @"zh-Hant": @"所選渲染器未內建：%@（包內缺 Frameworks/%@）⇒ 已阻斷啟動，請改選已內建的渲染器",
            @"en": @"The chosen renderer is not bundled: %@ (missing Frameworks/%@ in this build) — launch blocked; pick a bundled renderer",
            @"ja": @"選択したレンダラーは未同梱です：%@（このビルドに Frameworks/%@ がありません）— 起動をブロックしました。同梱済みのレンダラーを選び直してください",
        },
        @"runtime.blocked.jre": @{
            @"zh-Hans": @"所选 Java 运行时未内置/不完整：%@（缺 lib/server/libjvm.dylib）⇒ 已阻断启动，请改选已内置的档位",
            @"zh-Hant": @"所選 Java 執行環境未內建/不完整：%@（缺 lib/server/libjvm.dylib）⇒ 已阻斷啟動，請改選已內建的檔位",
            @"en": @"The chosen Java runtime is missing or incomplete: %@ (no lib/server/libjvm.dylib) — launch blocked; pick a bundled one",
            @"ja": @"選択した Java ランタイムが未同梱／不完全です：%@（lib/server/libjvm.dylib がありません）— 起動をブロックしました。同梱済みの項目を選び直してください",
        },

        // ---------------- 渲染器候选名（key 由 A2RendererCatalog 生成）----------------
        @"runtime.renderer.metallum": @{
            @"zh-Hans": @"Metal（自研 · libmetallum.dylib）",
            @"zh-Hant": @"Metal（自研 · libmetallum.dylib）",
            @"en": @"Metal (in-house · libmetallum.dylib)",
            @"ja": @"Metal（自社製 · libmetallum.dylib）",
        },
        @"runtime.renderer.gl4es_114": @{
            @"zh-Hans": @"GL4ES（libgl4es_114.dylib）",
            @"zh-Hant": @"GL4ES（libgl4es_114.dylib）",
            @"en": @"GL4ES (libgl4es_114.dylib)",
            @"ja": @"GL4ES（libgl4es_114.dylib）",
        },
        @"runtime.renderer.mobileglues": @{
            @"zh-Hans": @"MobileGlues（libmobileglues.dylib）",
            @"zh-Hant": @"MobileGlues（libmobileglues.dylib）",
            @"en": @"MobileGlues (libmobileglues.dylib)",
            @"ja": @"MobileGlues（libmobileglues.dylib）",
        },
        // ★系统 GLES 3.0（EAGL）★ —— 1.17+ 的临时默认项：EGL 由本层（假 EGL → EAGL）提供，
        //   GL 层是 MobileGlues。标识里的 dylib 名只是选择键（包内没有这个文件）。
        @"runtime.renderer.eagl": @{
            @"zh-Hans": @"系统 GLES 3.0（EAGL · 假 EGL）",
            @"zh-Hant": @"系統 GLES 3.0（EAGL · 假 EGL）",
            @"en": @"System GLES 3.0 (EAGL · host EGL)",
            @"ja": @"システム GLES 3.0（EAGL · ホスト EGL）",
        },
        @"runtime.renderer.nggl4es": @{
            @"zh-Hans": @"NG-GL4ES（libnggl4es.dylib）",
            @"zh-Hant": @"NG-GL4ES（libnggl4es.dylib）",
            @"en": @"NG-GL4ES (libnggl4es.dylib)",
            @"ja": @"NG-GL4ES（libnggl4es.dylib）",
        },
        // ★≤1.12.2 的默认固定管线后端★（Krypton Wrapper 构建：ES3 转译 + 宿主显式初始化）
        @"runtime.renderer.nggl4es_kw": @{
            @"zh-Hans": @"NG-GL4ES / KW（libnggl4es_kw.dylib）",
            @"zh-Hant": @"NG-GL4ES / KW（libnggl4es_kw.dylib）",
            @"en": @"NG-GL4ES / KW (libnggl4es_kw.dylib)",
            @"ja": @"NG-GL4ES / KW（libnggl4es_kw.dylib）",
        },
        @"runtime.renderer.moltenvk": @{
            @"zh-Hans": @"MoltenVK（libMoltenVK.dylib）",
            @"zh-Hant": @"MoltenVK（libMoltenVK.dylib）",
            @"en": @"MoltenVK (libMoltenVK.dylib)",
            @"ja": @"MoltenVK（libMoltenVK.dylib）",
        },
        @"runtime.renderer.osmesa_8": @{
            @"zh-Hans": @"OSMesa / Zink（libOSMesa.8.dylib）",
            @"zh-Hant": @"OSMesa / Zink（libOSMesa.8.dylib）",
            @"en": @"OSMesa / Zink (libOSMesa.8.dylib)",
            @"ja": @"OSMesa / Zink（libOSMesa.8.dylib）",
        },
        @"runtime.renderer.tinygl4angle": @{
            @"zh-Hans": @"ANGLE / tinygl4（libtinygl4angle.dylib）",
            @"zh-Hant": @"ANGLE / tinygl4（libtinygl4angle.dylib）",
            @"en": @"ANGLE / tinygl4 (libtinygl4angle.dylib)",
            @"ja": @"ANGLE / tinygl4（libtinygl4angle.dylib）",
        },

        // ---------------- Java 运行时档位（key 由 A2JavaRuntimeCatalog 生成）----------------
        @"runtime.jre.25": @{
            @"zh-Hans": @"Java 25（java-25-openjdk）",
            @"zh-Hant": @"Java 25（java-25-openjdk）",
            @"en": @"Java 25 (java-25-openjdk)",
            @"ja": @"Java 25（java-25-openjdk）",
        },
        @"runtime.jre.21": @{
            @"zh-Hans": @"Java 21（java-21-openjdk）",
            @"zh-Hant": @"Java 21（java-21-openjdk）",
            @"en": @"Java 21 (java-21-openjdk)",
            @"ja": @"Java 21（java-21-openjdk）",
        },
        @"runtime.jre.17": @{
            @"zh-Hans": @"Java 17（java-17-openjdk）",
            @"zh-Hant": @"Java 17（java-17-openjdk）",
            @"en": @"Java 17 (java-17-openjdk)",
            @"ja": @"Java 17（java-17-openjdk）",
        },
        @"runtime.jre.8": @{
            @"zh-Hans": @"Java 8（java-8-openjdk）",
            @"zh-Hant": @"Java 8（java-8-openjdk）",
            @"en": @"Java 8 (java-8-openjdk)",
            @"ja": @"Java 8（java-8-openjdk）",
        },
        @"runtime.jre.mc.25": @{
            @"zh-Hans": @"适合 MC 1.21.9+ / 26.x",
            @"zh-Hant": @"適合 MC 1.21.9+ / 26.x",
            @"en": @"For MC 1.21.9+ / 26.x",
            @"ja": @"MC 1.21.9+ / 26.x 向け",
        },
        @"runtime.jre.mc.21": @{
            @"zh-Hans": @"适合 MC 1.20.5 – 1.21.8",
            @"zh-Hant": @"適合 MC 1.20.5 – 1.21.8",
            @"en": @"For MC 1.20.5 – 1.21.8",
            @"ja": @"MC 1.20.5 – 1.21.8 向け",
        },
        @"runtime.jre.mc.17": @{
            @"zh-Hans": @"适合 MC 1.17 – 1.20.4",
            @"zh-Hant": @"適合 MC 1.17 – 1.20.4",
            @"en": @"For MC 1.17 – 1.20.4",
            @"ja": @"MC 1.17 – 1.20.4 向け",
        },
        @"runtime.jre.mc.8": @{
            @"zh-Hans": @"适合 MC ≤ 1.16.5",
            @"zh-Hant": @"適合 MC ≤ 1.16.5",
            @"en": @"For MC ≤ 1.16.5",
            @"ja": @"MC ≤ 1.16.5 向け",
        },
        @"runtime.jre.mc.unknown": @{
            @"zh-Hans": @"未知档位",
            @"zh-Hant": @"未知檔位",
            @"en": @"Unknown tier",
            @"ja": @"不明な項目",
        },
        };
    });
    return table;
}

#pragma mark - 查询

+ (NSArray<NSString *> *)allKeys {
    // ★稳定顺序★：把表排一遍，避免字典无序导致测试输出乱序。
    return [A2RuntimeStringTable().allKeys sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)allLanguageCodes {
    return @[ @"zh-Hans", @"zh-Hant", @"en", @"ja" ];
}

+ (NSString *)codeForLanguage:(A2RuntimeLanguage)language {
    NSArray<NSString *> *codes = [self allLanguageCodes];
    if (language < 0 || (NSUInteger)language >= codes.count) {
        return codes[A2RuntimeLanguageZhHans];
    }
    return codes[(NSUInteger)language];
}

+ (A2RuntimeLanguage)languageForSystemLocale {
    NSString *first = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *tag = first.lowercaseString;
    if ([tag hasPrefix:@"zh"]) {
        // 繁體：zh-Hant / zh-TW / zh-HK / zh-MO；其餘（zh-Hans / zh-CN / zh-SG）为简体。
        if ([tag containsString:@"hant"] || [tag containsString:@"tw"] ||
            [tag containsString:@"hk"] || [tag containsString:@"mo"]) {
            return A2RuntimeLanguageZhHant;
        }
        return A2RuntimeLanguageZhHans;
    }
    if ([tag hasPrefix:@"ja"]) {
        return A2RuntimeLanguageJapanese;
    }
    return A2RuntimeLanguageEnglish;
}

+ (nullable NSString *)stringForKey:(NSString *)key language:(A2RuntimeLanguage)language {
    if (key.length == 0) return nil;
    NSDictionary<NSString *, NSString *> *entry = A2RuntimeStringTable()[key];
    if (entry == nil) return nil;
    return entry[[self codeForLanguage:language]];
}

+ (NSString *)stringForKey:(NSString *)key {
    if (key.length == 0) return @"";
    NSString *value = [self stringForKey:key language:[self languageForSystemLocale]];
    if (value.length == 0) {
        value = [self stringForKey:key language:A2RuntimeLanguageZhHans];
    }
    // ★绝不返回空串★：缺 key 时把 key 本身回吐，便于一眼看出漏配。
    return value.length ? value : key;
}

@end
