-- Typ-Seed Oracle: native Typen inkl. der Oracle-Eigenheiten
-- (NUMBER-Varianten, BINARY_FLOAT/DOUBLE, CLOB/NCLOB/BLOB/RAW, TIMESTAMP-
--  Familie, INTERVAL-Typen, XMLTYPE, ROWID, SDO_GEOMETRY).
-- SDO_GEOMETRY braucht einen Spatial-faehigen Oracle (Image-Flavor "regular").
BEGIN EXECUTE IMMEDIATE 'DROP TABLE "type_matrix" PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE "type_matrix" (
  "id" NUMBER(18) GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "c_number" NUMBER,
  "c_number_p" NUMBER(12,4),
  "c_float" FLOAT,
  "c_bfloat" BINARY_FLOAT,
  "c_bdouble" BINARY_DOUBLE,
  "c_varchar2" VARCHAR2(64),
  "c_nvarchar2" NVARCHAR2(64),
  "c_char" CHAR(8),
  "c_clob" CLOB,
  "c_nclob" NCLOB,
  "c_blob" BLOB,
  "c_raw" RAW(16),
  "c_date" DATE,
  "c_timestamp" TIMESTAMP,
  "c_tstz" TIMESTAMP WITH TIME ZONE,
  "c_tsltz" TIMESTAMP WITH LOCAL TIME ZONE,
  "c_interval_ym" INTERVAL YEAR TO MONTH,
  "c_interval_ds" INTERVAL DAY TO SECOND,
  "c_xml" XMLTYPE,
  "g_geom" SDO_GEOMETRY,
  "c_rowid" ROWID
);
