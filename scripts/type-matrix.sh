#!/usr/bin/env bash
# Typ-Matrix: 5x5 ueber alle Dialekte.
#
# Fuer jeden Dialekt wird ein natives Typ-Schema geseedet (scripts/types/),
# per schema_reverse exportiert, in alle vier anderen Dialekte generiert,
# dort angewendet, wieder zurueckgelesen und gegen das Quell-Reverse
# verglichen. Ausgabe ist eine Matrix (Findings je Zelle) plus eine
# Code-Uebersicht — gedacht als flaechendeckende Sonde fuer Typverluste
# (still degradiert vs. gemeldet) und als reproduzierbarer Beleg fuer
# Befunde an d-migrate.
#
# Aufruf:  scripts/type-matrix.sh [--keep]      (--keep laesst die Tabellen stehen)
# Gebraucht: laufender Stack (make up), jq, curl, docker; SQLite-Legs laufen
# im Werkzeug-Image tools/harness-tools (wird bei Bedarf gebaut).
# Bash >= 4 noetig — MUSS vor `set -o pipefail` stehen: sh/dash bricht dort
# sonst mit "Illegal option" ab, bevor diese Pruefung greift.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSION%%.*}" -lt 4 ]; then
  echo "FAIL: bash >= 4 noetig (assoziative Arrays). Gefunden: ${BASH_VERSION:-nicht bash}" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "$0")/.."

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

MCP_URL=http://127.0.0.1:8787/mcp
PROTOCOL=2025-11-25
HARNESS_TOOL_IMAGE=${HARNESS_TOOL_IMAGE:-dmigrate-harness-tools:local}
PYTHON_IMAGE=${PYTHON_IMAGE:-dmigrate-harness-python:local}   # Stage 'py' aus tools/harness-tools
# Temp-Verzeichnis UNTER dem Projekt, nicht in $TMPDIR: auf macOS/Colima ist
# /var/folders nicht in den Container gemountet — der Container saehe ein
# leeres Verzeichnis und die Checks wuerden still "0" melden.
TMP_ROOT="$PWD/.repro-test/tmp"
mkdir -p "$TMP_ROOT"
TMP=$(mktemp -d "$TMP_ROOT/run-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

set -a; set +e; . ./.env 2>/dev/null; set -e; set +a

# Fehlerzustand als DATEI, nicht als Variable: fail() wird auch aus
# Kommandosubstitutionen ($(silent_losses_of ...)) gerufen, und eine dort
# gesetzte Variable erreicht das Elternskript nie (frueher: Exit 0 auf einem
# komplett kaputten Lauf).
FAIL_FILE="$TMP_ROOT/failures-$$"
: > "$FAIL_FILE"
fail() { echo "FAIL: $*" >&2; echo "$*" >> "$FAIL_FILE"; }

command -v jq >/dev/null || { echo "FAIL: jq fehlt" >&2; exit 1; }
docker image inspect "$HARNESS_TOOL_IMAGE" >/dev/null 2>&1 \
  || docker build -q -t "$HARNESS_TOOL_IMAGE" tools/harness-tools >/dev/null
docker image inspect "$PYTHON_IMAGE" >/dev/null 2>&1 \
  || docker build -q --target py -t "$PYTHON_IMAGE" tools/harness-tools >/dev/null

RPC_ID=0
. scripts/lib/mcp-client.sh
mcp_session || exit 1

DIALECTS="PG MSSQL MYSQL SQLITE ORACLE"
conn_of() { case "$1" in PG) echo local_pg;; MSSQL) echo local_mssql;; MYSQL) echo local_mysql;; SQLITE) echo local_sqlite;; ORACLE) echo local_oracle;; esac; }
# spatialProfile nur wo sinnvoll (PG=PostGIS, SQLite=SpatiaLite)
profile_of() { case "$1" in PG) echo postgis;; SQLITE) echo spatialite;; *) echo "";; esac; }
# Kurzlabel -> Dialektname der API (PG heisst dort POSTGRESQL)
api_of() { case "$1" in PG) echo POSTGRESQL;; *) echo "$1";; esac; }

