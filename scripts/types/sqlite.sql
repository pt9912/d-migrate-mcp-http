-- Typ-Seed SQLite/SpatiaLite: SQLite hat keine festen Typen, sondern
-- Affinitaeten — hier beides: die deklarierten Typnamen, die ein Reverse
-- vorfindet, plus eine typenlose Spalte und echte SpatiaLite-Geometrien.
-- Wird im Werkzeug-Image (tools/harness-tools) mit mod_spatialite ausgefuehrt.
PRAGMA trusted_schema=ON;
-- Pfadlos laden: die Extension wird ueber den System-Cache gefunden und
-- funktioniert damit auch auf anderen Architekturen (arm64/macOS-Docker).
SELECT load_extension('mod_spatialite');
SELECT InitSpatialMetaData(1);
DROP TABLE IF EXISTS type_matrix;

CREATE TABLE type_matrix (
  id INTEGER PRIMARY KEY,
  c_integer INTEGER,
  c_real REAL,
  c_text TEXT,
  c_blob BLOB,
  c_numeric NUMERIC,
  c_varchar VARCHAR(64),
  c_boolean BOOLEAN,
  c_date DATE,
  c_datetime DATETIME,
  c_decimal DECIMAL(12,4),
  c_typeless
);
SELECT AddGeometryColumn('type_matrix','g_point',4326,'POINT',2);
SELECT AddGeometryColumn('type_matrix','g_poly',4326,'POLYGON',2);
