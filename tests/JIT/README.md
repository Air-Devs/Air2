# tests/JIT —— JIT 纯逻辑单元测试

覆盖 `Air2/Player` 下的四件纯逻辑（★编译并运行**真实实现**，非 Python 镜像★）：

- `A2JITStrategySelector` —— 分级表（26 内置手动 / 27 自动 / 17.4+ 导入 / 内核 / 17.0–17.3 不可用）
  与 Provider 尝试顺序、失败原因；
- `A2PairingFile` —— 配对文件解析/校验（合法样本 / 缺字段 / 非法字段 / 损坏 base64 / 空文件）；
- `A2JITStateMachine` —— 合法迁移链 + 非法迁移被拒（含终态 `Enabled`）；
- `A2JITFacts` —— 注入假 `A2JITFactsSource` 后的能力判定。

## 运行（macOS：需 Xcode 命令行工具的 clang）

```sh
python3 tests/JIT/run_jit_tests.py
```

输出每例一行 `PASS` / `FAIL`，末尾给计数：

```
TOTAL pass=85 fail=0
[runner] 全部通过 ✓
```

退出码：`0` = 全通过；`1` = 有 `FAIL`（或编译/工具链失败）。

> 为什么是真编译：版本隔离那套用 Python 镜像，是因为当年 iSH 里没有 ObjC 编译器；
> 本机有 clang + Foundation，直接编译**被测的真实源文件**严格强于镜像。