# ---------------------------------------------------------------- Seed je Dialekt
seed_pg() {
  docker exec -i d-migrate-postgres sh -c \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -c "DROP TABLE IF EXISTS type_matrix; DROP TYPE IF EXISTS mood;"'
  docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q < scripts/types/pg.sql
}
seed_mssql() {
  docker exec -i d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa \
    -P "$MSSQL_SA_PASSWORD" -d dmigrate -i /dev/stdin < scripts/types/mssql.sql >/dev/null
}
seed_mysql() {
  docker exec -i d-migrate-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" dmigrate' 2>/dev/null < scripts/types/mysql.sql
}
seed_oracle() {
  docker exec -i d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 \
    < <(sed 's/;;/;/g' scripts/types/oracle.sql) >/dev/null
  # Metadaten fuer einen spaeteren Spatial-Index sind hier nicht noetig; nur aufraeumen:
  docker exec -i d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 \
    <<'SQL' >/dev/null
DELETE FROM USER_SDO_GEOM_METADATA WHERE TABLE_NAME='type_matrix';
COMMIT;
SQL
}
seed_sqlite() {
  rm -f sqlite-data/local.db
  # Kein `|| true`: ein fehlgeschlagener Seed (z.B. weil mod_spatialite nicht
  # ladbar ist) muss den Lauf scheitern lassen, nicht eine leere Datei
  # hinterlassen — sonst meldet die Matrix spaeter "?"/"0" statt Fehler.
  docker run --rm -i --user "$(id -u):$(id -g)" -v "$PWD/sqlite-data:/data" \
    --entrypoint sqlite3 "$HARNESS_TOOL_IMAGE" /data/local.db < scripts/types/sqlite.sql > "$TMP/seed_sqlite.log" 2>&1 \
    || { sed -n '1,5p' "$TMP/seed_sqlite.log" >&2; return 1; }
  grep -qiE '^Error|error:|Parse error|no such' "$TMP/seed_sqlite.log" && { sed -n '1,5p' "$TMP/seed_sqlite.log" >&2; return 1; }
  return 0
}
seed_of() { case "$1" in PG) seed_pg;; MSSQL) seed_mssql;; MYSQL) seed_mysql;; SQLITE) seed_sqlite;; ORACLE) seed_oracle;; esac; }

