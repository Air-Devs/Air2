# StikPair 行为规格书 —— 「设备内生成 pairing 文件」

> **性质**：只读调研产出的**行为规格**（协议事实 / 参数 / 数据结构 / 文件格式 / 失败处理），
> **不含任何上游源码**，供 Air2 自研实现照此落地。
> **依据对象**：`StikDebug/StikPair` @ `d9661c5`（tag `v1.2.0`，SwiftUI App）+ 其依赖
> `jkcoxson/idevice`（MIT）。**StikPair 自身许可是自定义「MIT, Non-Commercial」，不可 vendor**
> ——许可与可行性结论见 `docs/STIKPAIR-EVAL.md`。
> **引用格式**：`文件:行`，两个来源分别标注 `[SP]` = StikPair、`[IDV]` = idevice（`0.1.68` / pin `7bd551c`）。
> **范围**：只讲「怎么在设备内把 pair 文件拿到手」。**不含**隧道、不含 JIT 开启、不含配对文件之后的事。

---

## 0. 一句话结论

iOS 27 起，**设备可以主动配对到我们**：我们在本机起一个 TCP 监听 + 以
`_remotepairing-pairable-host._tcp` 广播出去（TXT 带 `authTag`），设备在
**设置 › 隐私与安全性 › 开发者模式 › 与 <名字> 配对** 里连进来；随后由**设备发起**、
我们在 **accessory/responder** 角色上跑完 `pair-setup` 的 **PS-Msg01..06**（SRP-3072/SHA-512），
我们生成的 6 位码由用户输到设备上；成功的产物是一份 **XML plist 配对文件**
（`public_key` / `private_key` / `identifier` / `alt_irk`）。全程只需**本地网络**权限，
**不需要 multicast entitlement**（这正是 StikPair 把 mDNS 广告从 Rust 侧移到系统侧的原因，
`[SP] rust/src/lib.rs:1-6`）。

---

## 1. 角色与两条不同的链路（先分清，别混）

| 链路 | 谁发起 | 谁连谁 | 我们扮演 | `originatedBy` | 线上协议版本 | 适用 |
|---|---|---|---|---|---|---|
| **A. 设备发起**（pairable host） | 设备 | 设备 → 我们 | **accessory / responder** | `"device"` | **26** | **iOS 27+**（唯一设备内路径） |
| B. 主机发起（Host／Apple TV） | 我们 | 我们 → 设备 | host / controller | `"host"` | **19** | tvOS 11+ 手动配对；iOS ≤26.x 需已有配对文件 |

- 版本号是**两条链路各自的常量**，不可互换：pairable host 用 26（`[IDV] responder.rs:115` 默认值、
  `:222-225` 写进 handshake），host 客户端用 19（`[IDV] mod.rs:43`）。
- 本规格书主体是 **A**；B 只在 §10 与 A 做差异说明。
- A 的会话里**不做 pair-verify**：设备若在 handshake 里请求 `attemptPairVerify=true`，
  StikPair/idevice 一律**报错终止**（`[IDV] responder.rs:191-201`）——这是刻意的，不是遗漏。

---

## 2. 端到端步骤（A：设备发起）

编号与 Air2 侧 `A2JITAutoPairingStep`（`Air2/Player/A2JITAutoPairing.h:62-71`）对齐，便于落点分类。

### 步骤 ① 绑定监听（Discovery 前置）
1. `bind(0.0.0.0, port=0)` —— **端口 0 = 让系统选**，再由 `local_addr()` 取回真实端口
   （`[SP] lib.rs:260-269`）。StikPair 传的 bind 是 `"0.0.0.0"`、port `0`（`[SP] PairingController.swift:41,242-243`）。
2. 绑定**必须先于广告**：TXT 里要报真实端口。

### 步骤 ② 生成本机身份（每次配对都重新生成）
| 对象 | 生成规则 | 出处 |
|---|---|---|
| 长期密钥对 | **Ed25519**：私钥 32 B（种子），公钥 32 B | `[IDV] rp_pairing_file.rs:44-58` |
| `identifier` | **UUIDv3(NAMESPACE_DNS, hostName)** 的字符串形式 | 同上 `:49-50` |
| `altIRK` | **16 B CSPRNG**（每次新生成；旧的配对记录随之作废） | `[IDV] responder.rs:72-81` |
| `name` / `model` | 用户可读名 + **Mac 机型标识**（默认 `Mac17,7`），设备把它当「电脑」显示 | `[SP] PairingController.swift:42,240`；`[IDV] responder.rs:40-53` |
| `udid` / `identifier`(peerDeviceInfo) | 允许空串，不影响配对成功 | `[IDV] responder.rs:53-56` |

