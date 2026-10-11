//
//  A2JITStrings.m
//  Air2
//
//  [JIT-IMPL-2] 四语文案表实现：一张静态字典，无任何平台调用。
//  ★新增 key 必须同时补齐四语★（单测 allKeys × allLanguageCodes 全量断言，
//  漏一门语言就 FAIL —— 这是本表能长期不腐化的唯一保证）。
//

#import "A2JITStrings.h"
#import <dispatch/dispatch.h>

@implementation A2JITStrings

#pragma mark - 表本体

/// key → @{ @"zh-Hans": …， @"zh-Hant": …， @"en": …， @"ja": … }
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *A2JITStringTable(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
        // ---------------- 面板骨架 ----------------
        @"jit.section.title": @{
            @"zh-Hans": @"运行环境 · JIT",
            @"zh-Hant": @"執行環境 · JIT",
            @"en": @"Runtime · JIT",
            @"ja": @"実行環境 · JIT",
        },
        @"jit.section.footer": @{
            @"zh-Hans": @"导入只在设备本地校验，不联网；开启后由判据内核（brk #0x69 区域取证）复核是否真的可用。",
            @"zh-Hant": @"匯入只在裝置本機校驗，不連網；開啟後由判據內核（brk #0x69 區域取證）複核是否真的可用。",
            @"en": @"Import validates locally only, no network. After enabling, the verdict kernel re-checks real usability via brk #0x69 region evidence.",
            @"ja": @"取り込みは端末内でのみ検証し、通信は行いません。有効化後は判定カーネルが brk #0x69 の領域証跡で実際に使えるかを再確認します。",
        },

        // ---------------- 行标题 ----------------
        @"jit.row.status": @{
            @"zh-Hans": @"JIT 状态",
            @"zh-Hant": @"JIT 狀態",
            @"en": @"JIT status",
            @"ja": @"JIT の状態",
        },
        @"jit.row.strategy": @{
            @"zh-Hans": @"分级策略",
            @"zh-Hant": @"分級策略",
            @"en": @"Strategy",
            @"ja": @"段階ポリシー",
        },
        @"jit.row.next": @{
            @"zh-Hans": @"下一步动作",
            @"zh-Hant": @"下一步動作",
            @"en": @"Next action",
            @"ja": @"次の操作",
        },
        @"jit.row.import": @{
            @"zh-Hans": @"导入配对文件",
            @"zh-Hant": @"匯入配對檔",
            @"en": @"Import pairing file",
            @"ja": @"ペアリングファイルを取り込む",
        },
        @"jit.row.enable": @{
            @"zh-Hans": @"开启 JIT",
            @"zh-Hant": @"開啟 JIT",
            @"en": @"Enable JIT",
            @"ja": @"JIT を有効化",
        },
        @"jit.row.tool": @{
            @"zh-Hans": @"外部工具",
            @"zh-Hant": @"外部工具",
            @"en": @"External tool",
            @"ja": @"外部ツール",
        },
        @"jit.row.evidence": @{
            @"zh-Hans": @"判据取证",
            @"zh-Hant": @"判據取證",
            @"en": @"Verdict evidence",
            @"ja": @"判定の証跡",
        },

        // ---------------- 行副标题 / 状态 ----------------
        @"jit.row.import.ready": @{
            @"zh-Hans": @"已导入，可被后续步骤读取",
            @"zh-Hant": @"已匯入，可供後續步驟讀取",
            @"en": @"Imported; readable by later steps",
            @"ja": @"取り込み済み。後続ステップから読めます",
        },
        @"jit.row.import.needFile": @{
            @"zh-Hans": @"选择 .plist / .mobiledevicepairing，本机校验",
            @"zh-Hant": @"選擇 .plist / .mobiledevicepairing，本機校驗",
            @"en": @"Pick a .plist / .mobiledevicepairing; validated on device",
            @"ja": @".plist / .mobiledevicepairing を選択し、端末内で検証します",
        },
        @"jit.row.import.notNeeded": @{
            @"zh-Hans": @"本策略不需要配对文件",
            @"zh-Hant": @"本策略不需要配對檔",
            @"en": @"This strategy needs no pairing file",
            @"ja": @"このポリシーではペアリングファイル不要です",
        },
        @"jit.row.tool.installed": @{
            @"zh-Hans": @"已安装，可用 URL scheme 拉起",
            @"zh-Hant": @"已安裝，可用 URL scheme 拉起",
            @"en": @"Installed; launchable via URL scheme",
            @"ja": @"インストール済み。URL scheme で起動できます",
        },
        @"jit.row.tool.notInstalled": @{
            @"zh-Hans": @"未安装",
            @"zh-Hant": @"未安裝",
            @"en": @"Not installed",
            @"ja": @"未インストール",
        },
        @"jit.row.enable.ready": @{
            @"zh-Hans": @"按策略在 App 内开启并复验",
            @"zh-Hant": @"按策略在 App 內開啟並複驗",
            @"en": @"Enable inside the app, then verify",
            @"ja": @"アプリ内で有効化し、確認まで行います",
        },
        @"jit.row.enable.noPath": @{
            @"zh-Hans": @"当前环境无可用路径",
            @"zh-Hant": @"當前環境無可用路徑",
            @"en": @"No usable path in this environment",
            @"ja": @"現在の環境に利用可能な経路がありません",
        },

        // ---------------- 判据原因（按 verdict 分流）----------------
        @"jit.verdict.unknown.reason": @{
            @"zh-Hans": @"尚未探测 JIT 能力",
            @"zh-Hant": @"尚未探測 JIT 能力",
            @"en": @"JIT capability not probed yet",
            @"ja": @"JIT 能力は未確認です",
        },
        @"jit.verdict.usable.reason": @{
            @"zh-Hans": @"JIT 已复验可用",
            @"zh-Hant": @"JIT 已複驗可用",
            @"en": @"JIT verified usable",
            @"ja": @"JIT は使用可能と確認済みです",
        },
        @"jit.verdict.notserviced.reason": @{
            @"zh-Hans": @"brk #0x69 无人服务：未启用 JIT 或调试器未应答",
            @"zh-Hant": @"brk #0x69 無人服務：未啟用 JIT 或偵錯器未回應",
            @"en": @"brk #0x69 not serviced: JIT not enabled or no debugger answering",
            @"ja": @"brk #0x69 に応答なし：JIT 未有效かデバッガが応答していません",
        },
        @"jit.verdict.legacysentinel.reason": @{
            @"zh-Hans": @"回 legacy 哨兵 0xE0000069：需指派 JIT 脚本",
            @"zh-Hant": @"回應 legacy 哨兵 0xE0000069：需指派 JIT 腳本",
            @"en": @"Legacy sentinel 0xE0000069 returned: a JIT script must be assigned",
            @"ja": @"旧方式の番兵 0xE0000069 を返しました：JIT スクリプトの割り当てが必要です",
        },
        @"jit.verdict.nomapping.reason": @{
            @"zh-Hans": @"返回地址在进程内无映射：返回值是哨兵变体或垃圾",
            @"zh-Hant": @"回傳位址在行程內無對應：回傳值是哨兵變體或垃圾",
            @"en": @"Returned address has no mapping in this process: sentinel variant or garbage",
            @"ja": @"返されたアドレスにマッピングがありません：番兵の変種か不正値です",
        },
        @"jit.verdict.zerosize.reason": @{
            @"zh-Hans": @"返回区域 size=0：无有效长度",
            @"zh-Hant": @"回傳區域 size=0：無有效長度",
            @"en": @"Returned region has size=0: no usable length",
            @"ja": @"返された領域の size=0：有効な長さがありません",
        },
        @"jit.verdict.notexecutable.reason": @{
            @"zh-Hans": @"该页 max_protection 不含可执行位：永不可执行",
            @"zh-Hant": @"該頁 max_protection 不含可執行位：永不執行",
            @"en": @"Region max_protection lacks EXECUTE: can never be executable",
            @"ja": @"領域の max_protection に実行ビットなし：実行できません",
        },

        // ---------------- 下一步动作（与原因一一对应）----------------
        @"jit.verdict.unknown.action": @{
            @"zh-Hans": @"先导入配对文件或连接隧道，再点开启 JIT",
            @"zh-Hant": @"先匯入配對檔或連接隧道，再點開啟 JIT",
            @"en": @"Import the pairing file or connect the tunnel, then tap Enable JIT",
            @"ja": @"先にペアリングファイルを取り込むかトンネル接続し、JIT を有効化します",
        },
        @"jit.verdict.usable.action": @{
            @"zh-Hans": @"无需额外动作，可以直接启动",
            @"zh-Hant": @"無需額外動作，可以直接啟動",
            @"en": @"Nothing to do; you can launch now",
            @"ja": @"追加操作は不要です。すぐに起動できます",
        },
        @"jit.verdict.notserviced.action": @{
            @"zh-Hans": @"先启用 JIT（内置 helper 或外部工具）再重试",
            @"zh-Hant": @"先啟用 JIT（內建 helper 或外部工具）再重試",
            @"en": @"Enable JIT first (built-in helper or external tool), then retry",
            @"ja": @"先に JIT を有効化し（内蔵ヘルパーまたは外部ツール）、再試行します",
        },
        @"jit.verdict.legacysentinel.action": @{
            @"zh-Hans": @"在调试器里指派 Universal 或 Amethyst JIT 脚本后重试",
            @"zh-Hant": @"在偵錯器裡指派 Universal 或 Amethyst JIT 腳本後重試",
            @"en": @"Assign the Universal or Amethyst JIT script in the debugger, then retry",
            @"ja": @"デバッガで Universal か Amethyst の JIT スクリプトを割り当てて再試行します",
        },
        @"jit.verdict.nomapping.action": @{
            @"zh-Hans": @"重启 App 后重新开启 JIT：返回的地址不可用",
            @"zh-Hant": @"重新啟動 App 後重新開啟 JIT：回傳的位址不可用",
            @"en": @"Restart the app and enable JIT again: the returned address is unusable",
            @"ja": @"App を再起動して JIT を入れ直します：返されたアドレスは使用不可です",
        },
        @"jit.verdict.zerosize.action": @{
            @"zh-Hans": @"重启 App 后重试；仍失败请改用外部工具",
            @"zh-Hant": @"重新啟動 App 後重試；仍失敗請改用外部工具",
            @"en": @"Retry after restarting the app; if it still fails, use an external tool",
            @"ja": @"App を再起動して再試行します。なお失敗する場合は外部ツールを使います",
        },
        @"jit.verdict.notexecutable.action": @{
            @"zh-Hans": @"改用外部工具开启：该页在任何情况下都不可执行",
            @"zh-Hant": @"改用外部工具開啟：該頁在任何情況下都不可執行",
            @"en": @"Switch to an external tool: this page can never be executable",
            @"ja": @"外部ツールでの有効化に切り替えます：このページは実行不可です",
        },

        // ---------------- 提示 ----------------
        @"jit.toast.importing": @{
            @"zh-Hans": @"正在读取所选配对文件…",
            @"zh-Hant": @"正在讀取所選配對檔…",
            @"en": @"Reading the selected pairing file…",
            @"ja": @"選択したファイルを読み込み中…",
        },
        @"jit.toast.importOK": @{
            @"zh-Hans": @"已导入配对文件",
            @"zh-Hant": @"已匯入配對檔",
            @"en": @"Pairing file imported",
            @"ja": @"ペアリングファイルを取り込みました",
        },
        @"jit.toast.importFail": @{
            @"zh-Hans": @"导入失败",
            @"zh-Hant": @"匯入失敗",
            @"en": @"Import failed",
            @"ja": @"取り込みに失敗しました",
        },
        @"jit.toast.enabling": @{
            @"zh-Hans": @"正在开启并复验 JIT…",
            @"zh-Hant": @"正在開啟並複驗 JIT…",
            @"en": @"Enabling and verifying JIT…",
            @"ja": @"JIT を有効化して確認中…",
        },
        @"jit.toast.enabled": @{
            @"zh-Hans": @"JIT 已启用",
            @"zh-Hant": @"JIT 已啟用",
            @"en": @"JIT enabled",
            @"ja": @"JIT を有効化しました",
        },
        @"jit.toast.enableFail": @{
            @"zh-Hans": @"开启失败",
            @"zh-Hant": @"開啟失敗",
            @"en": @"Enable failed",
            @"ja": @"有効化に失敗しました",
        },
        };
    });
    return table;
}