# Voraussetzung der Geometrie-Faelle: PostGIS-Schema im search_path. Fehlt sie,
# liest d-migrate Geometrie ohne geometry_type/srid — die Zellen blieben gruen,
# ohne etwas zu testen.
assert_pg_geometry() {
  local n
  n=$(docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT count(*) FROM geometry_columns WHERE f_table_name='type_matrix';" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] || fail "PostGIS-Metadaten fehlen (search_path? postgres-init gelaufen?) — Geometrie-Zellen wuerden still nichts testen"
}

# --------------------------------------------------------------- Apply je Dialekt
# $1=Dialekt $2=DDL-Datei; Rueckgabe != 0 bei Fehler
apply_pg() {
  docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q < "$2" > "$TMP/apply_$1.log" 2>&1
}
apply_mssql() {
  # -b: sqlcmd liefert sonst Exit 0 auch bei SQL-Fehlern; zusaetzlich das Log
  # pruefen, weil Verbindungsfehler (Container weg, Login abgelehnt) kein
  # "Msg ..., Level 1x" tragen.
  docker exec -i d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -b -C -S localhost -U sa \
    -P "$MSSQL_SA_PASSWORD" -d dmigrate < "$2" > "$TMP/apply_$1.log" 2>&1
  ! grep -qiE 'Msg [0-9]+, Level|^Sqlcmd: Error|Cannot open database|Login failed' "$TMP/apply_$1.log"
}
apply_mysql() {
  # Exit-Code UND Log: der Client endet bei Fehlern != 0, schreibt die Meldung
  # aber nach stderr — beides pruefen, sonst gilt ein Abbruch als Erfolg.
  if ! docker exec -i d-migrate-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" dmigrate' > "$TMP/apply_$1.log" 2>&1 < "$2"; then
    return 1
  fi
  ! grep -qiE '^ERROR|ERROR [0-9]+' "$TMP/apply_$1.log"
}
apply_oracle() {
  # WHENEVER SQLERROR EXIT FAILURE: sqlplus endet sonst mit 0 trotz ORA-Fehler
  { echo "WHENEVER SQLERROR EXIT FAILURE"; sed 's/;;/;/g' "$2"; } > "$TMP/ddl_ora_norm.sql"
  docker cp "$TMP/ddl_ora_norm.sql" d-migrate-oracle:/tmp/matrix_ddl.sql >/dev/null
  if ! docker exec d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 \
       @/tmp/matrix_ddl.sql > "$TMP/apply_$1.log" 2>&1; then
    return 1
  fi
  ! grep -qE '^(ORA-|SP2-|ERROR at)' "$TMP/apply_$1.log"
}
apply_sqlite() {
  # Exit-Code UND Log: sqlite3 meldet Laufzeitfehler als
  # "Runtime error near line N: ..." — das faengt kein '^Error'.
  if ! docker run --rm -i --user "$(id -u):$(id -g)" \
       -v "$PWD/sqlite-data:/data" -v "$(dirname "$2"):/ddl:ro" \
       --entrypoint sqlite3 "$HARNESS_TOOL_IMAGE" \
       -cmd "PRAGMA trusted_schema=ON;" \
       -cmd "SELECT load_extension('mod_spatialite');" \
       -cmd "SELECT InitSpatialMetaData(1);" \
       /data/local.db < "$2" > "$TMP/apply_$1.log" 2>&1; then
    return 1
  fi
  ! grep -qiE '^Error|error:|Parse error|no such|Runtime error' "$TMP/apply_$1.log"
}
apply_of() { local d="$1" f="$2"; case "$d" in PG) apply_pg "$d" "$f";; MSSQL) apply_mssql "$d" "$f";; MYSQL) apply_mysql "$d" "$f";; SQLITE) apply_sqlite "$d" "$f";; ORACLE) apply_oracle "$d" "$f";; esac; }

# --------------------------------------------------------------- Cleanup je Dialekt
# Die Matrix LEERT die Testdatenbanken (statt zu filtern): schema_reverse_start
# ignoriert includes/excludes nachweislich, ein Reverse traegt also die ganze
# Schemaflaeche — und ein Apply wuerde mit liegengebliebenen Tabellen
# kollidieren. PG behaelt das PostGIS-Schema (eigene Extension-Schemas sind
# nicht Teil von public); dmigrate_state liegt ebenfalls ausserhalb.
clean_pg() {
  docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q \
    -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;" 2>/dev/null || true
}
clean_mssql() {
  # Erst alle FKs loesen (sonst schlaegt das DROP der referenzierten Tabellen
  # fehl und es bleiben Reste stehen -> Matrix wird nicht deterministisch),
  # dann Tabellen/Views/Sequenzen.
  docker exec -i d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa \
    -P "$MSSQL_SA_PASSWORD" -d dmigrate -Q "
      DECLARE @fk NVARCHAR(MAX) = N'';
      SELECT @fk = @fk + N'ALTER TABLE [' + OBJECT_SCHEMA_NAME(parent_object_id) + N'].[' + OBJECT_NAME(parent_object_id)
                 + N'] DROP CONSTRAINT [' + name + N'];'
        FROM sys.foreign_keys;
      IF LEN(@fk) > 0 EXEC sp_executesql @fk;
      DECLARE @s NVARCHAR(MAX) = N'';
      SELECT @s = @s + N'DROP ' + CASE WHEN type='V' THEN 'VIEW' ELSE 'TABLE' END + N' [' + name + N'];'
        FROM sys.objects WHERE type IN ('U','V') AND is_ms_shipped = 0;
      SELECT @s = @s + N'DROP SEQUENCE [' + name + N'];' FROM sys.sequences WHERE is_ms_shipped = 0;
      IF LEN(@s) > 0 EXEC sp_executesql @s;" >/dev/null 2>&1 || true
}
clean_mysql() {
  docker exec -i d-migrate-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS dmigrate; CREATE DATABASE dmigrate;"' 2>/dev/null || true
}
clean_oracle() {
  # Jeder Drop einzeln mit eigener Exception-Klausel: ein FK-gebundenes DROP
  # (ORA-02449) brach sonst den ganzen Block ab und liess den Rest stehen.
  # CASCADE CONSTRAINTS + PURGE RECYCLEBIN raeumen die Abhaengigkeiten mit ab.
  docker exec -i d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 >/dev/null 2>&1 <<'SQL' || true
BEGIN
  FOR o IN (SELECT object_name, object_type FROM user_objects
             WHERE object_type IN ('TABLE','VIEW','SEQUENCE') AND object_name NOT LIKE 'SYS_%') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"' ||
        CASE o.object_type WHEN 'TABLE' THEN ' CASCADE CONSTRAINTS PURGE' ELSE '' END;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/
PURGE RECYCLEBIN;
DELETE FROM USER_SDO_GEOM_METADATA;
COMMIT;
SQL
}
clean_sqlite() { rm -f sqlite-data/local.db; }
clean_of() { case "$1" in PG) clean_pg;; MSSQL) clean_mssql;; MYSQL) clean_mysql;; SQLITE) clean_sqlite;; ORACLE) clean_oracle;; esac; }

