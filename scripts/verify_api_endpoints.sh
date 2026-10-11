#!/bin/sh
#
# CurseForge API 端点连通性验证。
#
# 为什么单独做这个脚本：
#   端点是「硬编码在代码里的字符串」，写错了编译器不报、CI 也过，
#   只有真机跑到那一步才会 404。而验证成本极低（一次 curl）。
#
# 用法：
#   CURSEFORGE_API_KEY=xxx sh scripts/verify_api_endpoints.sh
# 或在 CI 里从 secrets 注入。
#
# 未设置 Key 时跳过（不阻断），只是提示。

set -e

KEY="${CURSEFORGE_API_KEY:-}"
if [ -z "$KEY" ]; then
    # 也支持从仓库里的内置 Key 读（构建期注入的那份）
    KEY=$(grep -o '\$2a\$10\$[A-Za-z0-9./]*' "$(dirname "$0")/../Air2/Core/Addons/A2CurseForgeAPI.m" 2>/dev/null | head -1 || true)
fi

if [ -z "$KEY" ]; then
    echo "（未找到 CurseForge API Key，跳过端点验证）"
    exit 0
fi

BASE="https://api.curseforge.com/v1"
FAIL=0

# 这些路径必须与 A2CurseForgeAPI.m 里写的一致。
# 曾因为把 /mods/search 写成 /mods 导致全线 404。
check() {
    desc="$1"
    path="$2"
    # 请求之间稍作停顿 —— CurseForge 对短时间密集请求会限流，
    # 表现为连不上（curl 返回 000）而不是 429。
    sleep 1
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
           -H "x-api-key: $KEY" -H "Accept: application/json" "$BASE$path" || echo "000")
    # 000 通常是限流或网络抖动，重试一次再判定
    if [ "$code" != "200" ]; then
        sleep 3
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
               -H "x-api-key: $KEY" -H "Accept: application/json" "$BASE$path" || echo "000")
    fi

    if [ "$code" = "200" ]; then
        printf "  ✓ %-30s HTTP %s\n" "$desc" "$code"
    else
        printf "  ✗ %-30s HTTP %s\n" "$desc" "$code"
        FAIL=$((FAIL + 1))
    fi
}

echo "==> CurseForge 端点验证"
check "搜索模组"     "/mods/search?gameId=432&classId=6&pageSize=5"
check "搜索整合包"   "/mods/search?gameId=432&classId=4471&pageSize=5"
check "搜索资源包"   "/mods/search?gameId=432&classId=12&pageSize=5"
check "搜索光影"     "/mods/search?gameId=432&classId=6552&pageSize=5"
check "项目详情"     "/mods/238222"
check "项目文件列表" "/mods/238222/files?pageSize=5"
check "分类列表"     "/categories?gameId=432"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "有 $FAIL 个端点不可用 —— 检查 A2CurseForgeAPI.m 里的路径"
    exit 1
fi

echo "全部端点可用"
