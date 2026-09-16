-- Typ-Seed PostgreSQL: die Typen, die dieser Dialekt nativ bereitstellt.
-- Wird von scripts/type-matrix.sh als QUELLE (reverse) und als ZIEL (apply der
-- generierten DDL) benutzt. Tabellenname bewusst type_matrix — der Smoke-Repro
-- bleibt unberuehrt, die Matrix raeumt am Ende selbst auf.
DROP TABLE IF EXISTS type_matrix;
DROP TYPE IF EXISTS mood;

CREATE TYPE mood AS ENUM ('sad','ok','happy');

CREATE TABLE type_matrix (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  c_smallint smallint,
  c_int integer,
  c_bigint bigint,
  c_real real,
  c_double double precision,
  c_numeric numeric(12,4),
  c_bool boolean,
  c_char char(8),
  c_varchar varchar(64),
  c_text text,
  c_uuid uuid,
  c_json json,
  c_jsonb jsonb,
  c_xml xml,
  c_bytea bytea,
  c_date date,
  c_time time,
  c_tstz timestamptz,
  c_ts timestamp,
  c_interval interval,
  c_enum mood,
  c_int_array integer[],
  c_text_array text[],
  g_point geometry(Point,4326),
  g_geog geography(Point,4326)
);