# ------------------------------------------- Stille Typverluste (zweite Achse)
# Vergleicht den QUELL-KATALOG mit dem neutralen Modell: Spalten, deren
# Quelltyp spezifisch ist, im Modell aber auf text/char landen (oder als enum
# mit haengendem ref_type), tauchen im Quell<->Ziel-Vergleich NICHT auf — beide
# Seiten sind dort gleichermassen verflacht. SQLite bleibt ausgenommen: seine
# deklarierten Typnamen sind nominal, es gibt dort nichts zu verlieren.
native_types_pg() {
  docker exec -i d-migrate-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT column_name || '|' || data_type FROM information_schema.columns WHERE table_name='type_matrix' ORDER BY ordinal_position" 2>/dev/null
}
native_types_mssql() {
  docker exec -i d-migrate-mssql /opt/mssql-tools18/bin/sqlcmd -b -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" \
    -d dmigrate -W -s'|' -h-1 -Q "SELECT c.name + '|' + t.name FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id WHERE c.object_id=OBJECT_ID('type_matrix') ORDER BY c.column_id" 2>/dev/null
}
native_types_mysql() {
  docker exec -i d-migrate-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT CONCAT(COLUMN_NAME,'"'"'|'"'"',COLUMN_TYPE) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='"'"'type_matrix'"'"' ORDER BY ORDINAL_POSITION" dmigrate' 2>/dev/null
}
native_types_oracle() {
  docker exec -i d-migrate-oracle sqlplus -S dmigrate/"$ORACLE_PASSWORD"@localhost:1521/FREEPDB1 <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF TRIMSPOOL ON LINESIZE 200
SELECT LOWER(column_name) || '|' || data_type FROM user_tab_columns WHERE UPPER(table_name) = 'TYPE_MATRIX' ORDER BY column_id;
EXIT
SQL
}
silent_losses_of() {  # $1=Dialekt $2=schemaId -> stdout: "spalte|quelltyp|neutraltyp"
  [ "$1" = "SQLITE" ] && return 0
  local nat="$TMP/native_$1.txt" art out rc=0
  # Kein stilles Verschlucken: jede Stufe meldet ihren Fehler und die Zelle
  # erscheint als CHECK-FEHLER statt als "0" (eine Pruefung, die bei einem
  # Ausfuehrungsfehler Entwarnung gibt, ist schlimmer als keine Pruefung).
  if ! "native_types_$(echo "$1" | tr 'A-Z' 'a-z')" > "$nat" 2>"$TMP/native_$1.err"; then
    fail "Quellkatalog-Abfrage $1 fehlgeschlagen: $(head -c 160 "$TMP/native_$1.err" | tr '\n' ' ')"
    echo "CHECK-FEHLER|$1|katalog"; return 0
  fi
  art=$(artifact_of_schema "$2")
  [ -n "$art" ] || { fail "kein Artefakt zum Schema $2 ($1)"; echo "CHECK-FEHLER|$1|artefakt"; return 0; }
  # ALLE Chunks lesen: ein Artefakt > 32 KiB wird sonst stillschweigend
  # abgeschnitten, und ein Fehlerobjekt liefert den Text "null" mit rc 0.
  : > "$TMP/neutral_$1.yaml"
  local chunk="" cursor="null" guard=0
  while :; do
    if [ "$cursor" = "null" ]; then
      payload=$(jq -nc --arg a "$art" '{artifactId:$a}')
    else
      payload=$(jq -nc --arg a "$art" --arg c "$cursor" '{artifactId:$a,nextChunkCursor:$c}')
    fi
    if ! chunk=$(mcp_call artifact_chunk_get "$payload" 2>/dev/null); then
      fail "Artefakt $1 nicht lesbar (Chunk-Abruf)"; echo "CHECK-FEHLER|$1|artefakt"; return 0
    fi
    if ! printf '%s' "$chunk" | jq -e '.text' >/dev/null 2>&1; then
      fail "Artefakt $1 lieferte Fehlerobjekt: $(printf '%s' "$chunk" | jq -r '.code // "?"' 2>/dev/null)"
      echo "CHECK-FEHLER|$1|artefakt"; return 0
    fi
    printf '%s' "$chunk" | jq -r '.text' >> "$TMP/neutral_$1.yaml"
    cursor=$(printf '%s' "$chunk" | jq -r '.nextChunkCursor // "null"')
    [ "$cursor" = "null" ] && break
    guard=$((guard + 1)); [ "$guard" -gt 40 ] && { fail "Artefakt $1: zu viele Chunks"; break; }
  done
  # im Python-Image ausfuehren (Stage 'py' unseres Dockerfiles): weder Host
  # noch d-migrate-Image bringen python3 mit. Mount-Ziel NICHT /lib nennen —
  # das ueberschreibt das Loader-Verzeichnis und python3 startet nicht.
  out=$(docker run --rm -v "$TMP:/in:ro" -v "$PWD/scripts/lib:/harness-lib:ro" \
    --entrypoint python3 "$PYTHON_IMAGE" /harness-lib/silent-loss-check.py \
    "/in/native_$1.txt" "/in/neutral_$1.yaml" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    fail "Silent-Loss-Check $1 fehlgeschlagen (rc=$rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    echo "CHECK-FEHLER|$1|python"; return 0
  fi
  printf '%s\n' "$out" | grep . || true
}

# ---------------------------------------------------------------------- Matrix
echo "== Typ-Matrix (Quelle -> Ziel: Findings des Compare Quelle<->Ziel, ohne SCHEMA_NAME_CHANGED)"
declare -A CELL CODES SILENT SKIPPED_CELL
echo "-- Testdatenbanken leeren"
for d in $DIALECTS; do clean_of "$d"; done
for src in $DIALECTS; do
  echo "-- Quelle $src: seeden + reverse"
  if ! seed_of "$src" > "$TMP/seed_$src.log" 2>&1; then
    fail "Seed $src fehlgeschlagen (Log: $TMP/seed_$src.log)"
    echo "   Seed $src fehlgeschlagen (Log: $TMP/seed_$src.log)"
    SILENT[$src]="CHECK-FEHLER|$src|seed"   # sonst meldete Achse 2 faelschlich 0
    continue
  fi
  [ "$src" = "PG" ] && assert_pg_geometry
  SCH_SRC=$(reverse_conn "$(conn_of "$src")") || { fail "Reverse $src fehlgeschlagen"; echo "   Reverse $src fehlgeschlagen"; continue; }
  # zweite Achse: Verluste schon beim Zuruecklesen (unsichtbar im Quell<->Ziel-Vergleich)
  SILENT[$src]=$(silent_losses_of "$src" "$SCH_SRC")
  for dst in $DIALECTS; do
    [ "$src" = "$dst" ] && continue
    prof=$(profile_of "$dst")
    args=$(jq -nc --arg ref "dmigrate://tenants/default/schemas/$SCH_SRC" --arg t "$(api_of "$dst")" --arg sp "$prof" \
      '{schemaRef:$ref,targetDialect:$t,format:"yaml"} + (if $sp=="" then {} else {spatialProfile:$sp} end)')
    if ! res=$(mcp_call schema_generate "$args" 2>/dev/null); then
      fail "Generate $src->$dst fehlgeschlagen"; CELL[$src,$dst]="GEN-FAIL"; continue
    fi
    if ! echo "$res" | jq -e '.ddl' > /dev/null 2>&1; then
      # Fehler-Payload statt DDL (z.B. VALIDATION_ERROR/INTERNAL_AGENT_ERROR)
      mkdir -p .repro-test/matrix-fail
      echo "$res" > ".repro-test/matrix-fail/gen_${src}_${dst}.json"
      CELL[$src,$dst]="GEN-ERR"
      fail "Generate $src->$dst lieferte Fehler: $(echo "$res" | jq -r '.code // "?"' 2>/dev/null) $(echo "$res" | jq -r '.message // ""' 2>/dev/null | head -c 120)"
      continue
    fi
    echo "$res" | jq -r '.ddl' > "$TMP/ddl_${src}_${dst}.sql"
    # status/skippedCount auswerten: eine DDL, die nur aus Kommentaren besteht
    # (z.B. E052-Skip der ganzen Tabelle), ist keine Messung — sie als Zahl in
    # die Summen zu nehmen hiesse, den Skip im Ergebnis zu verstecken.
    GEN_SKIPPED_CELL=$(echo "$res" | jq -r '.skippedCount // 0')
    if ! grep -qE '^[[:space:]]*CREATE ' "$TMP/ddl_${src}_${dst}.sql"; then
      CELL[$src,$dst]="VOID(skip=$GEN_SKIPPED_CELL)"
      SKIPPED_CELL[$src,$dst]="gen-skipped=$GEN_SKIPPED_CELL"
      continue
    fi
    SKIPPED_CELL[$src,$dst]="gen-skipped=$GEN_SKIPPED_CELL"
    clean_of "$dst"
    if ! apply_of "$dst" "$TMP/ddl_${src}_${dst}.sql"; then
      fail "Apply $src->$dst fehlgeschlagen"
      CELL[$src,$dst]="APPLY-FAIL"
      mkdir -p .repro-test/matrix-fail
      cp "$TMP/ddl_${src}_${dst}.sql" ".repro-test/matrix-fail/ddl_${src}_${dst}.sql" 2>/dev/null || true
      cp "$TMP/apply_$dst.log" ".repro-test/matrix-fail/apply_${src}_${dst}.log" 2>/dev/null || true
      echo "   APPLY-FAIL $src->$dst: $(grep -m1 -E 'Msg [0-9]+, Level|^ORA-|^ERROR|^Error' "$TMP/apply_$dst.log" 2>/dev/null | head -1) (DDL: .repro-test/matrix-fail/)"
      continue
    fi
    SCH_DST=$(reverse_conn "$(conn_of "$dst")") || { fail "Reverse $dst fehlgeschlagen"; CELL[$src,$dst]="REV-FAIL"; continue; }
    cmp=$(mcp_call schema_compare "{\"left\":{\"schemaRef\":\"dmigrate://tenants/default/schemas/$SCH_SRC\"},\"right\":{\"schemaRef\":\"dmigrate://tenants/default/schemas/$SCH_DST\"},\"format\":\"yaml\"}" 2>/dev/null) || { fail "Compare $src->$dst fehlgeschlagen"; CELL[$src,$dst]="CMP-FAIL"; continue; }
    # SCHEMA_NAME_CHANGED zaehlt nicht mit: der Reverse-Provenance-Name
    # differiert zwischen zwei Dialekten immer und ist kein Typbefund —
    # Zellwert und Code-Liste sind damit dieselbe Grundmenge.
    n=$(echo "$cmp" | jq '[.findings[] | select(.code != "SCHEMA_NAME_CHANGED")] | length')
    CELL[$src,$dst]=$n
    codes=$(echo "$cmp" | jq -r '[.findings[] | select(.code!="SCHEMA_NAME_CHANGED") | .code] | group_by(.) | map("\(.[0]):\(length)") | join(" ")')
    CODES[$src,$dst]="$codes"
  done
  clean_of "$src"
done

echo
printf '%-8s' "Quelle"; for d in $DIALECTS; do printf '%-14s' "$d"; done; printf '%-10s\n' "Summe"
declare -A COLSUM
TOTAL=0
for src in $DIALECTS; do
  printf '%-8s' "$src"
  ROWSUM=0
  for dst in $DIALECTS; do
    [ "$src" = "$dst" ] && { printf '%-14s' "-"; continue; }
    v="${CELL[$src,$dst]:-?}"
    printf '%-14s' "$v"
    # nur echte Zahlen summieren (GEN-ERR/APPLY-FAIL u.ae. zaehlen nicht mit)
    case "$v" in ''|*[!0-9]*) ;; *) COLSUM[$dst]=$(( ${COLSUM[$dst]:-0} + v )); ROWSUM=$(( ROWSUM + v ));; esac
  done
  TOTAL=$(( TOTAL + ROWSUM ))
  printf '%-10s\n' "$ROWSUM"
