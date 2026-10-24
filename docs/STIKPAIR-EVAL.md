# StikPair 评估 —— 许可证与可行性结论

> 调研对象：`StikDebug/StikPair` @ `d9661c5`（tag `v1.2.0`，2026-08-25 最后推送），
> 依赖 `jkcoxson/idevice`（MIT）。
> 结论全部有 `文件:行` 或**实测命令输出**支撑；行为规格另见 `docs/STIKPAIR-SPEC.md`。
> 本文只读调研，**未改任何业务代码**。

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 能直接 vendor StikPair 吗 | **不能**。其许可是**自定义**的「MIT, Non-Commercial」（`LICENSE:1`），带**非商业限制**；本仓是 **GPL-3.0-or-later**，两者**无法合并成一个可分发作品**。 |
| 那它的依赖 `idevice` 呢 | **可以**。`idevice` 是 **MIT**（`idevice/Cargo.toml:7`；GitHub license API `spdx_id: MIT`），与 GPLv3 兼容，且**已在本仓 `docs/DEPENDENCIES.md:102` 登记（状态「未引入」）**。 |
| 依赖形式 | Rust **`staticlib` crate → xcframework**（`Cargo.toml:9`、`build-rust.sh:17-21`）；**仓库里没有预编译产物**（`.gitignore:6` 忽略 `StikPairFFI.xcframework`，release 只挂 `.ipa`）⇒ 想用就得自己在 Mac 上编。 |
| 要加 Swift 吗 | **不需要**。走 Rust 静态库 + C ABI + ObjC 调用；本仓 `scripts/gen_xcodeproj.py` 目前**只扫 `.m/.mm`**（`:295`），加 Swift 反而要改工程脚本 + 桥接头。 |
| 能不能编进 iOS App | **能**，已实测编译链路（见 §5）。**注意**：`idevice` 的 `remote_pairing` 功能**单开编不过**（缺 TLS 后端，实测 5 个错误），必须带上 `rustls` + 一个 crypto provider。 |
| 设备内配对的代码在哪 | `rust/src/lib.rs:82-133`（C ABI）→ `:251-313`（流程）；Swift 侧广告 `App/PairingController.swift:285-295`；真协议在 idevice 的 `remote_pairing/responder.rs:163-459`。 |
| 工作量 | **约 30 人时**（含 1 轮真机迭代）；其中协议本体我们已有，真正花时间的是**构建链路 + C ABI + 接线 + 真机验证**。 |

---

## 1. 许可证事实（精确到行）

### 1.1 StikPair：不是 MIT

- 文件标题就写明：**`StikPair License (MIT, Non-Commercial)`**（`LICENSE:1`），版权 `StephenDev0`（`LICENSE:3`）。
- 授权范围**只限非商业**：`"to deal in the Software for NON-COMMERCIAL purposes"`（`LICENSE:7`）。
- 明确禁止商业使用：`"COMMERCIAL USE … is NOT permitted without prior written permission"`（`LICENSE:15-18`）。
- **GitHub 的判定是 `NOASSERTION` / `Other`**（`GET /repos/StikDebug/StikPair` ⇒ `license.spdx_id = "NOASSERTION"`），
  即不是 OSI 认可许可、没有 SPDX 标识。
- 因此正确说法是「**自定义源码可见许可：MIT 文本 + 非商业限制**」，而**不是**「没有许可」。
  ⚠️ 本仓 `docs/DEPENDENCIES.md:183` 现在写的是「LICENSE = NOASSERTION（未声明许可，默认保留所有权利）」
  ——**这句需要更正**（有许可文件，只是非 OSI；结论「不入仓」不变）。

### 1.2 idevice：真 MIT

- `idevice/Cargo.toml:7` ⇒ `license = "MIT"`；仓库根 `LICENSE.txt`，GitHub API `spdx_id: MIT`。
- 我们关注的 commit `7bd551c`（`feature: wireless pairing FFI`）即 StikPair 钉住的那版（`Cargo.toml:12-15`）。

### 1.3 本仓：GPL-3.0-or-later

- 根 `LICENSE` / `COPYING` = GNU GPL v3；源码头统一 `SPDX-License-Identifier: GPL-3.0-or-later`
  （例：`Air2/Player/A2JITPairingCodeSession.h:6`、`Natives/Support/a2_rppairing.h:20`）。

### 1.4 兼容性判定（为什么不能 vendor）

