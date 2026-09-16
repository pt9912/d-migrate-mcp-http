#!/bin/bash
# Wird vom postgres-Service beim ERSTEN Init des pg-data-Volumes ausgefuehrt
# (docker-entrypoint-initdb.d). Zweck:
#
# 1. PostGIS in ein EIGENES Schema "postgis" statt "public" installieren.
#    In public legt PostGIS ~1000 Funktionen ab; d-migrates schema_reverse
#    sammelt sie als functions:-Block ein (gemessen: 320 KB Artefakt gegen
#    5 KB) und jeder Compare traegt sie mit.
# 2. Das Schema in den search_path der Datenbank aufnehmen — die PostGIS-Doku
#    verlangt das ausdruecklich (geometry_columns/spatial_ref_sys liegen in
#    diesem Schema). Ohne diesen Eintrag liest d-migrate Geometriespalten
#    OHNE geometry_type/srid zurueck (still, ohne Finding) — gemessen mit
#    PG 18.6 / PostGIS 3.6.
#
# Als .sh und nicht als .sql: Datenbank- und Rollenname kommen aus der
# Umgebung (.env: POSTGRES_DB/POSTGRES_USER). Ein hartcodiertes "dmigrate"
# waere beim ersten Init an einem angepassten Namen gescheitert — mit
# ON_ERROR_STOP bricht der Init dann ab, der Container wird nie healthy, und
# da das Volume danach initialisiert ist, laeuft das Skript nie wieder.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA postgis;
SQL

# ALTER DATABASE braucht den Namen als Literal -> in der Shell interpoliert.
# "$user" bleibt dabei woertlich stehen (DB-weite Einstellung, kein Shell-Ausdruck).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "ALTER DATABASE \"$POSTGRES_DB\" SET search_path = \"\$user\", public, postgis;"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "GRANT USAGE ON SCHEMA postgis TO \"$POSTGRES_USER\";"
