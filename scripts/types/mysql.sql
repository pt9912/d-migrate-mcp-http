-- Typ-Seed MySQL: native Typen inkl. der MySQL-Eigenheiten
-- (unsigned-Varianten, mediumint, bit, year, set, enum, json, blob-Familie,
--  geometry-Subtypen mit SRID).
DROP TABLE IF EXISTS type_matrix;

CREATE TABLE type_matrix (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  c_tinyint TINYINT,
  c_smallint SMALLINT,
  c_mediumint MEDIUMINT,
  c_int_unsigned INT UNSIGNED,
  c_bigint BIGINT,
  c_bit BIT(8),
  c_decimal DECIMAL(12,4),
  c_float FLOAT,
  c_double DOUBLE,
  c_char CHAR(8),
  c_varchar VARCHAR(64),
  c_text TEXT,
  c_binary BINARY(16),
  c_varbinary VARBINARY(64),
  c_blob BLOB,
  c_date DATE,
  c_time TIME,
  c_datetime DATETIME,
  c_year YEAR,
  c_enum ENUM('a','b','c'),
  c_set SET('x','y','z'),
  c_json JSON,
  g_point POINT SRID 4326,          -- NULLABLE: SpatiaLite kann kein NOT NULL auf Geometrie (sonst faellt die ganze Tabelle, E052)
  g_geom GEOMETRY
) ENGINE=InnoDB;