| 组合 | 结果 | 理由 |
|---|---|---|
| GPLv3 作品 + StikPair(非商业) | ❌ 不可分发 | 非商业限制属 GPLv3 **§7 禁止的「附加限制」**；同时 §10 要求下游获得与 GPLv3 同等的自由（含商业使用）。两者不可能同时满足。 |
| GPLv3 作品 + idevice(MIT) | ✅ | MIT 无附加限制，可并入 GPLv3 作品；保留版权与许可声明即可。 |
| 「我们非商业，所以没事？」 | ❌ 这个推理不成立 | 冲突点不是「我们现在收不收钱」，而是**组合作品对外分发时无法同时满足两份许可**。 |

**可以做的**（本仓一直在做的口径，见 `Air2/Player/A2JITAutoPairing.h:17-18`、`docs/DECISIONS.md:116`）：
读**协议事实**（帧格式、TLV 类型、TXT 键、authTag 算法、plist 键名、消息序）后**自研实现**；
协议事实不是受保护的表达，且 `idevice`(MIT) 本身就是这些事实的公开、可复用实现。

> 判例层面的免责声明：以上是工程口径的许可分析，不构成法律意见；真要对外分发前让法务过一眼。

---

## 2. 依赖是怎么接的（形式与产物）

| 项 | 事实 | 出处 |
|---|---|---|
| Rust crate 类型 | `crate-type = ["staticlib"]` | `[SP] rust/Cargo.toml:9` |
| idevice 引入方式 | **git 依赖 + 固定 rev**（非 crates.io、非 xcframework、非源码 vendored） | `[SP] rust/Cargo.toml:12-15`（`rev = 7bd551c…`, `default-features=false`, features `remote_pairing`+`aws-lc`） |
| 运行时 | `tokio`（`rt-multi-thread`, `net`, `macros`, `fs`） | `:17` |
| 打包 | `build-rust.sh`：`cargo build --release --target aarch64-apple-ios` + `-ios-sim`，再 `xcodebuild -create-xcframework` | `build-rust.sh:17-21` |
| Xcode 侧 | `framework: StikPairFFI.xcframework`，`embed: false`，`OTHER_LDFLAGS: -lc++` | `project.yml:26-28,33` |
| 产物是否随仓 | **否**：`.gitignore:6` 忽略 `StikPairFFI.xcframework`；release `v1.2.0` 只挂 `StikPair.ipa` | `[SP] .gitignore:6`；GitHub releases API |
| 模块暴露 | `module.modulemap` 导出 `stikpair.h` 一个 C 头 | `rust/include/module.modulemap:1-4`、`stikpair.h:34-61` |
| 构建工具链 | Xcode 27 / iOS 27 SDK、Rust + 两个 iOS target、`xcodegen` | `README.md:8`、`.github/workflows/build.yml:31-42` |

**含义**：所谓「拿到 StikPair」实际是「拿到一份 MIT-NC 的 Rust 薄壳 + 自己现场编 90+MB 依赖树」。
即使许可放行，也**没有可下载的 xcframework** 可用。

---

## 3. 设备内配对的实现位置（文件 + 行号）

### 3.1 StikPair 侧（薄壳，423 行 Rust + 377 行 Swift）

| 职责 | 位置 |
|---|---|
| C ABI 入口（阻塞式，返回 `StikPairResult`） | `rust/src/lib.rs:82-133`（签名 `:83-92`） |
| tokio 多线程 runtime | `:108-117` |
| **主流程**：bind → 生成身份 → 通知 Swift 去广告 → accept → 握手 → 写文件 | `:251-313` |
| 广告交给 Swift（不用 mdns-sd，避开 multicast entitlement） | `:1-6`（注释）、`:279`、`:379-403`（TXT 组装） |
| 写文件 | `:301-304` → `idevice rp_pairing_file.rs:150-153` |
| Apple TV 反向链路（客户端） | `:315-361` |
| 结果释放（6 个 C 字符串） | `:405-423` |
| Swift：权限 → 后台任务 → 调 ABI → 展示码 | `App/PairingController.swift:82-99,195-276` |
| Swift：`NetService` 发布 `_remotepairing-pairable-host._tcp` + TXT | `:285-295` |
| Swift：码展示 + 通知 | `:297-306`、`:339-364` |
| Swift：落盘路径 `Documents/rp_pairing_file.plist` | `:333-336` |
| UI：设置指引 / 码 / 导出 | `App/ContentView.swift:62-66,77-90,169-175` |

### 3.2 idevice 侧（真正的协议，MIT）