**注意（StikPair 的已知缺口，我们不要照抄）**：`alt_irk` 只是本次会话的身份密钥，
上下游注释都要求**持久化**（否则已配对设备认不出我们，`[IDV] responder.rs:59-66`），
而 StikPair 只把它以 hex 返回给 Swift、**没有落盘**（`[SP] lib.rs:271-272,311`）。

### 步骤 ③ 广告（交给系统 mDNS，不要自己发组播）
- 服务类型：`_remotepairing-pairable-host._tcp`（`[IDV] responder.rs:38`；StikPair 用
  `NetService` 发布同一类型，`[SP] PairingController.swift:287-294`）。
- **实例名 = `identifier`**，实例名长度上限 **30 字符**（`[IDV] ffi/src/pairable_host.rs:108` 的
  `set_service_name_len_max(30)`；上游用 `idevice-<identifier 前 8 位>.local.` 作主机名，`:109`）。
- TXT 记录（键 → 值，共 7 条）：

  | 键 | 值 | 说明 |
  |---|---|---|
  | `name` | 显示名 | 用户在设置里看到的「与 <name> 配对」 |
  | `identifier` | 同 ② 的 identifier | 必须与服务实例名、M6 里的 identifier **一致** |
  | `authTag` | base64(6 B) | 见下方算法 |
  | `model` | `Mac17,7` 之类 | |
  | `flags` | `"1"` | |
  | `ver` | `"26"` | = 线上协议版本（pairable host 用 26） |
  | `minVer` | `"17"` | |

  出处：`[IDV] responder.rs:91-105`。
- **`authTag` 算法**（`[IDV] peer_device.rs:129-140`）：
  `SipHash-2-4(k0 = LE(altIRK[0..8]), k1 = LE(altIRK[8..16]), msg = identifier.as_bytes())`
  → 取 8 B **小端**输出的**前 6 字节并逆序**，再 base64。
  **公开测试向量**（`[IDV] peer_device.rs:202-212`，已在 Air2 侧复现：
  `tests/JIT/remotexpc_tests.m:595-599`、`Natives/Support/a2_rppairing_pairable_host.m:427-437`）：

  ```
  altIRK(base64) = Mgp6ZGPzXM2ku9br46vsiw==
  identifier     = 2BE6E510-0325-4365-923E-B14C6F57DB3A
  authTag(base64)= kXjlTr2l
  ```
- **iOS 侧权限事实**：自建 mDNS 组播需 multicast entitlement（签名拿不到），
  系统 `NetService`/`NWListener` 只要**本地网络**权限即可（`[SP] lib.rs:1-6`；
  `[SP] Info.plist:38-46`）。Air2 已用 `NWListener` 走同一思路
  （`Natives/Support/a2_rppairing_pairable_host.h:12-30`）。

### 步骤 ④ 接受一条连接
`accept()` 一条 TCP 连接即可（`[SP] lib.rs:282-285`）；**不校验对端**（同机回环场景对端就是本机）。
拿到连接后立刻包成 rppairing socket，并**以 device/accessory 角色**（`originatedBy:"device"`）
构造 responder（`[SP] lib.rs:287-288`；`[IDV] socket.rs:58-67`）。

### 步骤 ⑤ handshake（对端 → 我们 → 对端）
1. **收**一条 `plain` 消息，从中取 `request._0.handshake._0`（`[IDV] responder.rs:179-189`）。
2. 若 `hostOptions.attemptPairVerify == true` ⇒ **终止**（见 §1）。
3. **回**一条 `response`：

```jsonc
{ "response": {
    "forRequestIdentifier": 0,
    "_1": { "handshake": { "_0": {
        "wireProtocolVersion": 26,
        "minimumSupportedWireProtocolVersion": 8,
        "deviceOptions": {
          "allowsPairSetup": true,
          "allowsPinlessPairing": false,
          "allowsIncomingTunnelConnections": false,
          "allowsUpgradeOfLockdownPairings": false,
          "allowsSharingSensitiveInfo": false
        },
        "peerDeviceInfo": {
          "udid": "<本机 udid，可空>",
          "deviceKVSIncludesSensitiveInfo": false,
          "identifier": "<本机 identifier，可空>",
          "name": "<name>", "model": "<model>"
        }
    } } }
} }
```
（结构见 `[IDV] responder.rs:203-238`。）

