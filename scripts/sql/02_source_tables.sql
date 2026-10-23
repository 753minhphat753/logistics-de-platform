-- Source schema: simulated operational (OLTP) database
-- Convention: all timestamps are Vietnam local time (UTC+7)

CREATE SCHEMA IF NOT EXISTS source;

CREATE TABLE IF NOT EXISTS source.zones (
    zone_id    SERIAL PRIMARY KEY,
    zone_name  TEXT NOT NULL UNIQUE,
    city       TEXT NOT NULL,
    area_km2   NUMERIC(8,2) CHECK (area_km2 > 0)
);

CREATE TABLE IF NOT EXISTS source.customers (
    customer_id    SERIAL PRIMARY KEY,
    customer_name  TEXT NOT NULL,
    phone          TEXT,
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS source.drivers (
    driver_id        SERIAL PRIMARY KEY,
    driver_name      TEXT NOT NULL,
    hire_date        DATE NOT NULL,
    current_zone_id  INT REFERENCES source.zones(zone_id),
    is_active        BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS source.orders (
    order_id        BIGSERIAL PRIMARY KEY,
    customer_id     INT NOT NULL REFERENCES source.customers(customer_id),
    driver_id       INT REFERENCES source.drivers(driver_id),
    zone_id         INT NOT NULL REFERENCES source.zones(zone_id),
    pickup_time     TIMESTAMP,
    promised_time   TIMESTAMP NOT NULL,
    delivered_time  TIMESTAMP,
    status          TEXT NOT NULL
        CHECK (status IN ('CREATED','ASSIGNED','PICKED_UP','IN_TRANSIT',
                          'DELIVERED','FAILED','CANCELLED')),
    delivery_fee    NUMERIC(10,2) CHECK (delivery_fee >= 0),
    created_at      TIMESTAMP NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- Supports incremental load (WHERE updated_at > last_watermark)
CREATE INDEX IF NOT EXISTS idx_orders_updated_at ON source.orders(updated_at);

-- Foreign keys are not indexed automatically in PostgreSQL
CREATE INDEX IF NOT EXISTS idx_orders_driver_id   ON source.orders(driver_id);
CREATE INDEX IF NOT EXISTS idx_orders_zone_id     ON source.orders(zone_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON source.orders(customer_id);

-- Keep updated_at current on every UPDATE
CREATE OR REPLACE FUNCTION source.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_orders_updated_at ON source.orders;
CREATE TRIGGER trg_orders_updated_at
BEFORE UPDATE ON source.orders
FOR EACH ROW EXECUTE FUNCTION source.set_updated_at();