> 行号取自 StikPair 钉住的 git rev `7bd551c`；换成 crates.io **0.1.68** 后整体偏移 +4 行左右
> （如 `accept` 在 0.1.68 是 `:167`、`handshake` `:181`、`pair_setup` `:249`、
> `build_accessory_identity_tlv` `:419`；`compute_auth_tag` 不变，仍是 `peer_device.rs:129`）。

| 职责 | 位置 |
|---|---|
| 服务类型常量 `_remotepairing-pairable-host._tcp.local.` | `remote_pairing/responder.rs:38` |
| 宿主身份（含随机 16 B altIRK、wire version 26） | `:48-81` |
| TXT 7 键（name/identifier/authTag/model/flags/ver/minVer） | `:91-105` |
| `accept()` = handshake + pair_setup | `:163-174` |
| handshake（拒绝 attemptPairVerify） | `:177-242` |
| PS-Msg01..06（SRP-3072/SHA-512、6 位码、HKDF、ChaCha20-Poly1305） | `:245-407` |
| M6 身份 TLV + OPACK Info | `:411-459` |
| 帧 / 信封 / 序列号 / b64 字节 | `remote_pairing/socket.rs:69-164` |
| 配对文件写盘（plist 4 键） | `remote_pairing/rp_pairing_file.rs:69-87,150-153` |
| authTag 算法 + 公开测试向量 | `remote_pairing/peer_device.rs:129-140,202-212` |
| 纯 Rust TLS 1.2 PSK（隧道用，**不依赖 OpenSSL**） | `remote_pairing/tls_psk.rs:340,518`；`tunnel.rs:24`（`connect_tls_psk_tunnel_native`） |

**关键发现**：idevice 的 `connect_tls_psk_tunnel_native`（`tunnel.rs:20-28`）说明是
「built-in TLS 1.2 PSK-AES256-CBC-SHA384 implementation with no external TLS library dependency」。
这正是本仓 `Natives/Support/a2_rppairing_rsd.h:19-22` 认定「TLS-PSK 未打通（公开 Security.framework 无 PSK 套件）」
的那一环——**用 idevice 就不需要我们自己啃 TLS-PSK**。

---

## 4. 「Swift 能不能混编」——不需要混编

本仓现状（实测）：

| 事实 | 证据 |
|---|---|
| 全仓 **0 个 `.swift` 文件** | `find . -name '*.swift'` 空 |
| 工程由脚本生成，**只扫 `.m`/`.mm`** 作为编译单元，`.h` 进头文件组 | `scripts/gen_xcodeproj.py:285-298`（判断在 `:295`） |
| 已有第三方**静态库**接线范式可复用 | `MBEDTLS_LDFLAGS`（`scripts/gen_xcodeproj.py:228-232`）、`target_ldflags()`（`:236-244`）、写入 build settings（`:657`） |
| 部署目标 14.0（StikPair 是 27.0） | `scripts/gen_xcodeproj.py:22` vs `[SP] project.yml:6` |

结论与做法：
- **不引入 Swift**：把 StikPair 那份 Rust 薄壳**按规格自研重写**（C ABI，纯 C 头），用 **ObjC** 调用。
  这样 `gen_xcodeproj.py` 只需加一段 `.a` 的链接（照抄 mbedTLS 范式），**零 Swift 改动**。
- 若坚持 Swift：必须同时改 `gen_xcodeproj.py`（新增 `.swift` 扫描、`SWIFT_VERSION`、
  `SWIFT_OBJC_BRIDGING_HEADER`）、并处理 Swift 运行时随包。**收益为零**，不做。
- 静态库链接注意：StikPair 的 `OTHER_LDFLAGS` 带 `-lc++`（`project.yml:33`），是给 Rust 依赖里的
  C++ 部分（`aws-lc-sys` 含 C++）用的；若我们选纯 Rust crypto provider 可去掉。

---

## 5. idevice 能不能编进 iOS App？——能，实测链路如下

### 5.1 版本选择（**重要**）

| 版本 | 是否含「设备发起」responder | 证据 |
|---|---|---|
| crates.io **0.1.63** | ❌ **没有** `remote_pairing/responder.rs` | 下载 `idevice-0.1.63.crate` 解包，`remote_pairing/` 下无 `responder.rs` |
| crates.io **0.1.68**（当前最新） | ✅ 有 `responder.rs`，并导出 `PairableHost` / `PairableHostInfo` / `PAIRABLE_HOST_SERVICE_TYPE` | 解包可见；`src/remote_pairing/mod.rs:35-39` 的 `pub use` |
| StikPair 钉的 git rev `7bd551c` | ✅ | `idevice/src/remote_pairing/responder.rs` 存在（本次逐文件拉取核对） |

