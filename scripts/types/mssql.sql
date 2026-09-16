-- Typ-Seed SQL Server: native Typen inkl. der MSSQL-Eigenheiten
-- (money, sql_variant, rowversion, uniqueidentifier, geography/geometry).
DROP TABLE IF EXISTS type_matrix;

CREATE TABLE type_matrix (
  id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  c_tinyint tinyint,
  c_smallint smallint,
  c_int int,
  c_bigint bigint,
  c_bit bit,
  c_decimal decimal(12,4),
  c_money money,
  c_float float,
  c_real real,
  c_char char(8),
  c_nchar nchar(8),
  c_varchar nvarchar(64),
  c_varchar_max nvarchar(max),
  c_uuid uniqueidentifier,
  c_xml xml,
  c_binary varbinary(max),
  c_date date,
  c_time time,
  c_datetime2 datetime2,
  c_dto datetimeoffset,
  c_geography geography,
  c_geometry geometry,
  c_rowversion rowversion,
  c_sqlvariant sql_variant
);
