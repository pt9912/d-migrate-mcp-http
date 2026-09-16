#!/usr/bin/env bash
# Round-trip smoke test gegen den lokalen d-migrate MCP-Server (Compose-Stack).
#
# Fahrt: local_pg seeden -> schema_reverse auf allen 5 Connections ->
# schema_generate in 5 Dialekte (status/skippedCount gegen Erwartungsmatrix)
# -> DDL nativ anwenden (MSSQL/MySQL/SQLite/Oracle) -> reverse -> schema_compare
# (PG-Reverse gegen jedes Ziel-Reverse; FK-Assertion + Finding-Zahl).
#
# Gebraucht wird: docker (laufender Stack, `make up`), jq, curl.
# Der SQLite-Leg laeuft im Werkzeug-Image tools/harness-tools (sqlite3 +
# mod_spatialite; der Host hat keine Spatialite-Extension, das d-migrate-Image
# keinen sqlite3-CLI) — es wird bei Bedarf automatisch gebaut.
# Ausgefuehrt:  scripts/roundtrip-smoke.sh [--update-expectations]
#
# Die Erwartungsmatrix liegt in scripts/roundtrip-expectations.env und ist an
# die d-migrate-Version gebunden (siehe Header dort). Bei Versionssprung:
# laufen lassen, Abweichungen pruefen, bewusst neu pinnen. Der MCP-Apply-Pfad
# existiert nicht (die Tools kennen kein "DDL anwenden"), daher die nativen
# Clients in den Compose-Containern.
# Bash >= 4 noetig (assoziative Arrays via declare -A). Muss VOR `set -o
# pipefail` stehen: dash/sh bricht dort sonst mit "Illegal option" ab,
# bevor diese Pruefung greift.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSION%%.*}" -lt 4 ]; then
  echo "FAIL: bash >= 4 noetig (associative arrays). Gefunden: ${BASH_VERSION:-nicht bash}" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "$0")/.."

REPRO_DIR=scripts   # Seed: scripts/roundtrip-repro-postgres.sql
EXPECT_FILE=${EXPECT_FILE:-scripts/roundtrip-expectations.env}   # z.B. EXPECT_FILE=.repro-test/roundtrip-expectations-dev.env für dev-Builds
HARNESS_TOOL_IMAGE=${HARNESS_TOOL_IMAGE:-dmigrate-harness-tools:local}
UPDATE_EXPECT=false
[ "${1:-}" = "--update-expectations" ] && UPDATE_EXPECT=true

MCP_URL=http://127.0.0.1:8787/mcp
PROTOCOL=2025-11-25
# Temp-Verzeichnis UNTER dem Projekt, nicht in $TMPDIR: auf macOS/Colima ist
# /var/folders nicht in den Container gemountet — der Container saehe ein
# leeres Verzeichnis und die Checks wuerden still "0" melden.
TMP_ROOT="$PWD/.repro-test/tmp"
mkdir -p "$TMP_ROOT"
TMP=$(mktemp -d "$TMP_ROOT/run-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

set -a; set +e; . ./.env 2>/dev/null; set -e; set +a   # UID-Zeile in .env ist readonly — Fehler ignorieren, Rest laden

# Fehlerzustand als DATEI: fail() wird auch in Kommandosubstitutionen gerufen,
# eine Variable erreicht das Elternskript von dort nicht.
FAIL_FILE="$TMP_ROOT/failures-$$"
: > "$FAIL_FILE"
fail() { echo "FAIL: $*" >&2; echo "$*" >> "$FAIL_FILE"; }
# Host-Voraussetzungen: NUR docker + jq + curl. Datenbank-Clients, sqlite3 und
# python3 kommen aus den Images (tools/harness-tools, die DB-Container) — der
# Host wird nicht angefasst.
for tool in docker jq curl; do
  command -v "$tool" >/dev/null || fail "$tool fehlt auf dem Host (docker + jq + curl genuegen)"
done
docker compose version >/dev/null 2>&1 || fail "docker compose v2 fehlt"
# Werkzeug-Image fuer den SQLite-/SpatiaLite-Leg (einmalig bauen, dann gecacht)
if ! docker image inspect "$HARNESS_TOOL_IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$HARNESS_TOOL_IMAGE" tools/harness-tools >/dev/null 2>&1 \
    || fail "Werkzeug-Image $HARNESS_TOOL_IMAGE fehlt/baubar? (make harness-tools)"
fi

# ---------------------------------------------------------------- MCP client
# Gemeinsame Bibliothek statt eigener Kopie (die beiden waren schon
# auseinandergelaufen: unterschiedliche Poll-Zahlen und pageSize).
RPC_ID=0
. scripts/lib/mcp-client.sh
mcp_session || exit 1


# ------------------------------------------------------------ 1. Preflight
echo "== 1. Preflight"
for c in d-migrate-postgres d-migrate-mssql d-migrate-mysql d-migrate-oracle d-migrate-mcp; do
  s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo "fehlt")
  [ "$s" = healthy ] || [ "$s" = running ] || fail "$c: $s"
