-- =============================================================
-- scripts/create_source_schema.sql
-- Tạo các bảng OLTP trong schema "source" (mô phỏng hệ thống gốc)
-- Chạy: Get-Content scripts/create_source_schema.sql | docker exec -i logistics-postgres psql -U postgres -d logistics
-- Idempotent: dùng IF NOT EXISTS / CREATE OR REPLACE, chạy lại an toàn
-- =============================================================

SET search_path TO source, public;

-- =============================================================
-- 0. Trigger function dùng chung để tự cập nhật updated_at
-- =============================================================
CREATE OR REPLACE FUNCTION source.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================
-- 1. zones — Bảng tham chiếu, không phụ thuộc bảng nào
-- =============================================================
CREATE TABLE IF NOT EXISTS source.zones (
    zone_id      SERIAL       PRIMARY KEY,
    zone_name    VARCHAR(100) NOT NULL,
    city         VARCHAR(100) NOT NULL DEFAULT 'Hanoi',
    area_km2     NUMERIC(8,2),
    centroid_lat NUMERIC(9,6) NOT NULL,   -- Dùng để gọi Weather API (V2)
    centroid_lon NUMERIC(9,6) NOT NULL,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  source.zones IS 'Danh sách khu vực giao hàng cố định (~12-20 zones). centroid dùng cho Weather API.';
COMMENT ON COLUMN source.zones.centroid_lat IS 'Vĩ độ trọng tâm zone, dùng để gọi Weather API theo BQ-OPS-4.';


-- =============================================================
-- 2. customers — Không phụ thuộc bảng nào
-- =============================================================
CREATE TABLE IF NOT EXISTS source.customers (
    customer_id  SERIAL       PRIMARY KEY,
    customer_name VARCHAR(150) NOT NULL,
    email        VARCHAR(254),
    phone        VARCHAR(20),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE source.customers IS 'Khách hàng đặt đơn. Scope V0: chỉ dùng để FK tham chiếu từ orders.';


-- =============================================================
-- 3. drivers — Không phụ thuộc bảng nào
-- Lưu ý: schedule (shift, zone assignment) đến từ CSV (Source 3),
--         bảng này chỉ lưu master data của driver.
-- =============================================================
CREATE TABLE IF NOT EXISTS source.drivers (
    driver_id    SERIAL       PRIMARY KEY,
    driver_name  VARCHAR(150) NOT NULL,
    hire_date    DATE         NOT NULL,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Trigger: tự cập nhật updated_at khi UPDATE
CREATE OR REPLACE TRIGGER trg_drivers_updated_at
    BEFORE UPDATE ON source.drivers
    FOR EACH ROW EXECUTE FUNCTION source.set_updated_at();

COMMENT ON TABLE source.drivers IS 'Master data driver. Lịch làm việc (shift/zone) lưu riêng trong CSV (Source 3).';


-- =============================================================
-- 4. orders — Bảng chính, FK đến customers và zones
--
-- Thiết kế FK chủ ý:
--   - customer_id → customers: bắt buộc, mọi order đều có khách
--   - zone_id     → zones:     bắt buộc, mọi order thuộc một zone
--   - driver_id:  KHÔNG có FK constraint vào drivers
--       Lý do: roadmap yêu cầu inject defect "driver_id không tồn
--       tại trong driver schedule" để test data quality pipeline (V6).
--       FK cứng sẽ chặn việc insert defect record này.
-- =============================================================
CREATE TABLE IF NOT EXISTS source.orders (
    order_id         SERIAL          PRIMARY KEY,
    customer_id      INT             NOT NULL REFERENCES source.customers(customer_id),
    driver_id        INT,                                    -- Không FK (xem comment trên)
    zone_id          INT             NOT NULL REFERENCES source.zones(zone_id),

    -- Timestamps theo KPI-1, KPI-3
    pickup_time      TIMESTAMPTZ     NOT NULL,
    promised_time    TIMESTAMPTZ     NOT NULL,
    delivered_time   TIMESTAMPTZ,                            -- NULL khi order chưa hoàn thành

    -- Trạng thái đơn hàng (KPI-8, FR-11)
    status           VARCHAR(20)     NOT NULL
                         CHECK (status IN (
                             'created', 'assigned', 'picked_up',
                             'in_transit', 'delivered', 'failed', 'cancelled'
                         )),

    -- Số lượng hàng (KPI-2 OTIF)
    items_ordered    SMALLINT        NOT NULL DEFAULT 1 CHECK (items_ordered > 0),
    items_delivered  SMALLINT,                              -- NULL khi chưa giao

    -- Tọa độ (KPI-4 cost, KPI-5 distance)
    pickup_lat       NUMERIC(9,6)    NOT NULL,
    pickup_lon       NUMERIC(9,6)    NOT NULL,
    dropoff_lat      NUMERIC(9,6)    NOT NULL,
    dropoff_lon      NUMERIC(9,6)    NOT NULL,

    -- Audit columns
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW()  -- Watermark cho incremental load
);

-- Trigger: tự cập nhật updated_at khi UPDATE
CREATE OR REPLACE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON source.orders
    FOR EACH ROW EXECUTE FUNCTION source.set_updated_at();

-- ---------------------------------------------------------------
-- Index
-- ---------------------------------------------------------------

-- Index chính cho incremental load (FR-1): pipeline query WHERE updated_at > watermark
CREATE INDEX IF NOT EXISTS idx_orders_updated_at
    ON source.orders (updated_at);

-- Index cho query theo zone (BQ-OPS-1, BQ-CS-1, BQ-FIN-2)
CREATE INDEX IF NOT EXISTS idx_orders_zone_id
    ON source.orders (zone_id);

-- Index cho query theo driver (KPI-6, KPI-7)
CREATE INDEX IF NOT EXISTS idx_orders_driver_id
    ON source.orders (driver_id);

-- Index cho lọc theo status (open orders, BQ-CS-1)
CREATE INDEX IF NOT EXISTS idx_orders_status
    ON source.orders (status);

-- Composite index cho query phổ biến nhất: zone + status + updated_at
CREATE INDEX IF NOT EXISTS idx_orders_zone_status_updated
    ON source.orders (zone_id, status, updated_at DESC);

COMMENT ON TABLE  source.orders IS 'Bảng đơn hàng chính (OLTP). Incremental load dùng updated_at làm watermark.';
COMMENT ON COLUMN source.orders.driver_id      IS 'ID tài xế. Không có FK để cho phép inject defect "unknown driver" (test V6).';
COMMENT ON COLUMN source.orders.delivered_time IS 'NULL = order chưa hoàn thành. Không được đặt NULL là late (theo KPI business rule).';
COMMENT ON COLUMN source.orders.updated_at     IS 'Watermark cho incremental load. Tự động cập nhật qua trigger trg_orders_updated_at.';


-- =============================================================
-- 5. Xác nhận
-- =============================================================
SELECT
    schemaname,
    tablename,
    tableowner
FROM pg_tables
WHERE schemaname = 'source'
ORDER BY tablename;