### 步骤 ⑥ pair-setup = PS-Msg01..06（**先收后发**，因为发起方是设备）
TLV 编码：`type(1B) + len(1B) + data`；**长度上限 255**，超过就拆成同类型的连续多段
（`[IDV] tlv.rs:65-98`、`responder.rs:510-517`）。会话传输方式见 §3。

| 消息 | 方向 | 内容 | 我们的动作 | 依据 |
|---|---|---|---|---|
| **M1** | 设备→我们 | `State=1`（可选 `Method`） | 只校验 `State==1` | `[IDV] responder.rs:253-255` |
| **M2** | 我们→设备 | `State=2` + `Salt`(16 B) + `PublicKey`(B，384 B，多段) | 生成 salt、**6 位数字码**（`%06d`，0–999999）；`verifier = SRP(SHA-512, G_3072, user="Pair-Setup", pin, salt)`；服务端公钥 **B**（由 `idevice_srp` 按 SRP-6a 计算），**循环重试直到 B 恰 384 B**；**先把码交给 UI**，再发 M2 | `[IDV] responder.rs:258-291` |
| **M3** | 设备→我们 | `State=3` + `PublicKey`(A) + `Proof` | 校验客户端 proof；**失败** ⇒ 回 `State=4` + `ErrorResponse=2`（鉴权失败）后终止 | `:293-329` |
| **M4** | 我们→设备 | `State=4` + `Proof`（服务端 proof） | 成功后 `session_key = verifier.key()` | `:331-345` |
| — | — | 派生会话加密密钥 | `HKDF-SHA512(salt="Pair-Setup-Encrypt-Salt", ikm=session_key, info="Pair-Setup-Encrypt-Info") → 32 B` | `:348-354` |
| **M5** | 设备→我们 | `State=5` + `EncryptedData` | 用 **ChaCha20-Poly1305** 解密，**nonce = 4×0x00 ‖ `"PS-Msg05"`**；解出 TLV，取 `Info`（**OPACK** 编码的字典）→ 解析对端身份 | `:356-378` |
| **M6** | 我们→设备 | `State=6` + `EncryptedData` | 组我方身份 TLV（见下）→ 用 **nonce = 4×0x00 ‖ `"PS-Msg06"`** 加密后发送 | `:380-406` |

**M6 的我方身份 TLV**（`[IDV] responder.rs:411-459`）：

| TLV 类型 | 值 |
|---|---|
| `Identifier (0x01)` | 我方 `identifier`（ASCII） |
| `PublicKey (0x03)` | 我方 Ed25519 **长期公钥**（32 B） |
| `Signature (0x0a)` | **Ed25519 签名 64 B**，签名串 = `AccessoryX(32) ‖ identifier ‖ LTPK(32)`；`AccessoryX = HKDF-SHA512(salt="Pair-Setup-Accessory-Sign-Salt", ikm=session_key, info="Pair-Setup-Accessory-Sign-Info")` |
| `Info (0x11)` | OPACK 字典：`altIRK`(16 B)、`btAddr`、`mac`(6 B)、`remotepairing_serial_number`、`accountID`(=identifier)、`remotepairing_udid`、`model`、`name` |

**M5 里对端 `Info` 字典的必备键**（缺任一即失败，`[IDV] peer_device.rs:47-63`）：
`accountID`(str)、`altIRK`(data, **必须 16 B**)、`model`(str)、`name`(str)、`remotepairing_udid`(str)。

### 步骤 ⑦ 落盘
1. `pairing_file.alt_irk = 对端 altIRK`（16 B，来自 M5；`[IDV] responder.rs:400-402`）。
2. 写文件：StikPair 写 `<App Documents>/rp_pairing_file.plist`
   （`[SP] PairingController.swift:333-336`，调用点在 `[SP] lib.rs:301-304`）。
3. 另行回传**我方** `altIRK`（hex 字符串）给上层，用于下次重新广告被设备认出
   （`[SP] lib.rs:306-312`）——**StikPair 没持久化，我们必须持久化**。

