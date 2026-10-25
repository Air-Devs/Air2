# 设备内配对（第一阶段）—— 入口 + TLS-PSK 隧道

> 分支 `feat/ondevice-pair`，基线 `feat/all-synced@35edf93`。
> 本文只记**做了什么 / 凭什么说通了 / 还没验什么**；协议规格见 `docs/STIKPAIR-SPEC.md`，
> 许可与选型背景见 `docs/STIKPAIR-EVAL.md`。

---

## 1. 交付范围（用户拍板的第一阶段）

| # | 交付 | 落点 |
|---|---|---|
| 一 | 设置 › 诊断 下新增「设备内配对」入口（调试开关控制显示），打开后能发起配对并显示 6 位码与状态 | `Air2/UI/Screens/Settings/A2OnDevicePairingSettings.{h,m}`、`A2OnDevicePairingViewController.{h,m}`、`A2SettingsViewController.m`（1 行装配 + 1 个通知钩子） |
| 二 | 补上「TLS-PSK 隧道」那一环（选型 + 根因 + 证据 + 回环自检） | `Natives/Support/a2_tlspsk_mbedtls.m`（修根因）、`a2_tlspsk_tunnel.{h,m}`（握手结果）、`a2_tlspsk_selftest.{h,m}`（新）、`Air2/Bridge/A2TLSPskTunnelBridge.{h,m}`（新，跨层入口） |
| — | 离线真握手单测 | `tests/Natives/tlspsk_tunnel_tests.m` + `run_tlspsk_tunnel_tests.py`（新） |

★没有改的东西★：下载 / 控件 / 渲染 / 启动链一行没动；`A2JITPairingCodeSession` 的语义
（生成码、持久化、`[A2-PAIRPIN]` 判据行）也没改 —— 入口只是它的**读侧**。

---

## 2. 选型：为什么走「纯自研 + 随仓 mbedTLS」，不引 idevice

结论：**选 (a)**。理由是三条实测事实，不是偏好：

| 判据 | (a) 自研 + mbedTLS 3.6.2（随仓） | (b) 引 idevice（MIT，Rust staticlib） |
|---|---|---|
| 依赖/许可 | 已在仓（`Libraries/ThirdParty/mbedtls`，Apache-2.0，`docs/DEPENDENCIES.md` 已登记），**零新依赖** | 新增 167 个 crate + `rustls` + `aws-lc`（含 C++，需 `-lc++`）+ `cmake`；要改 `gen_xcodeproj.py` 加 `.a` 链接 |
| 构建风险 | 现在就能编（本轮真编译出包验证） | 构建机需 Rust ≥1.85 + 两个 iOS target + cmake；任一步缺失就出不了包 |
| 能否自证 | **能**：`tests/Natives/tlspsk_tunnel_tests.py` 在本机回环真握手，实测 `0x00AF` / `TLSv1.2` / 帧回显 | 也要真机才能验「设备是否接受」；它给的是**另一个实现**（oracle），不是证据本身 |
| 剩余不确定项 | PSK identity 语义（见 §3.2） | 同样存在，且无法用 mbedTLS 侧消掉 |

补充：本轮**没有必要**引 Rust 也拿到了 idevice 的关键事实 —— 它的 TLS-PSK 客户端
`src/remote_pairing/tls_psk.rs:444` 明写 `ClientKeyExchange (empty PSK identity)`，
即「设备侧接受的 identity 是**空串**」。这条事实直接决定了 §3 的修法。

---

## 3. 「未打通」的真实根因（本单修的就是它）

`a2_rppairing_rsd.h:19-22` 原来写「公开 Security.framework 给不出 PSK 套件」——那是对
`SecProtocolOptions` 的判断，**不等于**「我们打不通」。后来补的 mbedTLS 后端
（`5bc23a9`）已经在仓里，但它有一个**必然失败**的调用：

```objc
// 修前（a2_tlspsk_mbedtls.m）
NSData *idData = [(identity ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
mbedtls_ssl_conf_psk(&_conf, psk.bytes, psk.length, idData.bytes, idData.length);
//                                      identity 为空 ⇒ length = 0
```

### 3.1 实测（macOS，clang + `Libraries/ThirdParty/mbedtls/lib-macos/libmbedcrypto.a`）

| 探针 | 结果 | 含义 |
|---|---|---|
| `mbedtls_ssl_conf_psk(..., identity, 0)` | `rc = -28928`（= `MBEDTLS_ERR_SSL_BAD_INPUT_DATA`, `-0x7100`） | **空 identity 被 API 直接拒绝** ⇒ 原实现永远在第 1 步失败 |
| 直写 `mbedtls_ssl_config` 私有字段（`psk_identity_len = 0`），对 mbedTLS 服务端 | 握手失败，服务端 PSK 回调从未被调用 | 客户端**没有把 PSK 套件放进 ClientHello** |
| 同上，对 `openssl s_server -cipher PSK-AES256-CBC-SHA384 -tls1_2 -nocert` | 服务端日志 `no shared cipher` | 同上，坐实「mbedTLS 表达不出空 identity」 |
| identity = `"a2-tlspsk"`（非空），对 OpenSSL | **`0x00AF` / `TLSv1.2` / 收到回显** | 套件白名单与 TLS 栈本身**是对的** |