#pragma mark - 查询

+ (NSArray<NSString *> *)allKeys {
    return [A2JITStringTable() allKeys];
}

+ (NSArray<NSString *> *)allLanguageCodes {
    return @[ @"zh-Hans", @"zh-Hant", @"en", @"ja" ];
}

+ (NSString *)codeForLanguage:(A2JITLanguage)language {
    NSArray<NSString *> *codes = [self allLanguageCodes];
    if (language < 0 || (NSUInteger)language >= codes.count) {
        return codes[A2JITLanguageZhHans];
    }
    return codes[(NSUInteger)language];
}

+ (NSString *)displayNameForLanguage:(A2JITLanguage)language {
    switch (language) {
        case A2JITLanguageZhHans: return @"zh-Hans";
        case A2JITLanguageZhHant: return @"zh-Hant";
        case A2JITLanguageEnglish: return @"en";
        case A2JITLanguageJapanese: return @"ja";
        default: return @"zh-Hans";
    }
}

+ (A2JITLanguage)languageForSystemLocale {
    NSString *first = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *tag = first.lowercaseString;
    if ([tag hasPrefix:@"zh"]) {
        // 繁體：zh-Hant / zh-TW / zh-HK / zh-MO；其餘（zh-Hans / zh-CN / zh-SG）为简体。
        if ([tag containsString:@"hant"] || [tag containsString:@"tw"] ||
            [tag containsString:@"hk"] || [tag containsString:@"mo"]) {
            return A2JITLanguageZhHant;
        }
        return A2JITLanguageZhHans;
    }
    if ([tag hasPrefix:@"ja"]) {
        return A2JITLanguageJapanese;
    }
    return A2JITLanguageEnglish;
}

+ (nullable NSString *)stringForKey:(NSString *)key language:(A2JITLanguage)language {
    if (key.length == 0) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *entry = A2JITStringTable()[key];
    if (entry == nil) {
        return nil;
    }
    return entry[[self codeForLanguage:language]];
}

+ (NSString *)stringForKey:(NSString *)key {
    if (key.length == 0) {
        return @"";
    }
    NSString *value = [self stringForKey:key language:[self languageForSystemLocale]];
    if (value.length == 0) {
        value = [self stringForKey:key language:A2JITLanguageZhHans];
    }
    // ★绝不返回空串★：缺 key 时把 key 本身回吐，便于一眼看出漏配。
    return value.length ? value : key;
}

@end
