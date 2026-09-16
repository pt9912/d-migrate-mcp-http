-- Wird vom postgres-Service beim ERSTEN Init des pg-data-Volumes ausgefuehrt
-- (docker-entrypoint-initdb.d). Zweck:
--
-- 1. PostGIS in ein EIGENES Schema "postgis" statt "public" installieren.
--    In public legt PostGIS ~1000 Funktionen ab; d-migrates schema_reverse
--    sammelt sie als functions:-Block ein (gemessen: 320 KB Artefakt gegen
--    5 KB) und jeder Compare traegt sie mit.
-- 2. Das Schema in den search_path der Datenbank aufnehmen — die PostGIS-Doku
--    verlangt das ausdruecklich (geometry_columns/spatial_ref_sys liegen in
--    diesem Schema). Ohne diesen Eintrag liest d-migrate Geometriespalten
--    OHNE geometry_type/srid zurueck (still, ohne Finding) — gemessen mit
--    PG 18.6 / PostGIS 3.6.
CREATE SCHEMA IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA postgis;
ALTER DATABASE dmigrate SET search_path = "$user", public, postgis;
GRANT USAGE ON SCHEMA postgis TO dmigrate;
