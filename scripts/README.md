# 构建脚本

本目录存放构建、打包、代码生成的辅助脚本。

## 现有脚本

| 脚本 | 用途 |
|---|---|
| `lint_structure.sh` | 结构与规范检查，CI 第一道关卡 |
| `package_ipa.sh` | 归档并导出 IPA 到 `artifacts/` |

## 约定

- 一律用 `bash`，开头必须 `set -uo pipefail`
- 需要跨平台（macOS / Linux / BusyBox）的脚本，**禁用 GNU 扩展**：
  - `grep --include` / `-P`（BusyBox 不支持）→ 用 `find ... -name` 喂文件
  - `sed -i` 无备份后缀在 BSD 与 GNU 上语义不同 → 用临时文件替换
  - `<<<` herestring、`<(...)` 进程替换在 BusyBox ash 下不可用 → 用临时文件
- 退出码：0 成功，非 0 失败。CI 靠退出码判定，不要用 `echo` 代替
- 脚本必须可独立运行，不依赖调用者的当前目录（内部自行 `cd` 到仓库根）
