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
ALLOWED_TOP="Air2 Air2.xcodeproj Natives JavaApp Libraries Assets cmake scripts docs tests .github"
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
# 说明：这里不设硬性行数上限。
#
# 原因：UIKit 的 Auto Layout 是声明式的，一条约束一行，
# 一个稍复杂的卡片 30~40 行约束很正常。按行数强制拆分会把
# 「一个完整的视图」硬切成多份，为了满足指标反而增加了
# 跨文件跳转的成本（分类访问主类私有属性还需要额外的内部头文件）。
#
# 所以行数只作为提示信号：超过 1000 行时，通常确实说明
# 这个文件承担了多个职责，值得看一眼是否需要拆。
# 是否真的拆，由人判断职责边界，不由行数决定。
echo "==> 2. 文件规模检查（提示性）"
HINT=1000
big=0
collect Air2 Natives JavaApp > /tmp/.air2_files.$$
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    [ -n "$n" ] || continue
    if [ "$n" -gt "$HINT" ]; then
        warn "$f 有 $n 行，值得确认一下是否承担了多个职责"
        big=1
    fi
done < /tmp/.air2_files.$$
[ "$big" -eq 0 ] && ok "无超长文件"

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
# Swift 与 ObjC 两边都查：Core 是无 UI 的业务核心，可单测。
# ObjC 残留目前零 UIKit 引用（仅注释里提到），保持住；
# Swift 迁移后同样不许 import UIKit/SwiftUI。
echo "==> 4. 分层检查"
if [ -d Air2/Core ]; then
    corefiles=$(find Air2/Core -type f -name '*.swift' 2>/dev/null)
    leaked=""
    if [ -n "$corefiles" ]; then
        leaked=$(grep -lE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(SwiftUI|UIKit)' $corefiles 2>/dev/null || true)
    fi
    if [ -n "$leaked" ]; then
        for f in $leaked; do err "Core 层不得依赖 UI 框架: $f"; done
    else
        ok "Core 层 Swift 无 UI 依赖"
    fi
    objc_core=$(find Air2/Core -type f \( -name '*.m' -o -name '*.mm' -o -name '*.h' \) 2>/dev/null)
    objc_leaked=""
    if [ -n "$objc_core" ]; then
        objc_leaked=$(grep -lE '#[[:space:]]*import[[:space:]]*<(UIKit|SwiftUI)/|@[[:space:]]*import[[:space:]]+(UIKit|SwiftUI)' $objc_core 2>/dev/null || true)
    fi
    if [ -n "$objc_leaked" ]; then
        for f in $objc_leaked; do err "Core 层不得依赖 UI 框架: $f"; done
    else
        ok "Core 层 ObjC 无 UI 依赖"
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

# ------------------------------------------------------------
# 6. 头文件引用检查
# ------------------------------------------------------------
# 之前这一步只在 CI 跑，本地漏检了三次才被发现。
# 引用了不存在的头文件时，编译器会报错，但等 CI 要几分钟。
echo "==> 6. 头文件引用检查"
if [ -f "$ROOT/scripts/check_imports.py" ]; then
    if ! python3 "$ROOT/scripts/check_imports.py" 2>&1 | tail -20; then
        :   # 详细错误已由脚本输出
    fi
    if ! python3 "$ROOT/scripts/check_imports.py" >/dev/null 2>&1; then
        err "存在无法解析的头文件引用"
    fi
fi

# ------------------------------------------------------------
# 7. ObjC 静态检查
# ------------------------------------------------------------
# 没有本地编译器，靠脚本过滤掉「一眼能看出」的编译错误，
# 减少 CI 往返。真实编译仍需 Xcode。
echo "==> 7. ObjC 静态检查"
if [ -f "$ROOT/scripts/lint_objc.py" ]; then
    if python3 "$ROOT/scripts/lint_objc.py" 2>&1 | tail -20; then
        :
    else
        err "ObjC 静态检查未通过"
    fi
fi

# ------------------------------------------------------------
# 8. 真相源声明（信息，不阻塞）
# ------------------------------------------------------------
# 真相源 = 文件系统 + Package.swift，
# pbxproj 是瞬时产物（构建前重生成，不依赖入库副本）。
echo "==> 8. 真相源"
if [ -f "$ROOT/Package.swift" ]; then
    ok "Package.swift 存在（SwiftPM 为真相源之一）"
else
    warn "缺少 Package.swift（SwiftPM 真相源）"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m检查通过\033[0m\n'
else
    printf '\033[31m检查失败\033[0m\n'
fi
exit "$FAIL"