done
# d-migrate-Version protokollieren
mcp_call capabilities_list '{}' | jq -r '"   Server: \(.serverName), MCP \(.mcpProtocolVersion)"'
docker image inspect "$HARNESS_TOOL_IMAGE" >/dev/null 2>&1 || fail "Werkzeug-Image fehlt"
[ ! -s "$FAIL_FILE" ] || { cat "$FAIL_FILE"; exit 1; }

# ------------------------------------------------- 2. local_pg seeden
echo "== 2. local_pg seeden (repro_schema.sql)"
docker exec d-migrate-postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q \
   -c "DROP VIEW IF EXISTS order_summary; DROP TABLE IF EXISTS order_items, orders, products, customers, type_probe, type_matrix; DROP TYPE IF EXISTS order_status; DROP TYPE IF EXISTS mood;"'
docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v ON_ERROR_STOP=1 -q < "$REPRO_DIR/roundtrip-repro-postgres.sql"
# Voraussetzung der Geometrie-Faelle: PostGIS-Schema im search_path, sonst
# liest d-migrate Geometrie ohne geometry_type/srid — still, ohne Finding.
GEOM=$(docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM geometry_columns WHERE f_table_name='type_probe';" 2>/dev/null || echo 0)
[ "${GEOM:-0}" -ge 1 ] || fail "PostGIS-Metadaten fehlen (search_path? init-Skript gelaufen?) — Geometrie-Faelle wuerden still nichts testen"
echo "   OK"

# ------------------------------------------ 3. Reverse auf allen 5 Connections
echo "== 3. schema_reverse auf allen 5 Connections"
SCH_PG=$(reverse_conn local_pg);        echo "   local_pg     -> $SCH_PG"
SCH_MSSQL=$(reverse_conn local_mssql);  echo "   local_mssql  -> $SCH_MSSQL"
SCH_MYSQL=$(reverse_conn local_mysql);  echo "   local_mysql  -> $SCH_MYSQL"
SCH_SQLITE=$(reverse_conn local_sqlite);echo "   local_sqlite -> $SCH_SQLITE"
SCH_ORACLE=$(reverse_conn local_oracle);echo "   local_oracle -> $SCH_ORACLE"

# ---------------------------------- 4. schema_generate in 5 Zieldialekte
echo "== 4. schema_generate (Quelle: local_pg-Reverse) in 5 Dialekte"
declare -A GEN_STATUS GEN_SKIPPED
# spatialProfile je Ziel: nur wo es einen Sinn hat (PG=PostGIS-Typen,
# SQLite=SpatiaLite-Aufrufe). Fuer die anderen wird es weggelassen.
declare -A SPATIAL_PROFILE=([POSTGRESQL]=postgis [SQLITE]=spatialite)
for t in POSTGRESQL MSSQL MYSQL SQLITE ORACLE; do
  args=$(jq -nc --arg ref "dmigrate://tenants/default/schemas/$SCH_PG" --arg t "$t" \
    --arg sp "${SPATIAL_PROFILE[$t]:-}" \
    '{schemaRef:$ref,targetDialect:$t,format:"yaml"} + (if $sp == "" then {} else {spatialProfile:$sp} end)')
  res=$(mcp_call schema_generate "$args")
  GEN_STATUS[$t]=$(echo "$res" | jq -r '.status')
  GEN_SKIPPED[$t]=$(echo "$res" | jq -r '.skippedCount')
  echo "$res" | jq -r '.ddl' > "$TMP/ddl_$t.sql"
  echo "   $t: status=${GEN_STATUS[$t]} skipped=${GEN_SKIPPED[$t]}"
done

check_expect() {  # $1=Key in expectations  $2=Ist-Wert
  local exp; exp=$(grep -E "^$1=" "$EXPECT_FILE" 2>/dev/null | cut -d= -f2 || true)
  if [ -z "$exp" ]; then echo "   (keine Erwartung fuer $1, Ist=$2)"; return 0; fi
  if [ "$exp" = "$2" ]; then echo "   OK  $1=$2"; return 0; fi
  if $UPDATE_EXPECT; then
    sed -i "s/^$1=.*/$1=$2/" "$EXPECT_FILE"
    echo "   PINNED $1=$2 (war $exp)"
  else
    fail "$1: erwartet $exp, gemessen $2"
  fi
}
check_expect GEN_PG_STATUS      "${GEN_STATUS[POSTGRESQL]}"
check_expect GEN_PG_SKIPPED     "${GEN_SKIPPED[POSTGRESQL]}"
check_expect GEN_MSSQL_SKIPPED  "${GEN_SKIPPED[MSSQL]}"
check_expect GEN_MYSQL_SKIPPED  "${GEN_SKIPPED[MYSQL]}"
check_expect GEN_SQLITE_SKIPPED "${GEN_SKIPPED[SQLITE]}"
check_expect GEN_ORACLE_SKIPPED "${GEN_SKIPPED[ORACLE]}"

# ------------------------------------- 5. DDL nativ anwenden (4 Ziele)
echo "== 5. DDL anwenden (nativ)"
# SQLite: Datei neu (im Container geleert), Anwendung im Werkzeug-Image (sqlite3 + mod_spatialite,
# damit AddGeometryColumn/CreateSpatialIndex der SpatiaLite-DDL laufen).
# InitSpatialMetaData ist Pflicht: die generierte DDL ruft nur
# AddGeometryColumn auf, das ohne die Metadatentabellen fehlschlaegt.
# Ausgabe wird geprueft statt verworfen — ein stiller Apply-Fehler waere
# genau das, was dieser Test finden soll.
sqlite_reset
# if ! ... : sqlite3 endet bei SQL-Fehlern != 0 — unter `set -e` wuerde der
# Lauf sonst hier abbrechen, statt den Fehler unten zu melden.
SQLITE_APPLY_RC=0
docker run --rm -i --user "$(id -u):$(id -g)" \
  -v "$PWD/sqlite-data:/data" -v "$TMP:/ddl:ro" \
  --entrypoint sqlite3 "$HARNESS_TOOL_IMAGE" \
  -cmd "PRAGMA trusted_schema=ON;" \
  -cmd "SELECT load_extension('mod_spatialite');" \
  -cmd "SELECT InitSpatialMetaData(1);" \
  /data/local.db < "$TMP/ddl_SQLITE.sql" > "$TMP/sqlite_apply.log" 2>&1 || SQLITE_APPLY_RC=$?
if [ "$SQLITE_APPLY_RC" != 0 ] || grep -qiE '^Error|error:|Parse error|no such|Runtime error' "$TMP/sqlite_apply.log"; then
  sed -n '1,10p' "$TMP/sqlite_apply.log" >&2
  fail "sqlite: DDL-Fehler (Log: $TMP/sqlite_apply.log)"
else
  echo "   sqlite: OK"
fi
# MySQL: Datenbank neu anlegen
docker exec d-migrate-mysql sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS dmigrate; CREATE DATABASE dmigrate;"' 2>/dev/null
MYSQL_APPLY_RC=0
docker exec -i d-migrate-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" dmigrate' \
  > "$TMP/mysql_apply.log" 2>&1 < "$TMP/ddl_MYSQL.sql" || MYSQL_APPLY_RC=$?
if [ "$MYSQL_APPLY_RC" != 0 ] || grep -qiE '^ERROR|ERROR [0-9]+' "$TMP/mysql_apply.log"; then
  sed -n '1,5p' "$TMP/mysql_apply.log" >&2
  fail "mysql: DDL-Fehler (Log: $TMP/mysql_apply.log)"
else
  echo "   mysql: OK"
fi
# MSSQL: Tabellen/View droppen, dann apply
docker exec d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa \
  -P "$MSSQL_SA_PASSWORD" -d dmigrate -Q \
  "IF OBJECT_ID('order_summary','V') IS NOT NULL DROP VIEW order_summary; DROP TABLE IF EXISTS order_items, orders, products, customers, type_probe, type_matrix;" \
  > /dev/null
MSSQL_APPLY_RC=0
docker exec -i d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -b -C -S localhost -U sa \
  -P "$MSSQL_SA_PASSWORD" -d dmigrate \
  < "$TMP/ddl_MSSQL.sql" > "$TMP/mssql_apply.log" 2>&1 || MSSQL_APPLY_RC=$?
if [ "$MSSQL_APPLY_RC" != 0 ] || grep -qiE 'Msg [0-9]+, Level|^Sqlcmd: Error|Login failed|Cannot open database' "$TMP/mssql_apply.log"; then
  sed -n '1,5p' "$TMP/mssql_apply.log" >&2
  fail "mssql: DDL-Fehler (Log: $TMP/mssql_apply.log)"
else
  echo "   mssql: OK"
fi
# Oracle: Tabellen/View droppen, dann apply (generierte DDL endet auf ';;').
# Achtung: die generierte DDL quotet alle Identifier, d.h. die Objekte heissen
# in user_objects kleingeschrieben ('customers') — deshalb UPPER()-Vergleich.
docker exec -i d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 \
  >/dev/null <<'EOF'
BEGIN FOR o IN (SELECT object_name, object_type FROM user_objects WHERE UPPER(object_name) IN ('ORDER_SUMMARY','ORDER_ITEMS','ORDERS','PRODUCTS','CUSTOMERS','TYPE_PROBE','TYPE_MATRIX') ORDER BY DECODE(object_type,'VIEW',1,2)) LOOP EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"'; END LOOP; END;
/
EOF
{ echo "WHENEVER SQLERROR EXIT FAILURE"; sed 's/;;/;/g' "$TMP/ddl_ORACLE.sql"; } > "$TMP/ddl_ORACLE_norm.sql"
docker cp "$TMP/ddl_ORACLE_norm.sql" d-migrate-oracle:/tmp/smoke_ddl.sql >/dev/null
ORACLE_APPLY_RC=0
docker exec d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 \
  @/tmp/smoke_ddl.sql > "$TMP/oracle_apply.log" 2>&1 || ORACLE_APPLY_RC=$?
# nur Zeilenanfang-Fehler zaehlen: die DDL-Kommentare enthalten "ORA-02329" etc.
if [ "$ORACLE_APPLY_RC" != 0 ] || grep -qE '^(ORA-|SP2-|ERROR at)' "$TMP/oracle_apply.log"; then
  sed -n '1,5p' "$TMP/oracle_apply.log" >&2
  fail "oracle: DDL-Fehler (Log: $TMP/oracle_apply.log)"
else
  echo "   oracle: OK"
fi

# ------------------------------------------ 6. Reverse der 4 Ziele
echo "== 6. schema_reverse der 4 angewendeten Ziele"
RT_MSSQL=$(reverse_conn local_mssql);   echo "   local_mssql  -> $RT_MSSQL"
RT_MYSQL=$(reverse_conn local_mysql);   echo "   local_mysql  -> $RT_MYSQL"
RT_SQLITE=$(reverse_conn local_sqlite); echo "   local_sqlite -> $RT_SQLITE"
RT_ORACLE=$(reverse_conn local_oracle); echo "   local_oracle -> $RT_ORACLE"

# ------------------------------- 7. Compare PG-Reverse vs. jedes Ziel-Reverse
echo "== 7. schema_compare: PG-Reverse gegen jedes Ziel-Reverse"
declare -A RT_SCH=([MSSQL]=$RT_MSSQL [MYSQL]=$RT_MYSQL [SQLITE]=$RT_SQLITE [ORACLE]=$RT_ORACLE)
declare -A COMPARE_N
for t in MSSQL MYSQL SQLITE ORACLE; do
  res=$(mcp_call schema_compare \
    "{\"left\":{\"schemaRef\":\"dmigrate://tenants/default/schemas/$SCH_PG\"},\"right\":{\"schemaRef\":\"dmigrate://tenants/default/schemas/${RT_SCH[$t]}\"},\"format\":\"yaml\"}")
  COMPARE_N[$t]=$(echo "$res" | jq '.findings | length')
  # FK-Assertion: die zwei NO-ACTION-FKs werden auf beiden Seiten gefaltet und
  # duerfen NIE erscheinen. Der RESTRICT-FK (orders_customer_id_fkey) dagegen
  # ist ein dokumentierter echter Aktionsunterschied (MSSQL/Oracle kennen kein
  # RESTRICT) und darf melden.
  fk=$(echo "$res" | jq -r '[.findings[].path // ""] | map(select(test("order_items_order_id_fkey|order_items_product_id_fkey"))) | length')
  if [ "$fk" != 0 ]; then
    fail "$t: $fk FK-Finding(s) auf NO-ACTION-FKs (Falschalarm-Klasse!)"
  else
    echo "   $t: ${COMPARE_N[$t]} Findings, 0 FK-Findings auf den NO-ACTION-FKs"
  fi
  check_expect "COMPARE_$t" "${COMPARE_N[$t]}"
done

# ------------------------------------------------------------- 8. Bericht
echo
echo "== Bericht"
printf '   %-10s %-12s %-8s %-10s\n' Ziel 'gen skipped' 'status' 'compare'
printf '   %-10s %-12s %-8s %-10s\n' MSSQL "${GEN_SKIPPED[MSSQL]}" "${GEN_STATUS[MSSQL]}" "${COMPARE_N[MSSQL]}"
printf '   %-10s %-12s %-8s %-10s\n' MYSQL "${GEN_SKIPPED[MYSQL]}" "${GEN_STATUS[MYSQL]}" "${COMPARE_N[MYSQL]}"
printf '   %-10s %-12s %-8s %-10s\n' SQLITE "${GEN_SKIPPED[SQLITE]}" "${GEN_STATUS[SQLITE]}" "${COMPARE_N[SQLITE]}"
printf '   %-10s %-12s %-8s %-10s\n' ORACLE "${GEN_SKIPPED[ORACLE]}" "${GEN_STATUS[ORACLE]}" "${COMPARE_N[ORACLE]}"

if [ ! -s "$FAIL_FILE" ]; then
  echo "SMOKE OK"
else
  echo "== Fehler:"
  cat "$FAIL_FILE"
  echo "SMOKE FEHLGESCHLAGEN — Abweichungen oben. Nach Pruefung: --update-expectations"
  exit 1
fi