done
printf '%-8s' "Summe"
for dst in $DIALECTS; do printf '%-14s' "${COLSUM[$dst]:-0}"; done
printf '%-10s\n' "$TOTAL"

echo
echo "== Finding-Codes je Zelle (ohne SCHEMA_NAME_CHANGED)"
for src in $DIALECTS; do
  for dst in $DIALECTS; do
    [ "$src" = "$dst" ] && continue
    [ -n "${CODES[$src,$dst]:-}" ] && printf '  %-7s -> %-7s %s  [%s]\n' "$src" "$dst" "${CODES[$src,$dst]}" "${SKIPPED_CELL[$src,$dst]:-}"
  done
done

echo
echo "== Stille Typverluste beim Reverse (Quelltyp -> neutraler Typ, ohne Finding)"
echo "   Diese Spalten sind fuer den Quell<->Ziel-Vergleich unsichtbar: beide Seiten"
echo "   tragen im Modell denselben verflachten Typ."
for src in $DIALECTS; do
  if [ "$src" = "SQLITE" ]; then
    printf '  %-7s (ausgenommen: deklarierte SQLite-Typen sind nominal)\n' "$src"
    continue
  fi
  if printf '%s' "${SILENT[$src]:-}" | grep -q CHECK-FEHLER; then
    printf '  %-7s CHECK-FEHLER: %s\n' "$src" "$(printf '%s' "${SILENT[$src]}" | tr '\n' ' ')"
  elif [ -n "${SILENT[$src]:-}" ]; then
    n=$(printf '%s\n' "${SILENT[$src]}" | grep -c .)
    printf '  %-7s %d:\n' "$src" "$n"
    printf '%s\n' "${SILENT[$src]}" | grep . | sed 's/^/      /'
  else
    printf '  %-7s  0\n' "$src"
  fi
done

if [ "$KEEP" = false ]; then
  for d in $DIALECTS; do clean_of "$d"; done
  echo "(Tabellen aufgeraeumt; --keep laesst sie stehen)"
fi
[ ! -s "$FAIL_FILE" ] || { echo "== Fehler:"; cat "$FAIL_FILE"; exit 1; }
