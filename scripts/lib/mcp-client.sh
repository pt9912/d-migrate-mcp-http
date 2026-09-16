# Gemeinsamer MCP-HTTP-Client (JSON-RPC ueber /mcp) fuer die Skripte in
# scripts/. Wird von type-matrix.sh benutzt; roundtrip-smoke.sh traegt noch
# eine eigene Kopie (bewusst nicht angefasst, um den laufenden Smoke nicht
# umzubauen).
#
# Erwartet vom Aufrufer: MCP_URL, PROTOCOL, jq/curl vorhanden, eine
# fail()-Funktion. Setzt SESSION.

mcp_session() {
  local sid
  sid=$(curl -sf -D - -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "$(jq -nc '{jsonrpc:"2.0",id:0,method:"initialize",params:{protocolVersion:$p,capabilities:{},clientInfo:{name:"mcp-script",version:"0.1"}}}' --arg p "$PROTOCOL")" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')
  [ -n "$sid" ] || { echo "FAIL: kein MCP-Server auf $MCP_URL" >&2; return 1; }
  curl -sf -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Session-Id: $sid" -H "MCP-Protocol-Version: $PROTOCOL" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  SESSION="$sid"
}

# $1=tool $2=args-json -> stdout: Tool-Ergebnis (JSON-Text)
mcp_call() {
  RPC_ID=$((RPC_ID + 1))
  local body
  body=$(jq -nc --argjson id "$RPC_ID" --arg tool "$1" --argjson args "$2" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$tool,arguments:$args}}')
  curl -sf -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Session-Id: $SESSION" -H "MCP-Protocol-Version: $PROTOCOL" \
    -d "$body" | jq -re '.result.content[0].text'
}

# $1=jobId -> stdout: Job-Ergebnis; wartet bis terminal
await_job() {
  local st res
  for _ in $(seq 1 90); do
    res=$(mcp_call job_status_get "{\"jobId\":\"$1\"}")
    st=$(echo "$res" | jq -r '.status')
    case "$st" in
      SUCCEEDED) echo "$res"; return 0 ;;
      FAILED|CANCELLED)
        fail "Job $1 endete: $st — $(echo "$res" | jq -r '.error.message // .error.code // "ohne Fehlerangabe"' 2>/dev/null)"
        return 1 ;;
    esac
    sleep 2
  done
  fail "Job $1: Timeout"; return 1
}

# $1=schemaId -> stdout: artifactId (fuer artifact_chunk_get)
artifact_of_schema() {
  mcp_call schema_list '{"pageSize":60}' | jq -r --arg s "$1" \
    '.schemas[] | select(.schemaId==$s) | .artifactRef'
}

# $1=connectionName [$2=includes als JSON-Array, z.B. '["type_matrix"]']
#   -> stdout: schemaId des Reverse-Artefakts
reverse_conn() {
  local job res art args
  args=$(jq -nc --arg c "dmigrate://tenants/default/connections/$1" \
    --arg k "rev-$(date +%s)-$1-$RANDOM" --argjson inc "${2:-null}" \
    '{connectionId:$c,idempotencyKey:$k} + (if $inc==null then {} else {includes:$inc} end)')
  job=$(mcp_call schema_reverse_start "$args" | jq -r '.jobId')
  res=$(await_job "$job") || return 1
  art=$(echo "$res" | jq -r '.artifacts[0]' | sed 's|.*/artifacts/||')
  mcp_call schema_list '{"pageSize":60}' | jq -r --arg a "$art" \
    '.schemas[] | select(.artifactRef==$a) | .schemaId'
}
