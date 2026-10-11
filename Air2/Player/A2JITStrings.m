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

        // ------------- [JIT-AUTOPAIR-1] 自动配对（iOS 27+，自研 RPPairing） -------------
        // 行
        @"jit.row.autopair": @{
            @"zh-Hans": @"自动配对",
            @"zh-Hant": @"自動配對",
            @"en": @"Auto pairing",
            @"ja": @"自動ペアリング",
        },
        @"jit.row.autopair.recommended": @{
            @"zh-Hans": @"推荐",
            @"zh-Hant": @"推薦",
            @"en": @"Recommended",
            @"ja": @"推奨",
        },
        @"jit.row.autopair.ready": @{
            @"zh-Hans": @"配对文件已就绪（新鲜）",
            @"zh-Hant": @"配對檔已就緒（新鮮）",
            @"en": @"Pairing file ready (fresh)",
            @"ja": @"ペアリングファイルは準備済み（新しい）",
        },
        @"jit.row.autopair.needRun": @{
            @"zh-Hans": @"点此在本机自动生成配对文件（无需 PC）",
            @"zh-Hant": @"點此在本機自動產生配對檔（無需 PC）",
            @"en": @"Tap to generate the pairing file on-device (no PC)",
            @"ja": @"タップして端末内でペアリングファイルを生成します（PC 不要）",
        },
        @"jit.row.autopair.notApplicable": @{
            @"zh-Hans": @"仅 iOS 27+ 适用",
            @"zh-Hant": @"僅 iOS 27+ 適用",
            @"en": @"Applies to iOS 27+ only",
            @"ja": @"iOS 27 以降のみ対象です",
        },
        @"jit.row.autopair.precondMissing": @{
            @"zh-Hans": @"前置未满足：%@",
            @"zh-Hant": @"前置未滿足：%@",
            @"en": @"Precondition unmet: %@",
            @"ja": @"前提条件が未達：%@",
        },
        @"jit.row.autopair.precondUnknown": @{
            @"zh-Hans": @"前置未确认：%@",
            @"zh-Hant": @"前置未確認：%@",
            @"en": @"Precondition unconfirmed: %@",
            @"ja": @"前提条件が未確認：%@",
        },
        // 前置条件名 / 判定态
        @"jit.autopair.precond.developerMode": @{
            @"zh-Hans": @"Developer Mode（开发者模式）",
            @"zh-Hant": @"Developer Mode（開發者模式）",
            @"en": @"Developer Mode",
            @"ja": @"Developer Mode",
        },
        @"jit.autopair.precond.localNetwork": @{
            @"zh-Hans": @"本地网络权限",
            @"zh-Hant": @"本機網路權限",
            @"en": @"Local Network permission",
            @"ja": @"ローカルネットワーク権限",
        },
        @"jit.autopair.precond.getTaskAllow": @{
            @"zh-Hans": @"get-task-allow 签名",
            @"zh-Hant": @"get-task-allow 簽章",
            @"en": @"get-task-allow entitlement",
            @"ja": @"get-task-allow 署名",
        },
        @"jit.autopair.precond.ddi": @{
            @"zh-Hans": @"DDI（Developer Disk Image）",
            @"zh-Hant": @"DDI（Developer Disk Image）",
            @"en": @"DDI (Developer Disk Image)",
            @"ja": @"DDI（Developer Disk Image）",
        },
        @"jit.autopair.precond.satisfied": @{
            @"zh-Hans": @"已满足",
            @"zh-Hant": @"已滿足",
            @"en": @"Met",
            @"ja": @"満たしています",
        },
        @"jit.autopair.precond.unsatisfied": @{
            @"zh-Hans": @"未满足",
            @"zh-Hant": @"未滿足",
            @"en": @"Unmet",
            @"ja": @"満たしていません",
        },
        @"jit.autopair.precond.unknown": @{
            @"zh-Hans": @"无法确认",
            @"zh-Hant": @"無法確認",
            @"en": @"Unconfirmed",
            @"ja": @"確認できません",
        },
        // 阻塞 / 失败分类：原因
        @"jit.autopair.blocker.none.reason": @{
            @"zh-Hans": @"无阻塞",
            @"zh-Hant": @"無阻塞",
            @"en": @"No blocker",
            @"ja": @"ブロックなし",
        },
        @"jit.autopair.blocker.systemTooOld.reason": @{
            @"zh-Hans": @"本机系统低于 iOS 27：设备内自动配对不适用",
            @"zh-Hant": @"本機系統低於 iOS 27：裝置內自動配對不適用",
            @"en": @"System is below iOS 27: in-device auto pairing does not apply",
            @"ja": @"本機は iOS 27 未満：端末内の自動ペアリングは対象外です",
        },
        @"jit.autopair.blocker.developerMode.reason": @{
            @"zh-Hans": @"Developer Mode 未开启",
            @"zh-Hant": @"Developer Mode 未開啟",
            @"en": @"Developer Mode is off",
            @"ja": @"Developer Mode がオフです",
        },
        @"jit.autopair.blocker.localNetwork.reason": @{
            @"zh-Hans": @"未授予本地网络权限",
            @"zh-Hant": @"未授予本機網路權限",
            @"en": @"Local Network permission not granted",
            @"ja": @"ローカルネットワークの権限がありません",
        },
        @"jit.autopair.blocker.getTaskAllow.reason": @{
            @"zh-Hans": @"签名缺少 get-task-allow",
            @"zh-Hant": @"簽章缺少 get-task-allow",
            @"en": @"Signature lacks get-task-allow",
            @"ja": @"署名に get-task-allow がありません",
        },
        @"jit.autopair.blocker.ddi.reason": @{
            @"zh-Hans": @"缺少 DDI（首次需联网获取）",
            @"zh-Hant": @"缺少 DDI（首次需連網取得）",
            @"en": @"DDI missing (first run needs network)",
            @"ja": @"DDI がありません（初回はネット接続が必要）",
        },
        @"jit.autopair.blocker.precondUnknown.reason": @{
            @"zh-Hans": @"前置条件无法确认（探测未接入）",
            @"zh-Hant": @"前置條件無法確認（探測未接入）",
            @"en": @"Preconditions unconfirmed (probe not wired)",
            @"ja": @"前提条件を確認できません（検出は未接続）",
        },
        @"jit.autopair.blocker.engineUnavailable.reason": @{
            @"zh-Hans": @"RPPairing 引擎未接入",
            @"zh-Hant": @"RPPairing 引擎未接入",
            @"en": @"RPPairing engine not wired in",
            @"ja": @"RPPairing エンジンは未接続です",
        },
        @"jit.autopair.blocker.discovery.reason": @{
            @"zh-Hans": @"未发现 RSD 广播（Bonjour）",
            @"zh-Hant": @"未發現 RSD 廣播（Bonjour）",
            @"en": @"No RSD advertisement found (Bonjour)",
            @"ja": @"RSD の広告（Bonjour）が見つかりません",
        },
        @"jit.autopair.blocker.rsd.reason": @{
            @"zh-Hans": @"RSD 端口连接失败",
            @"zh-Hant": @"RSD 連接埠連線失敗",
            @"en": @"Failed to connect to the RSD port",
            @"ja": @"RSD ポートへの接続に失敗しました",
        },
        @"jit.autopair.blocker.pairVerify.reason": @{
            @"zh-Hans": @"pair-verify 失败",
            @"zh-Hant": @"pair-verify 失敗",
            @"en": @"pair-verify failed",
            @"ja": @"pair-verify に失敗しました",
        },
        @"jit.autopair.blocker.tunnel.reason": @{
            @"zh-Hans": @"TLS-PSK 隧道建立失败",
            @"zh-Hant": @"TLS-PSK 通道建立失敗",
            @"en": @"Failed to establish the TLS-PSK tunnel",
            @"ja": @"TLS-PSK トンネルの確立に失敗しました",
        },
        @"jit.autopair.blocker.write.reason": @{
            @"zh-Hans": @"配对文件写出失败",
            @"zh-Hant": @"配對檔寫出失敗",
            @"en": @"Failed to write the pairing file",
            @"ja": @"ペアリングファイルの書き出しに失敗しました",
        },
        @"jit.autopair.blocker.stale.reason": @{
            @"zh-Hans": @"配对文件已过期（超过 7 天窗口）",
            @"zh-Hant": @"配對檔已過期（超過 7 天視窗）",
            @"en": @"Pairing file is stale (beyond the 7-day window)",
            @"ja": @"ペアリングファイルが期限切れです（7 日超）",
        },
        // 阻塞 / 失败分类：下一步动作
        @"jit.autopair.blocker.none.action": @{
            @"zh-Hans": @"可以继续",
            @"zh-Hant": @"可以繼續",
            @"en": @"You can proceed",
            @"ja": @"そのまま進めます",
        },
        @"jit.autopair.blocker.systemTooOld.action": @{
            @"zh-Hans": @"改用导入配对文件或外部工具",
            @"zh-Hant": @"改用匯入配對檔或外部工具",
            @"en": @"Use an imported pairing file or an external tool",
            @"ja": @"ペアリングファイルの取り込みか外部ツールを使います",
        },
        @"jit.autopair.blocker.developerMode.action": @{
            @"zh-Hans": @"在「设置 → 隐私与安全性 → 开发者模式」打开并重启设备",
            @"zh-Hant": @"在「設定 → 隱私權與安全性 → 開發者模式」開啟並重新啟動裝置",
            @"en": @"Enable it in Settings → Privacy & Security → Developer Mode, then reboot",
            @"ja": @"「設定 → プライバシーとセキュリティ → デベロッパモード」で有効化し、再起動します",
        },
        @"jit.autopair.blocker.localNetwork.action": @{
            @"zh-Hans": @"在「设置 → Air2 → 本地网络」允许访问",
            @"zh-Hant": @"在「設定 → Air2 → 本機網路」允許存取",
            @"en": @"Allow it in Settings → Air2 → Local Network",
            @"ja": @"「設定 → Air2 → ローカルネットワーク」で許可します",
        },
        @"jit.autopair.blocker.getTaskAllow.action": @{
            @"zh-Hans": @"改用带 get-task-allow 的签名（免费/开发签名默认具备）后重装",
            @"zh-Hant": @"改用含 get-task-allow 的簽章（免費/開發簽章預設具備）後重新安裝",
            @"en": @"Reinstall with a signature that has get-task-allow (free/dev signing has it by default)",
            @"ja": @"get-task-allow を含む署名（無料/開発署名は既定で付与）で入れ直します",
        },
        @"jit.autopair.blocker.ddi.action": @{
            @"zh-Hans": @"连接网络后重试，让系统获取 Developer Disk Image",
            @"zh-Hant": @"連接網路後重試，讓系統取得 Developer Disk Image",
            @"en": @"Go online and retry so the system can fetch the Developer Disk Image",
            @"ja": @"ネット接続後に再試行し、Developer Disk Image を取得させます",
        },
        @"jit.autopair.blocker.precondUnknown.action": @{
            @"zh-Hans": @"本版本尚未接入前置探测；可先用导入配对文件",
            @"zh-Hant": @"本版本尚未接入前置探測；可先用匯入配對檔",
            @"en": @"This build has no precondition probe yet; import a pairing file for now",
            @"ja": @"この版には前提検出がまだありません。当面はペアリングファイルを取り込みます",
        },
        @"jit.autopair.blocker.engineUnavailable.action": @{
            @"zh-Hans": @"自动配对属下一阶段；本机请先用「导入配对文件」或外部工具",
            @"zh-Hant": @"自動配對屬下一階段；本機請先用「匯入配對檔」或外部工具",
            @"en": @"Auto pairing lands next phase; for now use an imported pairing file or an external tool",
            @"ja": @"自動ペアリングは次段階です。当面はペアリングファイルの取り込みか外部ツールを使います",
        },
        @"jit.autopair.blocker.discovery.action": @{
            @"zh-Hans": @"确认本地网络权限已开，并让设备与自身处在同一网络后重试",
            @"zh-Hant": @"確認本機網路權限已開，並讓裝置與自身處於同一網路後重試",
            @"en": @"Make sure Local Network is allowed and the device is on the same network, then retry",
            @"ja": @"ローカルネットワークの許可と同じネットワーク上にいることを確認して再試行します",
        },
        @"jit.autopair.blocker.rsd.action": @{
            @"zh-Hans": @"确认 Developer Mode 已开并重试；仍失败请改用导入配对文件",
            @"zh-Hant": @"確認 Developer Mode 已開並重試；仍失敗請改用匯入配對檔",
            @"en": @"Verify Developer Mode is on and retry; if it still fails, import a pairing file",
            @"ja": @"Developer Mode が有効か確認して再試行します。なお失敗する場合はペアリングファイルを取り込みます",
        },
        @"jit.autopair.blocker.pairVerify.action": @{
            @"zh-Hans": @"删除旧的配对材料后重试；仍失败请改用导入配对文件",
            @"zh-Hant": @"刪除舊的配對材料後重試；仍失敗請改用匯入配對檔",
            @"en": @"Remove stale pairing material and retry; if it still fails, import a pairing file",
            @"ja": @"古いペアリング材料を削除して再試行します。なお失敗する場合はペアリングファイルを取り込みます",
        },
        @"jit.autopair.blocker.tunnel.action": @{
            @"zh-Hans": @"确认本地网络权限与 Developer Mode 后重试",
            @"zh-Hant": @"確認本機網路權限與 Developer Mode 後重試",
            @"en": @"Verify Local Network permission and Developer Mode, then retry",
            @"ja": @"ローカルネットワーク権限と Developer Mode を確認して再試行します",
        },
        @"jit.autopair.blocker.write.action": @{
            @"zh-Hans": @"确认设备存储空间充足后重试",
            @"zh-Hant": @"確認裝置儲存空間充足後重試",
            @"en": @"Make sure there is enough storage, then retry",
            @"ja": @"ストレージの空きを確認して再試行します",
        },
        @"jit.autopair.blocker.stale.action": @{
            @"zh-Hans": @"重新自动配对，或重新导入一份配对文件",
            @"zh-Hant": @"重新自動配對，或重新匯入一份配對檔",
            @"en": @"Auto pair again, or import a fresh pairing file",
            @"ja": @"自動ペアリングをやり直すか、新しいファイルを取り込みます",
        },
        // 提示
        @"jit.toast.autopairing": @{
            @"zh-Hans": @"正在自动配对…",
            @"zh-Hant": @"正在自動配對…",
            @"en": @"Auto pairing…",
            @"ja": @"自動ペアリング中…",
        },
        @"jit.toast.autopairOK": @{
            @"zh-Hans": @"自动配对完成",
            @"zh-Hant": @"自動配對完成",
            @"en": @"Auto pairing completed",
            @"ja": @"自動ペアリングが完了しました",
        },
        @"jit.toast.autopairFail": @{
            @"zh-Hans": @"自动配对失败",
            @"zh-Hant": @"自動配對失敗",
            @"en": @"Auto pairing failed",
            @"ja": @"自動ペアリングに失敗しました",
        },

        // ---------------- [JIT-DDI-1] DDI（Developer Disk Image）----------------
        @"jit.row.ddi": @{
            @"zh-Hans": @"DDI（Developer Disk Image）",
            @"zh-Hant": @"DDI（Developer Disk Image）",
            @"en": @"DDI (Developer Disk Image)",
            @"ja": @"DDI（Developer Disk Image）",
        },
        @"jit.row.ddiImport": @{
            @"zh-Hans": @"导入 DDI 镜像",
            @"zh-Hant": @"匯入 DDI 映像",
            @"en": @"Import DDI image",
            @"ja": @"DDI イメージを取り込む",
        },
        @"jit.row.ddiImport.needFile": @{
            @"zh-Hans": @"选择 DeveloperDiskImage.dmg，本机校验（不联网）",
            @"zh-Hant": @"選擇 DeveloperDiskImage.dmg，本機校驗（不連網）",
            @"en": @"Pick DeveloperDiskImage.dmg; validated on device (no network)",
            @"ja": @"DeveloperDiskImage.dmg を選択（端末内で検証・通信なし）",
        },
        @"jit.row.ddiFetch": @{
            @"zh-Hans": @"联网取 DDI",
            @"zh-Hant": @"連網取 DDI",
            @"en": @"Fetch DDI online",
            @"ja": @"DDI をオンライン取得",
        },
        @"jit.row.ddiFetch.detail": @{
            @"zh-Hans": @"默认关。开启后向 Apple 官方服务请求个性化 DDI——这是访问 Apple 官方服务，不是「上云」",
            @"zh-Hant": @"預設關。開啟後向 Apple 官方服務請求個人化 DDI——這是存取 Apple 官方服務，不是「上雲」",
            @"en": @"Off by default. When on, requests a personalized DDI from Apple's official service — that is accessing Apple's service, not \"going to the cloud\"",
            @"ja": @"既定はオフ。オンにすると Apple 公式サービスへ個別化 DDI を要求します（Apple 公式サービスへのアクセスであり「クラウド化」ではありません）",
        },
        // 判定短文案
        @"jit.ddi.status.present": @{
            @"zh-Hans": @"已就位",
            @"zh-Hant": @"已就位",
            @"en": @"In place",
            @"ja": @"準備済み",
        },
        @"jit.ddi.status.missing": @{
            @"zh-Hans": @"缺失",
            @"zh-Hant": @"缺失",
            @"en": @"Missing",
            @"ja": @"未検出",
        },
        @"jit.ddi.status.versionMismatch": @{
            @"zh-Hans": @"版本不匹配",
            @"zh-Hant": @"版本不相符",
            @"en": @"Version mismatch",
            @"ja": @"バージョン不一致",
        },
        @"jit.ddi.status.stale": @{
            @"zh-Hans": @"已过期",
            @"zh-Hant": @"已過期",
            @"en": @"Stale",
            @"ja": @"期限切れ",
        },
        @"jit.ddi.status.unknown": @{
            @"zh-Hans": @"无法确认",
            @"zh-Hant": @"無法確認",
            @"en": @"Unconfirmed",
            @"ja": @"確認できません",
        },
        // 判定原因
        @"jit.ddi.verdict.present.reason": @{
            @"zh-Hans": @"本地已有可用的 DDI 镜像（版本匹配且未过期）",
            @"zh-Hant": @"本機已有可用的 DDI 映像（版本相符且未過期）",
            @"en": @"A usable local DDI image is present (version-matched and fresh)",
            @"ja": @"利用可能な DDI イメージが本機にあります（バージョン一致・期限内）",
        },
        @"jit.ddi.verdict.missing.reason": @{
            @"zh-Hans": @"本地没有可用的 DDI 镜像",
            @"zh-Hant": @"本機沒有可用的 DDI 映像",
            @"en": @"No usable local DDI image",
            @"ja": @"本機に利用可能な DDI イメージがありません",
        },
        @"jit.ddi.verdict.versionMismatch.reason": @{
            @"zh-Hans": @"本地 DDI 与当前系统版本/构建号不一致",
            @"zh-Hant": @"本機 DDI 與目前系統版本/組建號不相符",
            @"en": @"The local DDI does not match the current OS version/build",
            @"ja": @"本機 DDI が現在のシステムのバージョン/ビルドと一致しません",
        },
        @"jit.ddi.verdict.stale.reason": @{
            @"zh-Hans": @"本地 DDI 镜像超出新鲜度窗口（超过 7 天）",
            @"zh-Hant": @"本機 DDI 映像超出新鮮度視窗（超過 7 天）",
            @"en": @"The local DDI image is beyond the freshness window (over 7 days)",
            @"ja": @"本機 DDI イメージが鮮度ウィンドウ（7 日）を超えています",
        },
        @"jit.ddi.verdict.unknown.reason": @{
            @"zh-Hans": @"DDI 状态无法确认（探测未接线 / 镜像未声明版本 / 目录不可读）",
            @"zh-Hant": @"DDI 狀態無法確認（探測未接線 / 映像未宣告版本 / 目錄不可讀）",
            @"en": @"DDI state cannot be confirmed (probe not wired / image declares no version / directory unreadable)",
            @"ja": @"DDI の状態を確認できません（検出未接続 / イメージにバージョン宣言なし / ディレクトリ読めず）",
        },
        // 下一步动作
        @"jit.ddi.next.ready": @{
            @"zh-Hans": @"DDI 已就位，可继续",
            @"zh-Hant": @"DDI 已就位，可繼續",
            @"en": @"DDI is in place; you can continue",
            @"ja": @"DDI は準備済みです。続行できます",
        },
        @"jit.ddi.next.enableFetch": @{
            @"zh-Hans": @"本地没有 DDI：导入一份，或打开「联网取 DDI」开关",
            @"zh-Hant": @"本機沒有 DDI：匯入一份，或開啟「連網取 DDI」開關",
            @"en": @"No local DDI: import one, or turn on \"Fetch DDI online\"",
            @"ja": @"本機に DDI がありません。取り込むか「DDI をオンライン取得」をオンにします",
        },
        @"jit.ddi.next.fetch": @{
            @"zh-Hans": @"本地没有 DDI：可向 Apple 官方服务请求（需联网）",
            @"zh-Hant": @"本機沒有 DDI：可向 Apple 官方服務請求（需連網）",
            @"en": @"No local DDI: you can request one from Apple's official service (needs network)",
            @"ja": @"本機に DDI がありません。Apple 公式サービスへ要求できます（通信が必要）",
        },
        @"jit.ddi.next.reimport": @{
            @"zh-Hans": @"重新导入一份与当前系统匹配的 DDI",
            @"zh-Hant": @"重新匯入一份與目前系統相符的 DDI",
            @"en": @"Re-import a DDI matching the current OS",
            @"ja": @"現在のシステムに一致する DDI を取り込み直します",
        },
        @"jit.ddi.next.unconfirmed": @{
            @"zh-Hans": @"无法确认：查看日志取证后再决定",
            @"zh-Hant": @"無法確認：查看日誌取證後再決定",
            @"en": @"Unconfirmed: check the log evidence first",
            @"ja": @"確認できません。まずログの証跡を確認します",
        },
        // 机制阻塞（联网取 / 挂载）
        @"jit.ddi.fetch.disabled.reason": @{
            @"zh-Hans": @"「联网取 DDI」当前是关闭的",
            @"zh-Hant": @"「連網取 DDI」目前是關閉的",
            @"en": @"\"Fetch DDI online\" is currently off",
            @"ja": @"「DDI をオンライン取得」は現在オフです",
        },
        @"jit.ddi.fetch.disabled.action": @{
            @"zh-Hans": @"打开开关后重试（这是访问 Apple 官方服务，不是「上云」）",
            @"zh-Hant": @"開啟開關後重試（這是存取 Apple 官方服務，不是「上雲」）",
            @"en": @"Turn it on and retry (this accesses Apple's official service, not \"the cloud\")",
            @"ja": @"オンにして再試行します（Apple 公式サービスへのアクセスであり「クラウド化」ではありません）",
        },
        @"jit.ddi.fetch.unsupported.reason": @{
            @"zh-Hans": @"联网取 DDI 尚不可用（个性化机制未接入 / 缺设备标识）",
            @"zh-Hant": @"連網取 DDI 尚不可用（個人化機制未接線 / 缺裝置識別）",
            @"en": @"Online DDI fetch is not available yet (personalization not wired / missing device identifier)",
            @"ja": @"DDI のオンライン取得は未対応です（個別化の未接続 / デバイス識別子なし）",
        },
        @"jit.ddi.fetch.unsupported.action": @{
            @"zh-Hans": @"先手动导入 DDI 镜像；机制落地见下一阶段",
            @"zh-Hant": @"先手動匯入 DDI 映像；機制落地見下一階段",
            @"en": @"Import a DDI image manually for now; the mechanism lands next phase",
            @"ja": @"当面は手動で DDI イメージを取り込みます（機構は次段階）",
        },
        @"jit.ddi.mount.unavailable.reason": @{
            @"zh-Hans": @"挂载 DDI 当前不可用（需 image_mounter 服务与相应特权）",
            @"zh-Hant": @"掛載 DDI 目前不可用（需 image_mounter 服務與相應特權）",
            @"en": @"Mounting the DDI is unavailable (needs the image_mounter service and privileges)",
            @"ja": @"DDI のマウントは利用できません（image_mounter サービスと権限が必要）",
        },
        @"jit.ddi.mount.unavailable.action": @{
            @"zh-Hans": @"确认 Developer Mode 与网络后重试；仍不可用请附日志取证",
            @"zh-Hant": @"確認 Developer Mode 與網路後重試；仍不可用請附日誌取證",
            @"en": @"Verify Developer Mode and network, then retry; if it still fails, attach the log evidence",
            @"ja": @"Developer Mode とネットワークを確認して再試行します。それでも不可ならログの証跡を添えてください",
        },
        // 提示
        @"jit.toast.ddiImporting": @{
            @"zh-Hans": @"正在导入 DDI…",
            @"zh-Hant": @"正在匯入 DDI…",
            @"en": @"Importing DDI…",
            @"ja": @"DDI を取り込み中…",
        },
        @"jit.toast.ddiImportOK": @{
            @"zh-Hans": @"DDI 已导入",
            @"zh-Hant": @"DDI 已匯入",
            @"en": @"DDI imported",
            @"ja": @"DDI を取り込みました",
        },
        @"jit.toast.ddiImportFail": @{
            @"zh-Hans": @"DDI 导入失败",
            @"zh-Hant": @"DDI 匯入失敗",
            @"en": @"DDI import failed",
            @"ja": @"DDI の取り込みに失敗しました",
        },
        @"jit.toast.ddiFetching": @{
            @"zh-Hans": @"正在向 Apple 官方服务请求 DDI…",
            @"zh-Hant": @"正在向 Apple 官方服務請求 DDI…",
            @"en": @"Requesting DDI from Apple's official service…",
            @"ja": @"Apple 公式サービスへ DDI を要求中…",
        },
        @"jit.toast.ddiFetchFail": @{
            @"zh-Hans": @"联网取 DDI 失败",
            @"zh-Hant": @"連網取 DDI 失敗",
            @"en": @"Online DDI fetch failed",
            @"ja": @"DDI のオンライン取得に失敗しました",
        },
        @"jit.toast.ddiMountOK": @{
            @"zh-Hans": @"DDI 已挂载",
            @"zh-Hant": @"DDI 已掛載",
            @"en": @"DDI mounted",
            @"ja": @"DDI をマウントしました",
        },
        @"jit.toast.ddiFetchOff": @{
            @"zh-Hans": @"「联网取 DDI」是关着的：先打开开关",
            @"zh-Hant": @"「連網取 DDI」是關著的：先開啟開關",
            @"en": @"\"Fetch DDI online\" is off: turn it on first",
            @"ja": @"「DDI をオンライン取得」はオフです。先にオンにしてください",
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
