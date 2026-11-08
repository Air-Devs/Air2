//
//  A2JITStrings.m
//  Air2
//
//  [JIT-PAGE-6] 四语文案表实现：一张静态字典，无任何平台调用。
//  ★新增 key 必须同时补齐四语★（单测 allKeys × allLanguageCodes 全量断言，
//  漏一门语言就 FAIL —— 这是本表能长期不腐化的唯一保证）。
//
//  ★本表的 key 集合 = 设置页「JIT」那 6 行的全部文案★：
//    状态 / 启动器 / 配对文件 / 开发者镜像 / 证据 / 诊断日志 + 7 档判据的原因与动作。
//  已删除的整块（见 git 历史）：调试暂停、GL 断点探针、启动器提前 detach 开关、
//    自研 RSD 自动配对（配对码来源 + 设备发起配对全链路）、外部工具多选、DDI 的手动导入与联网获取。
//  ★这些 key 已从表里连根删掉★：grep 表内 0 条、代码内 0 引用（单测 ⑪ 用负断言守着「不得回流」）。
//  ★删 key 必须同时删调用点★，否则单测的「每个 key 都被用到」断言会失败。
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
            @"zh-Hans": @"JIT",
            @"zh-Hant": @"JIT",
            @"en": @"JIT",
            @"ja": @"JIT",
        },
        @"jit.section.footer": @{
            @"zh-Hans": @"本页只做判定与开关，不联网；改动下次启动游戏生效。",
            @"zh-Hant": @"本頁只做判定與開關，不連網；變更於下次啟動遊戲生效。",
            @"en": @"This page only reports verdicts and toggles switches; nothing goes online. Changes apply on the next game launch.",
            @"ja": @"このページは判定とスイッチのみで、通信は行いません。変更は次回のゲーム起動から有効です。",
        },

        // ---------------- ① 状态（只读一行）----------------
        @"jit.row.status": @{
            @"zh-Hans": @"状态",
            @"zh-Hant": @"狀態",
            @"en": @"Status",
            @"ja": @"状態",
        },
        @"jit.status.ready": @{
            @"zh-Hans": @"就绪",
            @"zh-Hant": @"就緒",
            @"en": @"Ready",
            @"ja": @"準備完了",
        },
        @"jit.status.notReady": @{
            @"zh-Hans": @"未就绪",
            @"zh-Hant": @"未就緒",
            @"en": @"Not ready",
            @"ja": @"未準備",
        },
        @"jit.status.pending": @{
            @"zh-Hans": @"正在判定…",
            @"zh-Hant": @"正在判定…",
            @"en": @"Checking…",
            @"ja": @"判定中…",
        },
        // 副标题：来源 + 判据给的那一句原因（来源由本页据启动器选择 + 本机形态推断）
        @"jit.status.sourceFormat": @{
            @"zh-Hans": @"来源：%@",
            @"zh-Hant": @"來源：%@",
            @"en": @"Source: %@",
            @"ja": @"取得元：%@",
        },
        @"jit.source.builtin": @{
            @"zh-Hans": @"内建（StikJIT）",
            @"zh-Hant": @"內建（StikJIT）",
            @"en": @"Built-in (StikJIT)",
            @"ja": @"内蔵（StikJIT）",
        },
        @"jit.source.stikdebug": @{
            @"zh-Hans": @"StikDebug",
            @"zh-Hant": @"StikDebug",
            @"en": @"StikDebug",
            @"ja": @"StikDebug",
        },
        @"jit.source.trollstore": @{
            @"zh-Hans": @"TrollStore",
            @"zh-Hant": @"TrollStore",
            @"en": @"TrollStore",
            @"ja": @"TrollStore",
        },
        @"jit.source.jailbreak": @{
            @"zh-Hans": @"越狱",
            @"zh-Hant": @"越獄",
            @"en": @"Jailbroken",
            @"ja": @"脱獄",
        },

        // ---------------- ② 启动器（三选一）----------------
        @"jit.row.launcher": @{
            @"zh-Hans": @"启动器",
            @"zh-Hant": @"啟動器",
            @"en": @"Launcher",
            @"ja": @"ランチャー",
        },
        @"jit.launcher.builtin": @{
            @"zh-Hans": @"内建（StikJIT）",
            @"zh-Hant": @"內建（StikJIT）",
            @"en": @"Built-in (StikJIT)",
            @"ja": @"内蔵（StikJIT）",
        },
        @"jit.launcher.stikdebug": @{
            @"zh-Hans": @"StikDebug",
            @"zh-Hant": @"StikDebug",
            @"en": @"StikDebug",
            @"ja": @"StikDebug",
        },
        @"jit.launcher.auto": @{
            @"zh-Hans": @"自动",
            @"zh-Hant": @"自動",
            @"en": @"Auto",
            @"ja": @"自動",
        },
        @"jit.launcher.subtitle": @{
            @"zh-Hans": @"选哪条就只用哪条：该来源不可用时直接失败并说明原因（不回退）。下次启动游戏生效",
            @"zh-Hant": @"選哪條就只用哪條：該來源不可用時直接失敗並說明原因（不回退）。下次啟動遊戲生效",
            @"en": @"Only the chosen source is used: if unavailable the launch fails with a reason (no fallback). Applies to the next game launch.",
            @"ja": @"選んだ取得元のみを使用します。使えない場合は理由を出して失敗します（フォールバックなし）。次回のゲーム起動から有効です。",
        },
        @"jit.launcher.toast.selected": @{
            @"zh-Hans": @"JIT 启动器：%@（下次启动游戏生效）",
            @"zh-Hant": @"JIT 啟動器：%@（下次啟動遊戲生效）",
            @"en": @"JIT launcher: %@ (applies to the next game launch)",
            @"ja": @"JIT ランチャー：%@（次回のゲーム起動から有効）",
        },
        // 存量装机里可能还存着本页已不再提供的旧取值（debugger / jailbreak / trollstore / sidestore）
        // ⇒ 如实点名，不把它显示成「自动」（那会谎报到底是谁在给 JIT）。
        @"jit.launcher.legacy": @{
            @"zh-Hans": @"当前存的是旧取值「%@」（本页不再提供）；点一下重新选择",
            @"zh-Hant": @"目前存的是舊取值「%@」（本頁不再提供）；點一下重新選擇",
            @"en": @"A legacy value \"%@\" is stored (no longer offered here); tap to pick again",
            @"ja": @"旧い値「%@」が保存されています（本ページでは提供終了）。タップして選び直してください",
        },

        // ---------------- ③ 配对文件 ----------------
        @"jit.row.enable": @{
            @"zh-Hans": @"开启 JIT",
            @"zh-Hant": @"開啟 JIT",
            @"en": @"Turn on JIT",
            @"ja": @"JIT を有効にする",
        },
        @"jit.row.enable.subtitle": @{
            @"zh-Hans": @"由扩展进程 attach 本 App 并服务 brk（不需要外部 App）",
            @"zh-Hant": @"由擴充程式 attach 本 App 並服務 brk（不需要外部 App）",
            @"en": @"The helper extension attaches this app and services brk (no external app)",
            @"ja": @"拡張が本 App に attach して brk を処理します（外部 App 不要）",
        },
        @"jit.toast.enabling": @{
            @"zh-Hans": @"正在开启 JIT…",
            @"zh-Hant": @"正在開啟 JIT…",
            @"en": @"Turning JIT on…",
            @"ja": @"JIT を有効化中…",
        },
        @"jit.toast.enableOK": @{
            @"zh-Hans": @"JIT 已开启",
            @"zh-Hant": @"JIT 已開啟",
            @"en": @"JIT is on",
            @"ja": @"JIT を有効にしました",
        },
        @"jit.toast.enableFail": @{
            @"zh-Hans": @"开启失败",
            @"zh-Hant": @"開啟失敗",
            @"en": @"Could not turn JIT on",
            @"ja": @"JIT を有効にできませんでした",
        },
        @"jit.toast.ddiWorking": @{
            @"zh-Hans": @"正在下载/挂载开发者镜像…",
            @"zh-Hant": @"正在下載/掛載開發者映像…",
            @"en": @"Downloading and mounting the developer disk image…",
            @"ja": @"開発者ディスクイメージを取得・マウント中…",
        },
        @"jit.toast.ddiOK": @{
            @"zh-Hans": @"开发者镜像已就绪",
            @"zh-Hant": @"開發者映像已就緒",
            @"en": @"Developer disk image is ready",
            @"ja": @"開発者ディスクイメージの準備ができました",
        },
        @"jit.row.pairing": @{
            @"zh-Hans": @"配对文件",
            @"zh-Hant": @"配對檔",
            @"en": @"Pairing file",
            @"ja": @"ペアリングファイル",
        },
        @"jit.pairing.imported": @{
            @"zh-Hans": @"已导入",
            @"zh-Hant": @"已匯入",
            @"en": @"Imported",
            @"ja": @"取り込み済み",
        },
        @"jit.pairing.notImported": @{
            @"zh-Hans": @"未导入",
            @"zh-Hant": @"未匯入",
            @"en": @"Not imported",
            @"ja": @"未取り込み",
        },
        @"jit.pairing.subtitle.ready": @{
            @"zh-Hans": @"点一下可重新导入（本机校验，不联网）",
            @"zh-Hant": @"點一下可重新匯入（本機校驗，不連網）",
            @"en": @"Tap to import again (validated on device, no network)",
            @"ja": @"タップで取り込み直し（端末内検証・通信なし）",
        },
        @"jit.pairing.subtitle.needFile": @{
            @"zh-Hans": @"点一下选择 .plist / .mobiledevicepairing（本机校验，不联网）",
            @"zh-Hant": @"點一下選擇 .plist / .mobiledevicepairing（本機校驗，不連網）",
            @"en": @"Tap to pick a .plist / .mobiledevicepairing (validated on device, no network)",
            @"ja": @"タップして .plist / .mobiledevicepairing を選択（端末内検証・通信なし）",
        },

        // ---------------- ④ 开发者镜像（DDI）----------------
        @"jit.row.ddi": @{
            @"zh-Hans": @"开发者镜像",
            @"zh-Hant": @"開發者映像",
            @"en": @"Developer image",
            @"ja": @"開発者イメージ",
        },
        @"jit.ddi.state.mounted": @{
            @"zh-Hans": @"已挂载",
            @"zh-Hant": @"已掛載",
            @"en": @"Mounted",
            @"ja": @"マウント済み",
        },
        @"jit.ddi.state.notMounted": @{
            @"zh-Hans": @"未挂载",
            @"zh-Hant": @"未掛載",
            @"en": @"Not mounted",
            @"ja": @"未マウント",
        },
        @"jit.ddi.state.unknown": @{
            @"zh-Hans": @"未知",
            @"zh-Hant": @"未知",
            @"en": @"Unknown",
            @"ja": @"不明",
        },
        @"jit.ddi.subtitle.mirror": @{
            @"zh-Hans": @"本地镜像：%@；点一下重置 DDI 缓存",
            @"zh-Hant": @"本機映像：%@；點一下重設 DDI 快取",
            @"en": @"Local image: %@; tap to reset the DDI cache",
            @"ja": @"本機イメージ：%@。タップで DDI キャッシュをリセット",
        },
        @"jit.ddi.subtitle.none": @{
            @"zh-Hans": @"没有可用镜像；点一下重置 DDI 缓存",
            @"zh-Hant": @"沒有可用映像；點一下重設 DDI 快取",
            @"en": @"No usable image; tap to reset the DDI cache",
            @"ja": @"利用できるイメージがありません。タップで DDI キャッシュをリセット",
        },
        @"jit.ddi.subtitle.unknown": @{
            @"zh-Hans": @"无法确认镜像状态（目录不可读）；点一下重置 DDI 缓存",
            @"zh-Hant": @"無法確認映像狀態（目錄不可讀）；點一下重設 DDI 快取",
            @"en": @"Image state cannot be confirmed (directory unreadable); tap to reset the DDI cache",
            @"ja": @"イメージの状態を確認できません（ディレクトリ読めず）。タップで DDI キャッシュをリセット",
        },
        @"jit.toast.ddiResetting": @{
            @"zh-Hans": @"正在重置 DDI 缓存…",
            @"zh-Hant": @"正在重設 DDI 快取…",
            @"en": @"Resetting the DDI cache…",
            @"ja": @"DDI キャッシュをリセット中…",
        },
        @"jit.toast.ddiResetOK": @{
            @"zh-Hans": @"DDI 缓存已重置",
            @"zh-Hant": @"DDI 快取已重設",
            @"en": @"DDI cache reset",
            @"ja": @"DDI キャッシュをリセットしました",
        },
        @"jit.toast.ddiResetFail": @{
            @"zh-Hans": @"DDI 缓存重置失败",
            @"zh-Hant": @"DDI 快取重設失敗",
            @"en": @"DDI cache reset failed",
            @"ja": @"DDI キャッシュのリセットに失敗しました",
        },
        @"jit.toast.ddiResetUnavailable": @{
            @"zh-Hans": @"无法重置 DDI 缓存：%@",
            @"zh-Hant": @"無法重設 DDI 快取：%@",
            @"en": @"Cannot reset the DDI cache: %@",
            @"ja": @"DDI キャッシュをリセットできません：%@",
        },

        // ---------------- ⑤ 证据（只读，长按复制日志路径）----------------
        @"jit.row.evidence": @{
            @"zh-Hans": @"证据",
            @"zh-Hant": @"證據",
            @"en": @"Evidence",
            @"ja": @"証跡",
        },
        @"jit.evidence.none": @{
            @"zh-Hans": @"无取证记录",
            @"zh-Hant": @"無取證記錄",
            @"en": @"No evidence recorded",
            @"ja": @"証跡の記録なし",
        },
        @"jit.evidence.hint": @{
            @"zh-Hans": @"长按复制日志路径",
            @"zh-Hant": @"長按複製日誌路徑",
            @"en": @"Long-press to copy the log path",
            @"ja": @"長押しでログのパスをコピー",
        },
        @"jit.evidence.copied": @{
            @"zh-Hans": @"已复制日志路径",
            @"zh-Hant": @"已複製日誌路徑",
            @"en": @"Log path copied",
            @"ja": @"ログのパスをコピーしました",
        },

        // ---------------- ⑥ 诊断日志（开关）----------------
        @"jit.row.diaglog": @{
            @"zh-Hans": @"诊断日志",
            @"zh-Hant": @"診斷日誌",
            @"en": @"Diagnostic log",
            @"ja": @"診断ログ",
        },
        @"jit.diaglog.subtitle": @{
            @"zh-Hans": @"把 JIT 判定与启动链的逐项细节写进 lastlog（默认关）",
            @"zh-Hant": @"把 JIT 判定與啟動鏈的逐項細節寫進 lastlog（預設關）",
            @"en": @"Write per-step JIT/launch details into lastlog (off by default)",
            @"ja": @"JIT 判定と起動チェーンの詳細を lastlog に書き出します（既定はオフ）",
        },
        @"jit.toast.diaglogOn": @{
            @"zh-Hans": @"诊断日志：开",
            @"zh-Hant": @"診斷日誌：開",
            @"en": @"Diagnostic log: on",
            @"ja": @"診断ログ：オン",
        },
        @"jit.toast.diaglogOff": @{
            @"zh-Hans": @"诊断日志：关",
            @"zh-Hant": @"診斷日誌：關",
            @"en": @"Diagnostic log: off",
            @"ja": @"診断ログ：オフ",
        },

        // ---------------- 判据原因（按 verdict 分流；A2JITVerdictGuidance 与失败页共用）----------------
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

        // ---------------- 下一步动作（与原因一一对应；失败页用）----------------
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
            @"ja": @"選択したペアリングファイルを読み込み中…",
        },
        @"jit.toast.importOK": @{
            @"zh-Hans": @"配对文件已导入",
            @"zh-Hant": @"配對檔已匯入",
            @"en": @"Pairing file imported",
            @"ja": @"ペアリングファイルを取り込みました",
        },
        @"jit.toast.importFail": @{
            @"zh-Hans": @"配对文件导入失败",
            @"zh-Hant": @"配對檔匯入失敗",
            @"en": @"Pairing file import failed",
            @"ja": @"ペアリングファイルの取り込みに失敗しました",
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
    if (value.length > 0) {
        return value;
    }
    value = [self stringForKey:key language:A2JITLanguageZhHans];
    return value.length > 0 ? value : key;
}

@end
