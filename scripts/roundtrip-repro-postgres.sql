-- Repro-Schema fuer den Round-Trip-Smoke-Test (scripts/roundtrip-smoke.sh),
-- aus dem Gotchas-Memory nachgebaut: CHECK, computed column, function-Default,
-- UNIQUE auf TEXT, FK mit RESTRICT / NO ACTION / ohne Angabe, Enum, View.
-- Dazu eine Typ-Tabelle, die die neutralen Typen ohne Reader-Zweig abdeckt
-- (json/jsonb, interval, uuid, xml, bytea, char, smallint, real, Arrays) und
-- zwei Geometriespalten (PostGIS). Geometrie bewusst NULLABLE: SpatiaLite
-- kann NOT-NULL-Geometrie nicht abbilden (E052 verwirft sonst die Tabelle).
DROP VIEW IF EXISTS order_summary;
DROP TABLE IF EXISTS type_probe;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;
DROP TYPE IF EXISTS order_status;

CREATE TYPE order_status AS ENUM ('NEW','PAID','SHIPPED','CANCELLED');

CREATE TABLE customers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email text NOT NULL,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT current_timestamp,
  CONSTRAINT uq_customer_email UNIQUE (email)
);

CREATE TABLE products (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku text NOT NULL,
  price numeric(10,2) NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  CONSTRAINT uq_product_sku UNIQUE (sku)
);

CREATE TABLE orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
  status order_status NOT NULL DEFAULT 'NEW',
  status_history order_status[] NOT NULL DEFAULT ARRAY['NEW'::order_status],
  placed_at timestamptz NOT NULL DEFAULT current_timestamp,
  total numeric(10,2) NOT NULL,
  CHECK (total >= 0)
);

CREATE TABLE order_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES orders(id) ON DELETE NO ACTION,
  product_id bigint NOT NULL REFERENCES products(id),
  quantity integer NOT NULL CHECK (quantity > 0),
  price_at_sale numeric(10,2) NOT NULL,
  line_total numeric(10,2) GENERATED ALWAYS AS (price_at_sale * quantity) STORED
);

CREATE TABLE type_probe (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  c_small smallint,
  c_real real,
  c_char char(10),
  c_uuid uuid,
  c_json json,
  c_jsonb jsonb,
  c_xml xml,
  c_bytea bytea,
  c_interval interval,
  c_int_array integer[],
  c_text_array text[],
  g_point geometry(Point,4326),
  g_poly geometry(Polygon,4326)
);

CREATE VIEW order_summary AS
  SELECT o.id AS order_id, c.email, o.total
  FROM orders o JOIN customers c ON c.id = o.customer_id;