### 步骤 ⑧ 收尾（App 层，非协议）
- 成功 → 本地通知提示「回到 App 导出配对文件」（`[SP] PairingController.swift:318-322`）；
  UI 给 `ShareLink` 导出（`[SP] ContentView.swift:169-175`）。
- 失败 → 按原因分文案，不吞错（`[SP] PairingController.swift:142-164`）。
- **StikPair 到此为止**：不建隧道、不连 RSD、不碰 JIT。`host_alt_irk_hex` 之外无任何后续动作。

---

## 3. 会话传输层（rppairing over TCP）

| 项 | 规格 | 依据 |
|---|---|---|
| 帧 | `magic "RPPairing"`(9 B) + **`length` u16 大端** + JSON 体 | `[IDV] mod.rs:42`、`socket.rs:69-80` |
| 发送序列号 | 每条我们发出的消息 `sequenceNumber` 自 0 起 **+1** | `[IDV] responder.rs:462-466` |
| 明文信封 | `{"message":{"plain":{"_0":<对象>}},"originatedBy":"device","sequenceNumber":n}` | `socket.rs:84-99` |
| 密文信封 | `{"message":{"streamEncrypted":{"_0":"<base64>"}},…}`（本链路用不到，A 不加密控制通道） | `socket.rs:101-116` |
| 二进制字段 | 该传输上 TLV 字节以 **base64 字符串**承载（RemoteXPC 传输才是 raw data） | `socket.rs:154-164` |
| 配对数据事件 | `{"event":{"_0":{"pairingData":{"_0":{"data":"<b64 TLV>","startNewSession":false,"kind":"setupManualPairing"}}}}} ` | `responder.rs:469-485` |
| 收帧 | 先读满 9 B magic，再读 2 B 长度，再读长度字节；**必须在累积缓冲里按帧切分**（NWConnection 会分片） | `socket.rs:118-152` |

Air2 侧等价实现已存在：`Natives/Support/a2_rppairing.h:44-60`（帧/信封）、
`a2_rppairing_pairsetup.h`（TLV 与 PS 流程）、`a2_remotexpc_session.h`（字节流抽象）。

**TLV 类型表**（只列本流程用到的，全表 `[IDV] tlv.rs:8-40`）：

| 值 | 名称 | 值 | 名称 |
|---|---|---|---|
| `0x00` | Method | `0x05` | EncryptedData |
| `0x01` | Identifier | `0x06` | State |
| `0x02` | Salt | `0x07` | ErrorResponse |
| `0x03` | PublicKey | `0x08` | RetryDelay |
| `0x04` | Proof | `0x0a` | Signature |
| `0x11` | Info | `0xff` | Separator |

---

## 4. 配对文件格式（产物契约）

**XML plist**，顶层字典，4 个键（`[IDV] rp_pairing_file.rs:69-87`）：

| 键 | 类型 | 长度/取值 | 语义 |
|---|---|---|---|
| `public_key` | `<data>` | **32 B** | **我方** Ed25519 长期公钥 |
| `private_key` | `<data>` | **32 B** | **我方** Ed25519 私钥种子（敏感，勿入日志） |
| `identifier` | `<string>` | UUIDv3(DNS, hostName) | 我方身份标识；= 广告实例名 = M6 identifier |
| `alt_irk` | `<data>` | **16 B** | **对端设备**的 altIRK（用于校验设备 `_remotepairing._tcp` 的 `authTag`） |

- 读取侧必须能**同时吃 XML 与二进制 plist**（`from_bytes` 用 `plist::from_bytes`，`:90-147`）。
- Air2 已有解析器与必填字段断言：`Air2/Player/A2PairingFile.m:27-37`
  （`RemotePairing` 格式要求 `identifier`/`public_key`/`private_key`）——
  **注意它目前不要求 `alt_irk`**，而设备发起链路产出的文件**必然带** `alt_irk`；
  若要校验「这是本机生成的、能用于重连的文件」，应把它加入可选字段并在有值时校验 16 B。
- 文件位置：容器内 `Documents/rp_pairing_file.plist`（StikPair 的约定）。
  Air2 的落盘目标由 `A2JITPairingFileStore` 决定，不必照抄这个路径。

---

## 5. 生命周期、权限、后台保活（不做这步真机会失败）

