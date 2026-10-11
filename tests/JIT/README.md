# tests/JIT —— JIT 纯逻辑单元测试

覆盖 `Air2/Player` 下的纯逻辑（★编译并运行**真实实现**，非 Python 镜像★）：

- `A2JITStrategySelector` —— 分级表（26 内置手动 / 27 自动 / 17.4+ 导入 / 内核 / 17.0–17.3 不可用）
  与 Provider 尝试顺序、失败原因；
- `A2PairingFile` —— 配对文件解析/校验（合法样本 / 缺字段 / 非法字段 / 损坏 base64 / 空文件）；
- `A2JITStateMachine` —— 合法迁移链 + 非法迁移被拒（含终态 `Enabled`）；
- `A2JITFacts` —— 注入假 `A2JITFactsSource` 后的能力判定；
- `A2JITCoordinator` + `A2LaunchChain` —— 编排端到端 + 「先 JIT 后启 JVM」门禁；
- **`[JIT-IMPL-2]`** `A2JITVerdictGuidance` —— 判据分流（7 档原因/动作 key 互不相同）；
- **`[JIT-IMPL-2]`** `A2JITStrings` —— 四语齐全（每个 key × zh-Hans/zh-Hant/en/ja 全量断言）；
- **`[JIT-IMPL-2]`** `A2JITPairingFileStore` —— 导入落盘 + 元数据（来源/时间/SHA-256）+ 拒垃圾；
- **`[JIT-IMPL-2]`** `A2JITExternalToolProvider` —— 拉起 + **有界等待** + 轮询判据（含超时即失败）；
- **`[JIT-IMPL-2]`** `A2JITImportedPairingProvider` —— 就绪真探测 + **真调判据**（注入假 probe）；
- **`[JIT-AUTOPAIR-1]`** `A2JITAutomaticPairingProvider` —— 能力检测（仅 27+）+ **前置条件精确报缺哪项** +
  配对文件**新鲜度** + ★有界★生成调用点 + **不谎报**（引擎未接入 / 报成功但无文件一律失败）；
- **`[JIT-AUTOPAIR-1]`** `A2JITAutoPairingGuidance` + `A2JITAutoPairingPreconditions` ——
  14 档 blocker → 现有 `A2JITFailureReason` 的映射、四语分流文案、三态（Unknown≠满足）语义；
- **`[JIT-DDI-1]`** `A2JITDDI` + `A2JITDDIStore` —— DDI 纯逻辑（版本对齐**三态**：Matched / Mismatched /
  **Unknown**；综合判定五态）、UDIF 尾标校验、手动导入落盘 + 元数据、过期判定；
- **`[JIT-DDI-1]`** `A2JITDDIProbe` + `A2JITDDIGuidance` —— DDI 判定合成（本地镜像 + 设备侧查询 ⇒
  **已就位 / 缺失 / 无法确认**）、★`Unknown ⇒ Unknown`（不许升成满足、也不许降成缺失）★、
  5 档状态/原因/动作 key × 四语、联网取 / 挂载的如实阻断、**Provider 接线**（DDI 真三态进前置条件）；
- **`[JIT-IMPL-2]`** 接线不变量 —— `A2JITReadinessVerdict` 与 Natives 的 `A2JITRegionVerdict`
  逐值相等、scheme 清单与 `Air2/Info.plist` 一致、★Player 不得 import Natives 判据头★、
  Bridge 确实调用了 `A2JITEnvironment`；★[JIT-AUTOPAIR-1] 另加：设置页接入自动配对行、
  Bridge 骨架如实报未接入、Player 不得 import Bridge★；★[JIT-DDI-1] 另加：设置页接入 DDI 行 /
  导入 / **联网取开关（默认关）**、DDI 设备侧 Bridge 骨架如实回 `Unknown` / `NO`、
  Player 不得 import DDI Bridge★；
- **`[JIT-AUTOPAIR-2]`** `a2_rppairing_crypto` + `a2_rppairing` + `a2_rppairing_chacha` + `a2_rppairing_ed25519`
  + `a2_rppairing_verify` + `a2_rppairing_rsd`（Natives/Support，★真实现直接链接★）——
  RPPairing 握手内核：**X25519**（RFC 7748 §5.2/§6.1 向量逐位核对）、**HKDF-SHA512**（独立参考逐位核对）、
  SHA-512 / MD5 / CSPRNG / **UUIDv3**（RFC 4122）、**线上帧与信封编解码**（往返 + 边界如实报错）、
  **配对文件组装 → `A2PairingFile` 校验 → `A2JITPairingFileStore` 落盘**（与 ④ 的交接）、
  **握手完成度自检**如实点名受阻步骤（Ed25519 / ChaCha20-Poly1305 未落地）+ Bridge 真接线不变量。

## 运行（macOS：需 Xcode 命令行工具的 clang）

```sh
python3 tests/JIT/run_jit_tests.py
```

输出每例一行 `PASS` / `FAIL`，末尾给计数：

```
TOTAL pass=<N> fail=0
[runner] 全部通过 ✓
```

退出码：`0` = 全通过；`1` = 有 `FAIL`（或编译/工具链失败）。

> 计数是**单调不回退**的门禁：新增逻辑只许加例（`[JIT-AUTOPAIR-1]` 达 396；
> `[JIT-DDI-1]` 再增 ⑭⑮ 与不变量 ⑩；`[JIT-AUTOPAIR-2]` 再增 §⑯ 共 71 例 ⇒ 基线 **517 → 588**），
> 基线例数一项都不许掉（历史 107 套件对**新源码**仍 107/0）。

> 为什么是真编译：版本隔离那套用 Python 镜像，是因为当年 iSH 里没有 ObjC 编译器；
> 本机有 clang + Foundation，直接编译**被测的真实源文件**严格强于镜像。
> ★测试还会用 `-I Natives/Support` 读 `A2JITEnvironment.h` 的枚举值做跨层镜像断言
> （只读头，不链接该 `.m` —— 其实现含 arm64 裸 `brk`，不能在 macOS 上跑）★。