⇒ **不要抄 StikPair 的 `git rev`**，直接 `idevice = "0.1.68"`（crates.io，仍是 MIT），
不用维护 git pin，也避免「钉在某个未发布 commit」。

### 5.2 feature 组合（实测，非推测）

在本机（Windows + Rust 1.95）建了一个最小 probe crate（`crate-type=["staticlib"]`，
代码只调用 `RpPairingFile::generate` / `PairableHostInfo::generate` / `RpPairingSocket::new_device` /
`PairableHost::accept` / `write_to_file` / `compute_auth_tag` / `connect_tls_psk_tunnel_native`）：

| features | `cargo check` 结果 |
|---|---|
| `default-features=false, ["remote_pairing"]` | ❌ **5 个编译错误**：`unresolved import crate::pairing_file::PairingFile` 等 ⇒ **必须有 TLS 后端** |
| `+ ["rustls"]`（只开 rustls） | ❌ `error: The rustls TLS backend is enabled but no crypto provider was selected` |
| `+ ["rustls","aws-lc"]` | ✅ `Finished` 44.0 s；依赖树 **167** 个 crate |
| `+ ["rustls","rustcrypto"]` | ✅ `Finished` 18.6 s；依赖树 **189** 个 crate（纯 Rust，但 `rustls-rustcrypto` 是 `0.0.2-alpha`） |

⇒ 推荐 **`["remote_pairing","rustls","aws-lc"]`**（与 StikPair 一致、稳），
若要「零 C/CMake 工具链」再退到 `rustcrypto`（接受 alpha 依赖）。

### 5.3 可执行的 iOS 构建路径

在 Mac（Xcode 26/27 + Rust ≥1.85，因为 idevice 是 `edition = "2024"`，`idevice/Cargo.toml:13`）上：

```sh
# 1) target
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
# 2) 我们的薄壳 crate（自研，C ABI）
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
# 3) 打包（device + simulator 两个 slice）
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/liba2_pairing_ffi.a     -headers include \
  -library target/aarch64-apple-ios-sim/release/liba2_pairing_ffi.a -headers include \
  -output A2PairingFFI.xcframework
```

- `aws-lc-sys` 在 iOS 上需要 **cmake + clang**（Xcode 自带 clang；cmake 需 `brew install cmake`）。
  这是外网依赖，但**构建期**才需要，不进 App。
- 静态库**随仓**放置（照 mbedTLS 的先例：`Libraries/ThirdParty/mbedtls/lib/*.a` 是随仓的，
  `scripts/gen_xcodeproj.py:225-226` 明确「随仓预编译，由脚本在 Mac 上离线重建」）。
  但**不要**把 `cargo build` 产物当黑盒提交——应提交「薄壳源码 + 重建脚本」，`.a` 可选随仓，
  与 `docs/DEPENDENCIES.md:114-117`「源码 + CI 构建，别搬 PocketJ 的 90 MB 预编译 `.a`」一致。
- 链接：`OTHER_LDFLAGS` 加 `-L$(SRCROOT)/Libraries/ThirdParty/idevice/lib -la2_pairing_ffi`
  （device/sim 用同一名、不同目录，或直接上 `.xcframework`——Xcode 自动选 slice）。
  若用 aws-lc，加 `-lc++`。

### 5.4 体积/风险量级

- 依赖 167 个 crate；tokio + rustls + aws-lc 的静态库量级在 **10–25 MB**（未 strip），
  `-Xlinker -dead_strip` + LTO（`[profile.release] lto = "thin"`，`Cargo.toml:19-21`）后更小。
- **不需要** iOS multicast entitlement；**需要**本地网络权限 + Developer Mode（同 StikPair）。

---

## 6. 能搬什么、不能搬什么

| 对象 | 可否使用 | 说明 |
|---|---|---|
| StikPair 的 Rust/Swift 源码 | ❌ 不可 | 非商业许可；且与 GPLv3 冲突（§1.4）。 |
| StikPair 的**协议行为描述** | ✅ 可用作规格 | 已整理成 `docs/STIKPAIR-SPEC.md`（无源码、无摘录）。 |
| `idevice`（MIT）源码/静态库 | ✅ 可 | GPLv3 兼容；需在本仓 `docs/DEPENDENCIES.md` 登记（该文件 `:1-3` 规定「未登记不得进入构建」）。 |
| idevice 的**测试向量**（authTag 那组） | ✅ | 属事实数据；本仓已独立命中同一向量（`tests/JIT/remotexpc_tests.m:595-599`）。 |

