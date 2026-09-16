#!/usr/bin/env bash
# Latenz-/Warmup-Benchmark gegen den lokalen d-migrate-MCP-Server.
# Misst in ms: statische Calls (capabilities_list), State-Store-Reads
# (schema_list), DDL-Rendering (schema_generate x5 Dialekte gegen ein
# gepinntes Schema) — und mit --restart den Kaltstart (Container-Neustart
# bis zum ersten erfolgreichen initialize).
# Aufruf:  ./scripts/mcp-bench.sh [--restart] [schemaRef]
#          (schemaRef default: neuestes PostgreSQL-Reverse im Store)
# Bash >= 4 noetig. Muss VOR `set -o pipefail` stehen: dash/sh bricht dort
# sonst mit "Illegal option" ab, bevor diese Pruefung greift.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSION%%.*}" -lt 4 ]; then
  echo "FAIL: bash >= 4 noetig. Gefunden: ${BASH_VERSION:-nicht bash}" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "$0")/.."

PROTOCOL=2025-11-25
MCP_URL=http://127.0.0.1:8787/mcp
N_FAST=${N_FAST:-40}
N_STORE=${N_STORE:-20}
N_GEN=${N_GEN:-10}          # pro Dialekt
RESTART=false
[ "${1:-}" = "--restart" ] && { RESTART=true; shift; }
SMOKE_SCHEMA_REF=${1:-}
# Temp-Verzeichnis UNTER dem Projekt (auf macOS/Colima ist $TMPDIR nicht in
# Container gemountet) und im Fehlerfall stehen lassen — dann sind Logs/Dateien
# noch da, wenn man sie braucht.
TMP_ROOT="$PWD/.repro-test/tmp"
mkdir -p "$TMP_ROOT"
TMP=$(mktemp -d "$TMP_ROOT/run-XXXXXX")
cleanup() {
  if [ "${1:-0}" != 0 ]; then
    echo "== Lauf fehlgeschlagen — Temp bleibt liegen: $TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap 'cleanup $?' EXIT

set -a; set +e; . ./.env 2>/dev/null; set -e; set +a

stats() { sort -n | awk '{a[NR]=$1} END { if (NR==0) {print "(keine Messwerte)"; exit} if (NR%2) m=a[(NR+1)/2]; else m=(a[NR/2]+a[NR/2+1])/2; s=0; for(i=1;i<=NR;i++) s+=a[i]; printf "%5d %5d %5d %5d  n=%d\n", m, s/NR, a[1], a[NR], NR }'; }

rpc_file() { # $1 = payload-Datei -> stdout
  curl -sf -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Session-Id: $SESSION" -H "MCP-Protocol-Version: $PROTOCOL" \
    -d @"$1"
}

session_new() {
  SESSION=$(curl -sf -D - -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"'$PROTOCOL'","capabilities":{},"clientInfo":{"name":"mcp-bench","version":"0.1"}}}' \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')
  [ -n "$SESSION" ] || { echo "FAIL: kein MCP-Server auf $MCP_URL" >&2; return 1; }
  curl -sf -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Session-Id: $SESSION" -H "MCP-Protocol-Version: $PROTOCOL" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}

# ---- optional: Kaltstart messen (Container-Neustart bis erster initialize)
if $RESTART; then
  echo "== Kaltstart"
  docker compose restart d-migrate-mcp >/dev/null
  T0=$(date +%s%N)
  until curl -sf -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"'$PROTOCOL'","capabilities":{},"clientInfo":{"name":"mcp-bench","version":"0.1"}}}'; do
    sleep 0.2
  done
  T1=$(date +%s%N)
  echo "  bis MCP antwortet: $(( (T1 - T0) / 1000000 )) ms"
  sleep 1   # Session-Header abwarten; frische Session unten
fi

session_new

# ---- SMOKE_SCHEMA_REF: neuestes PostgreSQL-Reverse aus dem Store
if [ -z "$SMOKE_SCHEMA_REF" ]; then
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"schema_list","arguments":{"pageSize":40}}}' > "$TMP/pl.json"
  SMOKE_SCHEMA_REF=$(rpc_file "$TMP/pl.json" 2>/dev/null | jq -r '.result.content[0].text // empty' 2>/dev/null \
    | jq -r '[.schemas[] | select(.origin=="schema_reverse")][0].resourceUri // empty' 2>/dev/null || true)
fi
if [ -z "$SMOKE_SCHEMA_REF" ]; then
  echo "WARN: kein PG-Reverse-Schema im Store — schema_generate-Sektion entfaellt" >&2
fi
echo "== Messphase: fast=$N_FAST store=$N_STORE generate=$N_GEN/Dialekt"

# ---- 1. capabilities_list (statisch)
for i in $(seq 1 "$N_FAST"); do
  echo "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/call\",\"params\":{\"name\":\"capabilities_list\",\"arguments\":{}}}" > "$TMP/p.json"
  T0=$(date +%s%N); rpc_file "$TMP/p.json" >/dev/null; T1=$(date +%s%N)
  echo $(( (T1 - T0) / 1000000 )) >> "$TMP/fast.txt"
done

# ---- 2. schema_list (State-Store/DB)
for i in $(seq 1 "$N_STORE"); do
  echo "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/call\",\"params\":{\"name\":\"schema_list\",\"arguments\":{\"pageSize\":40}}}" > "$TMP/p.json"
  T0=$(date +%s%N); rpc_file "$TMP/p.json" >/dev/null; T1=$(date +%s%N)
  echo $(( (T1 - T0) / 1000000 )) >> "$TMP/store.txt"
done

# ---- 3. schema_generate (Render-Last, x5 Dialekte)
if [ -n "$SMOKE_SCHEMA_REF" ]; then
  for t in POSTGRESQL MSSQL MYSQL SQLITE ORACLE; do
    for i in $(seq 1 "$N_GEN"); do
      jq -nc --arg ref "$SMOKE_SCHEMA_REF" --arg t "$t" \
        '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"schema_generate",arguments:{schemaRef:$ref,targetDialect:$t}}}' > "$TMP/p.json"
      T0=$(date +%s%N); rpc_file "$TMP/p.json" >/dev/null; T1=$(date +%s%N)
      echo $(( (T1 - T0) / 1000000 )) >> "$TMP/gen.txt"
    done
  done
fi

echo "== Ergebnis (ms): median mean min max n"
printf '  capabilities_list : '; stats < "$TMP/fast.txt"
[ -f "$TMP/store.txt" ] && { printf '  schema_list       : '; stats < "$TMP/store.txt"; }
[ -f "$TMP/gen.txt" ] && { printf '  schema_generate   : '; stats < "$TMP/gen.txt"; }