| 事项 | StikPair 的做法（可照抄的行为） | 出处 |
|---|---|---|
| 本地网络权限 | 用一个**一次性 Bonjour 探测**（`_stikpairprobe._tcp` 的 listener + browser 自发现）触发系统弹窗，60 s 超时；未授权即失败并给设置指引 | `[SP] LocalNetworkAuthorization.swift:10-48`、`Info.plist:44-45` |
| Info.plist | `NSLocalNetworkUsageDescription` + `NSBonjourServices` 至少含 `_remotepairing-pairable-host._tcp`（ATV 再加 `_remotepairing-manual-pairing._tcp`） | `[SP] Info.plist:38-46` |
| 后台继续跑 | `BGContinuedProcessingTask`（`BackgroundTasks`），id = `<bundleID>.pairing`，`strategy = .queue`；提交失败或**3 s 内未开始**就退化为前台直跑 | `[SP] PairingController.swift:195-211`、`Info.plist:47-52` |
| 过期处理 | `expirationHandler` ⇒ 停保活 + 失败文案「后台时间用尽，重按一次」 | `:221-228` |
| 额外保活（可选） | 静音音频（`AVAudioEngine` 循环缓冲）/ 后台定位 | `KeepAlive.swift:12-63`、`Info.plist:53-61` |
| 码的可见性 | 大号等宽数字 + 可选本地通知；**用户要切到系统设置去输码**，所以码必须可回看 | `:297-306`、`ContentView.swift:77-90` |
| 用户引导 | 设置 › 隐私与安全性 › 开发者模式 › 「与 <name> 配对」；不出现时「关掉 App 重开」 | `ContentView.swift:62-66,71`、`README.md:21-23` |
| 超时 | **无协议级超时**：`accept()` 一直阻塞。StikPair 只靠后台任务的过期回调兜底；Air2 的既有口径是 300 s 预算后就中止 | `[IDV]` 无超时；`[SP] PairingController.swift:221-228`；`a2_rppairing_pairable_host.h` 的 `A2RPPairableHostDefaultBudgetSeconds` |

**后台能力要点**：`BGContinuedProcessingTask` 属 **iOS 26+**；StikPair 的工程把整体
deployment target 设成 **27.0**（`[SP] project.yml:6`）。Air2 的 target 是 **14.0**
（`scripts/gen_xcodeproj.py:22`）⇒ 接这套必须 `@available` 包裹 + 退化路径。

---

## 6. 失败模式与错误面（照这个分类做文案，别一句万能文案）

| 场景 | 现象 | 该报什么 | 依据 |
|---|---|---|---|
| 本地网络未授权 | 探测 60 s 超时 | 「需本地网络权限」+ 去设置的指引 | `[SP] PairingController.swift:92-96` |
| 绑定失败 | `TcpListener::bind` 报错 | 端口不可用（含具体 addr） | `[SP] lib.rs:263-265` |
| 无人连入 | accept 一直阻塞 | 后台时间用尽 / 用户取消 | `[SP] PairingController.swift:221-228` |
| 设备请求 pair-verify | 直接终止 | 「本链路只支持 pair-setup」 | `[IDV] responder.rs:191-201` |
| 码输错 | M3 proof 校验失败 | 回 `ErrorResponse=2`；UI 报「验证码不正确」 | `:311-329` |
| TLV 结构异常 | `MalformedTlv` / `UnknownTlv` | 协议错误（带 type 值，便于定位） | `[IDV] tlv.rs:84-92` |
| M5 解密失败 | ChaCha20-Poly1305 校验不过 | 会话密钥/实现不一致（不是「码错」） | `:362-374` |
| 对端 Info 缺键 | 少 `accountID/altIRK/model/name/remotepairing_udid` | 对端身份不完整，点名缺哪个键 | `[IDV] peer_device.rs:47-63` |
| 写文件失败 | IO 错误 | 「配对成功但落盘失败」——**不可**报成功 | `[SP] lib.rs:301-304` |

**不可重试 / 必须重来**：整条会话是**一次性**的（`accept` 只接受一条连接、
每次配对都重新生成主机密钥，旧配对记录作废，`[IDV] responder.rs:72-81`）。
失败后要**重新广播**、用户再回设置点一次。

---

## 7. iOS 27 / 更低版本 / tvOS 的差异（决定 Air2 的分级）

