#!/usr/bin/env bash
# Call one MCP tool over HTTP and print its payload.
#
#   MCP_AUTH=claude:secret scripts/mcp-curl.sh query_daily_activity \
#     '{"start_date":"2026-09-22","end_date":"2026-09-29"}'
#
# Three requests are unavoidable: streamable HTTP hands out a session on
# initialize, and the server only accepts calls after notifications/initialized.
# Answers arrive as plain JSON or as an SSE frame, so both are handled.
set -euo pipefail

URL=${MCP_URL:-https://mi-fitness.tarassov.me/mcp}
AUTH=${MCP_AUTH:?MCP_AUTH=user:password required}
TOOL=${1:?tool name required}
ARGS=${2:-'{}'}

curl_mcp() { curl -sS -u "$AUTH" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" "$@"; }

SID=$(curl_mcp -D - -o /dev/null -X POST "$URL" -d '{
  "jsonrpc":"2.0","id":1,"method":"initialize",
  "params":{"protocolVersion":"2025-06-18","capabilities":{},
            "clientInfo":{"name":"mcp-curl","version":"1"}}}' \
  | awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {print $2}' | tr -d '\r')
[ -n "$SID" ] || { echo "no session id from $URL" >&2; exit 1; }

curl_mcp -o /dev/null -H "mcp-session-id: $SID" -X POST "$URL" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl_mcp -H "mcp-session-id: $SID" -X POST "$URL" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",
       \"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}" \
| python3 -c '
import json, sys
raw = sys.stdin.read()
body = "".join(l[6:] for l in raw.splitlines() if l.startswith("data: ")) or raw
msg = json.loads(body)
if "error" in msg:
    sys.exit("MCP error: " + json.dumps(msg["error"], ensure_ascii=False))
block = msg["result"]["content"][0]["text"]
try:
    print(json.dumps(json.loads(block), ensure_ascii=False, indent=2))
except json.JSONDecodeError:
    print(block)
'

curl_mcp -o /dev/null -X DELETE "$URL" -H "mcp-session-id: $SID" || true
