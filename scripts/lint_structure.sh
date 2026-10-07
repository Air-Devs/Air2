#!/usr/bin/env bash
# ============================================================
# Air2 — 结构与规范检查
# 目的：用机器挡住"石山代码"的常见形态
#   1. 未登记的顶层目录
#   2. 超大文件
#   3. 禁用命名
#   4. Core 层依赖 UI 框架
# 依赖：仅 POSIX 工具 + find/grep，兼容 GNU 与 BusyBox
# 退出码非 0 即失败。
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
warn() { printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m[错误]\033[0m %s\n' "$*"; FAIL=1; }
ok()   { printf '  \033[32m[通过]\033[0m %s\n' "$*"; }

# 收集源文件（跨平台：不用 grep --include）
collect() {
    find "$@" -type f \
        \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \
           -o -name '*.c' -o -name '*.h' -o -name '*.java' \) 2>/dev/null
}

# ------------------------------------------------------------
# 1. 顶层目录白名单
# ------------------------------------------------------------
echo "==> 1. 顶层目录检查"
ALLOWED_TOP="Air2 Natives JavaApp Libraries Assets cmake scripts docs tests .github"
bad_top=0
for path in * .github; do
    [ -e "$path" ] || continue
    [ -d "$path" ] || continue
    case "$path" in .git) continue ;; esac
    if ! printf ' %s ' "$ALLOWED_TOP" | grep -q " $path "; then
        err "未登记的顶层目录: $path （请先在 docs/ARCHITECTURE.md 登记）"
        bad_top=1
    fi
done
[ "$bad_top" -eq 0 ] && ok "顶层目录全部已登记"

# ------------------------------------------------------------
# 2. 文件规模
# ------------------------------------------------------------
echo "==> 2. 文件规模检查"
HARD=800
SOFT=400
big=0
collect Air2 Natives JavaApp > /tmp/.air2_files.$$
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    [ -n "$n" ] || continue
    if [ "$n" -gt "$HARD" ]; then
        err "$f 有 $n 行（上限 $HARD，阻塞合并）"; big=1
    elif [ "$n" -gt "$SOFT" ]; then
        warn "$f 有 $n 行（建议拆分为 ≤ $SOFT 行）"
    fi
done < /tmp/.air2_files.$$
[ "$big" -eq 0 ] && ok "无超大文件"

# ------------------------------------------------------------
# 3. 禁用命名（针对文件名/类型名）
# ------------------------------------------------------------
echo "==> 3. 命名检查"
BAD='(Utils2|ManagerNew|NewManager|Common|Helper)\.'
found=$(cat /tmp/.air2_files.$$ | grep -E "$BAD" || true)
if [ -n "$found" ]; then
    for f in $found; do err "禁用命名: $f"; done
else
    ok "无禁用命名"
fi

# ------------------------------------------------------------
# 4. Core 层不得依赖 UI 框架
# ------------------------------------------------------------
echo "==> 4. 分层检查"
if [ -d Air2/Core ]; then
    corefiles=$(find Air2/Core -type f -name '*.swift' 2>/dev/null)
    leaked=""
    if [ -n "$corefiles" ]; then
        leaked=$(grep -lE '^[[:space:]]*import[[:space:]]+(SwiftUI|UIKit)' $corefiles 2>/dev/null || true)
    fi
    if [ -n "$leaked" ]; then
        for f in $leaked; do err "Core 层不得依赖 UI 框架: $f"; done
    else
        ok "Core 层无 UI 依赖"
    fi
else
    ok "Core 层尚未创建，跳过"
fi

# ------------------------------------------------------------
# 5. 遗留标记统计（提示，不阻塞）
# ------------------------------------------------------------
echo "==> 5. 遗留标记"
n_todo=$(cat /tmp/.air2_files.$$ | xargs grep -lE 'TODO|FIXME|XXX' 2>/dev/null | wc -l | tr -d ' ')
n_todo=${n_todo:-0}
if [ "$n_todo" -gt 0 ]; then
    warn "有 $n_todo 个文件含 TODO/FIXME（超过一个迭代周期未处理应删除）"
else
    ok "无遗留标记"
fi

rm -f /tmp/.air2_files.$$

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m检查通过\033[0m\n'
else
    printf '\033[31m检查失败\033[0m\n'
fi
exit "$FAIL"