| 系统 | 能否设备内生成配对文件 | 机制 | 依据 |
|---|---|---|---|
| **iOS 27+** | ✅ | 本规格书链路 A（pairable host，协议版本 26） | `[SP] README.md:3,7`；`[IDV] responder.rs:1-6`（"始自 iOS 27"） |
| iOS 18–26.7 | ❌ | 只能导入外部生成的配对文件；设备不暴露「与 X 配对」入口 | `docs/DECISIONS.md:137`（同 SideInstaller README 口径） |
| tvOS 11+ | ⚠️ 另一种 | 链路 B：我们浏览 `_remotepairing-manual-pairing._tcp`，用户**把 ATV 屏幕上的 6 位码输进 App**；之后再走 pair-verify、写文件 | `[SP] README.md:30-36`、`AppleTVDiscovery.swift:22-27`、`lib.rs:315-361` |
| 其他 | — | 无设备内路径 | — |

链路 B 与 A 的差别（实现时别混）：
- B 是**客户端**：先 `pair-verify`（X25519 + HKDF-SHA512，`[IDV] mod.rs:125-200`），
  verify 失败才进 `pair()`（用户输入设备上显示的码，`mod.rs:100-114`）；
  加密控制通道用 `streamEncrypted`（ChaCha20-Poly1305 每方向独立密钥）。
- B 写出的配对文件**没有我方 `alt_irk` 语义**（`lib.rs:349-355` 把 `host_alt_irk_hex` 置空），
  因为 ATV 场景不需要我们再被「识别为已配对主机」。
- B 的协议版本是 19（`[IDV] mod.rs:43`），不是 26。

---

## 8. 与 Air2 现有实现的对照（只标事实，便于分工）

| 能力 | Air2 现状 | 文件:行 | 缺口 |
|---|---|---|---|
| 帧 / 信封 / identifier / 配对文件组装 | **已有**（自研） | `Natives/Support/a2_rppairing.h:22-60`、`a2_rppairing.m`（510 行） | — |
| authTag / TXT / 实例名 | **已有**，且与上游测试向量一致 | `a2_rppairing_pairable_host.h:12-40`、`.m:427-437` | — |
| 广告 + 接受连入（NWListener） | **已有** | `a2_rppairing_pairable_host.h:22-30` | 需与后台保活/UX 串起来 |
| accessory 侧 PS-Msg01..06 | **已有** | `a2_rppairing_pairsetup_accessory.h:1-40`、`.m`（382 行） | **无真机互操作验证** |
| SRP-3072 / SHA-512 | **已有** | `a2_rppairing_srp.m`（903 行） | — |
| TLS-PSK 隧道（配对后连 RSD 用） | **未打通**（公开 Security.framework 无 PSK 套件） | `a2_rppairing_rsd.h:19-22` | 上游 idevice 有**纯 Rust**实现可替代（见 EVAL §5） |
| 码的展示 / 后台保活 / 权限 | Player 侧仅生成码、未接线 | `A2JITPairingCodeSession.h:20-28` | 需按 §5 接线 |

结论：**规格书里的协议部分我们基本都已实现**；真正缺的是「真机互操作验证」与「隧道」。
因此上游 idevice 的最大价值不是教我们协议，而是**一个可编译、可对拍的实现**（oracle）。

---

## 9. 验收判据（先做能离线自证的，再上真机）

**离线（无需真机，可在 macOS 单测跑）**
1. `authTag` 命中公开向量：`Mgp6ZGPzXM2ku9br46vsiw==` + `2BE6E510-…` ⇒ `kXjlTr2l`。
2. 帧编解码回环：`"RPPairing"` + 大端长度 + JSON，分片到达（1 B/次）仍能切帧。
3. TLV：>255 B 的 `PublicKey`（384 B 的 B）拆成 2 段后能原样拼回。
4. 配对文件：写出 4 键 plist ⇒ 用 `A2PairingFile` 解析成功；`public_key`/`private_key` 各 32 B、`alt_irk` 16 B。
5. 负面：M3 proof 错时确实发 `ErrorResponse=2`，且**不**写文件。

**真机（iOS 27 设备，缺一不可）**
6. 「设置 › 隐私与安全性 › 开发者模式」里出现「与 <name> 配对」，且名字与 `name` 一致。
7. 输入我们显示的 6 位码后会话继续走完 M1–M6，产出文件。
8. 产出的文件能被 Air2 的导入路径接受，并能在后续 `pair-verify`（连 `_remotepairing._tcp`）中被设备认可。
9. 关掉 App 重开后，用持久化的我方 `alt_irk` 重新广告，设备**不再需要**重新输码（同一配对仍有效）。
