#!/bin/sh
#
# Air2 协作房 MCP 调用助手
#
# 用法：
#   ./mcp.sh tools/list
#   ./mcp.sh call room_whoami '{}'
#   ./mcp.sh call room_register '{"name":"Minis","client":"Minis"}'
#   ./mcp.sh call room_digest '{"cursor":0}'
#
# 说明：
#   MCP 是 JSON-RPC over HTTP（Streamable HTTP）。
#   需要环境变量 MCP_TOKEN（Bearer 鉴权）。
#   响应可能是 SSE 格式（event: message\ndata: {...}），这里会剥出 data 行。
#
set -e

ENDPOINT="${MCP_ENDPOINT:-https://mcp.air-devs.top/mcp}"

if [ -z "$MCP_TOKEN" ]; then
    echo "错误：未设置 MCP_TOKEN 环境变量" >&2
    exit 1
fi

# 用户填的 token 可能自带 "Bearer " 前缀 —— 剥掉再统一加，
# 否则会拼成 "Bearer Bearer xxx"（服务端报 unauthorized）
AUTH="$MCP_TOKEN"
case "$AUTH" in
    Bearer\ *|bearer\ *) AUTH="${AUTH#* }" ;;
esac

# Session id 缓存文件 —— MCP 要求 initialize 后所有请求带上
SESSION_FILE="/tmp/.mcp_session_$$"
# 同一会话内复用（用固定路径，多次调用共享）
SESSION_FILE="/tmp/.air2_mcp_session"

# 统一的请求函数。$1 = JSON body，$2 = 是否保存 session（1=保存）
do_post() {
    hdr_file="/tmp/.air2_mcp_hdr"
    resp=$(curl -s -D "$hdr_file" -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $AUTH" \
        ${SESSION_ID:+-H "Mcp-Session-Id: $SESSION_ID"} \
        -d "$1" \
        --max-time 30)

    # initialize 响应里会带 Mcp-Session-Id，存下来供后续请求用
    new_sid=$(grep -i "^mcp-session-id:" "$hdr_file" 2>/dev/null | sed 's/^[^:]*: *//' | tr -d '\r')
    if [ -n "$new_sid" ]; then
        printf '%s' "$new_sid" > "$SESSION_FILE"
        SESSION_ID="$new_sid"
    fi

    printf '%s' "$resp"
}

# 读取已保存的 session
[ -f "$SESSION_FILE" ] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null)

# 剥离 SSE 包装：取最后一条 data: 行
strip_sse() {
    awk '
        /^data: / { sub(/^data: /, ""); last = $0 }
        !/^data: / && !/^event: / && NF > 0 { last = $0 }
        END { if (last != "") print last }
    '
}

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in
    tools/list)
        do_post '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | strip_sse
        ;;

    call)
        tool="${1:-}"
        args="${2:-{\}}"
        if [ -z "$tool" ]; then
            echo "用法：mcp.sh call <tool_name> '<json_args>'" >&2
            exit 1
        fi
        # 构造 tools/call 请求
        body=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool" "$args")
        do_post "$body" | strip_sse
        ;;

    init)
        do_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"air2-mcp-cli","version":"1.0"}}}' | strip_sse
        ;;

    *)
        cat <<EOF
Air2 MCP CLI

  mcp.sh init                         —— 初始化握手（看服务版本）
  mcp.sh tools/list                   —— 列出全部工具
  mcp.sh call <tool> '<json_args>'    —— 调用工具

示例：
  mcp.sh call room_whoami '{}'
  mcp.sh call room_register '{"name":"Minis","client":"Minis"}'
  mcp.sh call room_digest '{"cursor":0}'
EOF
        ;;
esac