**义务**：引入 idevice 后需 (a) 在 `docs/DEPENDENCIES.md` 登记（版本/来源/许可/用途/引入方式）；
(b) 随包保留 MIT 版权与许可文本（`Libraries/ThirdParty/idevice/LICENSE.txt` + 构建产物旁）；
(c) 若要发布源码包，含 `Cargo.lock` 以保证可重建。

---

## 7. 工作量估算（人时，含缓冲）

> 前提：协议本体**我们已有**（`Natives/Support/a2_rppairing*` 共 8,437 行，
> 含 SRP-3072、accessory 侧 PS-Msg01..06、TXT/authTag、帧/信封），所以工作集中在
> 「构建链路 + C ABI + 接线 + 真机验证」，**不是**重写协议。

| # | 任务 | 落点（文件级） | 估时 |
|---|---|---|---|
| 1 | 薄壳 crate（C ABI：`a2_pair_start/stop/submit_pin/free_result`） | `Natives/Rust/a2_pairing_ffi/{Cargo.toml,src/lib.rs,include/a2_pairing_ffi.h}` | 5 h |
| 2 | 构建脚本（device + sim + xcframework + 校验 `lipo`/`otool`） | `scripts/build_rust_pairing_ios.sh` | 3 h |
| 3 | 工程接线（静态库/框架链接、头搜索路径） | `scripts/gen_xcodeproj.py`（仿 `:228-244` 的 mbedTLS 范式，写入点在 `:657`） | 2 h |
| 4 | Natives 适配层（FFI → 现有语义：判据行、失败分类、`A2JITAutoPairingStep`） | `Natives/Support/a2_idevice_pairing.{h,m}` | 5 h |
| 5 | Player/Bridge 接线（引擎实现 + 码来源改为 FFI 回调） | `Air2/Bridge/A2JITAutoPairingEngineBridge.m`、`Air2/Player/A2JITPairingCodeSession.m` | 4 h |
| 6 | 广告与保活（复用现有 `A2RPPairableHostAdvertiser`；BGContinuedProcessingTask + `@available`） | `Natives/Support/a2_rppairing_pairable_host.m`（复用/微调）、App 装配处 | 4 h |
| 7 | 离线测试（authTag 向量、帧分片、TLV 分段、plist 四键断言、负面用例） | `tests/JIT/pairwire_tests.m`（扩）/ `run_pairwire_tests.py` | 3 h |
| 8 | 真机迭代（iOS 27 设备；设置里出现入口 → 输码 → 文件可用 → 重连免码） | —（设备 + 日志） | 8 h（1–2 轮） |
| | **合计** | | **≈34 h**（乐观 24 h / 悲观 45 h） |

**如果只做「验证现有 ObjC 实现」而不引入 Rust**：1（换成真机调试）+ 8，约 **10–14 h**，
但会**永远缺隧道**（`a2_rppairing_rsd.h:19-22`），后续 JIT 那一步仍要另找方案。

---

## 8. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| **没有 iOS 27 真机** | 规格里 §9 的 6–9 条判据无法验证；「设置里是否出现配对入口」永远未知 | 优先借机；否则只能交付到「离线自证 + 有界失败」 |
| idevice 是 `0.x`，API 会动 | 升级即可能编译失败（0.1.63→0.1.68 就新增了 responder） | 钉 `0.1.68` + 提交 `Cargo.lock`；升级走单独 PR |
| `remote_pairing` 单开编不过 | 直接抄 StikPair 的 features 之外的组合会踩坑 | 用实测过的 `["remote_pairing","rustls","aws-lc"]` |
| `aws-lc-sys` 需要 cmake | Mac/CI 缺 cmake 就编不过 | 构建脚本里显式检查并提示；或退 `rustcrypto`（alpha 依赖） |
| 静态库体积 | IPA 变大（10–25 MB 量级） | LTO + `-dead_strip`；只开 `remote_pairing`（别开 `full`） |
| 后台被挂起 | 用户在「设置」里操作时任务被 Suspends ⇒ 必然失败 | 按 SPEC §5：`BGContinuedProcessingTask` + `@available(iOS 26)` + 过期即如实失败 |
| 复用现有 ObjC 与 idevice 产出「都对但字段语义不同」 | 两套实现漂移 | 用 idevice 当 **oracle**：同一 authTag 向量、同一 plist 键集、同一 wire version 常量（26/19 分明） |
| 许可误判（把 NC 当 MIT） | 分发即侵权 | 本文 §1；并更正 `docs/DEPENDENCIES.md:183` 的表述 |