### 3.2 因此现在的实现（`a2_tlspsk_mbedtls.m`）

1. **identity 为空 ⇒ 用占位 `"a2-tlspsk"`**，并打一条 `[A2-TLSPK]` 日志如实说明
   「mbedTLS 无法表达空 identity；设备是否忽略 identity 需真机验」——
   ★不谎称「按规格发了空 identity」★。
2. **握手后断言协商结果**：版本必须是 `TLSv1.2`，套件必须 ∈ `{0x00AF, 0x008C}`，
   否则断开并如实失败（不继续用别的套件跑下去）。
3. 握手结果（版本/套件）通过门面的 `negotiatedSummary` 对外可读，UI 与日志共用同一份事实。
4. 门面：`sendFrame`/`receiveFrame` 失败即把状态置 `Failed`（原来会一直停在 `Ready`）。

---

## 4. 怎么自证（不需要真机的那部分）

```sh
# 在 Mac 上（仓根）
python3 tests/Natives/run_tlspsk_tunnel_tests.py
```

它做的事（**真编译 + 真握手**，不是字符串扫描）：

1. 用随仓 mbedTLS 在 `127.0.0.1:0` 起 PSK 服务端（TLS1.2、套件白名单同设备要求）；
2. 用**生产路径** `A2TLSPskTunnel` → mbedTLS 后端连上去；
3. 走完 ClientHello→Finished，核对套件/版本，再用隧道帧（4B 大端长度 + 载荷）回显一次；
4. 另外断言：默认关、无后端、公网拒绝（不上云）、自检结束后开关复原。

同一个自检在 App 内也有入口（设置 › 诊断 › 设备内配对（调试） › TLS-PSK 隧道自检），
真机上可直接点，结论进 `lastlog.txt` 的 `[A2-TLSPK-SELFTEST]` 行。

---

## 5. 还没验证的部分（必须真机 / 后续单）

1. **设备是否接受非空 PSK identity**（最关键的未知）。设备侧 Apple TLS 的 identity 语义
   只能真机验；若被拒，修法是把 `a2_tlspsk_mbedtls.m` 的后端换成一个**能发空 identity** 的
   实现（自写 TLS 1.2 PSK 的 ClientKeyExchange 段，或引 idevice 的 Rust 实现）——
   门面 `A2TLSPskTunnel` 的 `registerBackend:` 就是为这个留的口子，调用方零改动。
2. **整条隧道到 RSD 的联通**：本单只到「TLS-PSK 隧道握手 + 帧收发」；`RSDCheckin`、
   `createListener` 拿端口、以及 PSK 真值（pair-verify 的 shared secret）**都没有接**。
   现在没有任何调用方把 pair-verify 的 shared secret 交给隧道 —— 属主线业务逻辑，未动。
3. **设备内配对的 mDNS 广告 + responder 传输**：仍是 `A2JITPairingCodeSession.h:20-28`
   记的「唯一改点」（起 `NWListener(_remotepairing-pairable-host._tcp)` + 把设备发起的
   pairingData TLV 交给 `A2RPPairSetupSession`）。本轮入口只到「生成码 + 显示状态 + 判据行」。
4. **iOS 27 设置里的「与 <名字> 配对」是否出现**、输码后 M1–M6 是否走完、产出的 plist
   能否被设备在后续 pair-verify 中认可 —— 全部需要 iOS 27 真机（`docs/STIKPAIR-SPEC.md` §9 的 6–9 条）。
5. **后台保活**：`BGContinuedProcessingTask` 需 iOS 26+ 且本仓 deployment target 是 14.0，
   入口页目前不申请后台任务（用户切到系统设置期间被挂起是已知风险，见规格 §5）。

---

## 6. 判据行速查

| 行 | 出处 | 含义 |
|---|---|---|
| `[A2-PAIRPIN] state=… host=… code=…` | `A2JITPairingCodeSession` | 配对码会话状态（本轮未改） |
| `[A2-PAIRUI] …` | `A2OnDevicePairingViewController` / `…Settings` | 入口页刷新与开关切换 |
| `[A2-TLSPK] 已注册 mbedTLS 后端…` | `a2_tlspsk_mbedtls.m` | 后端就绪 |
| `[A2-TLSPK] identity 为空 ⇒ 用占位 identity…` | `a2_tlspsk_mbedtls.m` | identity 回退（如实） |
| `[A2-TLSPK] 握手结果 version=… suite=…` | `a2_tlspsk_mbedtls.m` | ★真协商结果★（不是配置值） |
| `[A2-TLSPK-SELFTEST] passed=… suite=… version=… echo=…` | `a2_tlspsk_selftest.m` | 回环自检结论 |