---

## 9. 建议路线

1. **不 vendor StikPair**，不留它的任何代码/常量；只在 `docs/` 保留规格书。
2. **引入 `idevice` 0.1.68（MIT）** 作为「设备内配对」的**第二实现 + oracle**：
   - 它的 `PairableHost` 负责 PS-Msg01..06（与我们自研实现互为对照）；
   - 它同时带来**纯 Rust TLS-PSK 隧道**，解掉我们 `a2_rppairing_rsd.h:19-22` 的死结；
   - 全部经**自研 C ABI 薄壳**暴露给 ObjC，不引入 Swift。
3. **保留现有 ObjC 实现**为回退路径：Rust 侧不可用（未编入/初始化失败）时按现有 Provider 语义如实降级
   （`A2JITAutoPairingBlockerEngineUnavailable`，`Air2/Player/A2JITAutoPairing.h:87`）。
4. 先落**离线可自证**的 5 条判据（SPEC §9），再排真机。

### 最小任务清单（可直接开工）

- [ ] `Natives/Rust/a2_pairing_ffi/Cargo.toml` —— `idevice = { version="0.1.68", default-features=false, features=["remote_pairing","rustls","aws-lc"] }` + `tokio{rt-multi-thread,net,fs,macros}` + `crate-type=["staticlib"]`
- [ ] `Natives/Rust/a2_pairing_ffi/src/lib.rs` —— 4 个 C 导出：`a2_pair_start(bind,name,model,out_path,cbs,ctx,out)` / `a2_pair_stop` / `a2_pair_submit_result_free`；阻塞调用放 `tokio::runtime::Builder::new_multi_thread()`
- [ ] `Natives/Rust/a2_pairing_ffi/include/a2_pairing_ffi.h` —— `A2PairResult{error,device_name,device_model,device_udid,alt_irk_hex,pairing_path}` + 两个回调（ready/pin）
- [ ] `scripts/build_rust_pairing_ios.sh` —— 两个 target + `xcodebuild -create-xcframework` + `lipo -info` 自检
- [ ] `scripts/gen_xcodeproj.py` —— 加 `A2PAIR_FFI_LDFLAGS`（仿 `:228-244`）与 `HEADER_SEARCH_PATHS`
- [ ] `Natives/Support/a2_idevice_pairing.{h,m}` —— FFI 包装：状态 → `A2JITAutoPairingStep`，错误 → `A2JITAutoPairingBlocker`，全程 `[A2-PAIRPIN]` 判据行
- [ ] `Air2/Bridge/A2JITAutoPairingEngineBridge.m` —— 新增 Rust 引擎实现（保留现有自研实现作回退）
- [ ] `Air2/Player/A2JITPairingCodeSession.m` —— 码来源改为 FFI 回调（码 + hostName 持久化逻辑保留）
- [ ] `tests/JIT/pairwire_tests.m` —— 加 5 条离线判据（authTag 向量 / 帧分片 / TLV 384B 分段 / plist 四键 / M3 失败不落盘）
- [ ] `docs/DEPENDENCIES.md` —— 登记 idevice 0.1.68（MIT，静态库，用途：设备内配对 + TLS-PSK 隧道）；**更正 `:183` 的 StikPair 许可表述**
- [ ] `docs/DECISIONS.md` —— 新增 ADR-010「设备内配对：自研协议实现 + idevice(MIT) 作第二实现/oracle；不 vendor StikPair(NC)」

---

## 附：本次调研的可复核证据

- StikPair 源码：`git clone --depth 1 https://github.com/StikDebug/StikPair` ⇒ `d9661c5`。
- idevice：`GET /repos/jkcoxson/idevice`（`license.spdx_id=MIT`）；`GET /contents/...?ref=7bd551c` 逐文件；
  `static.crates.io/crates/idevice/idevice-0.1.68.crate` 解包核对 `remote_pairing/responder.rs` 存在、`0.1.63` 不存在。
- 编译实验：`C:\Users\Administrator\AppData\Local\hermes\cache\scratch\idev_probe`（4 组 feature 的 `cargo check` 结果见 §5.2）。
