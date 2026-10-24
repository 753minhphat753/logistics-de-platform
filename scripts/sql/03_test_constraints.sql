-- =============================================================
-- scripts/sql/03_test_constraints.sql
-- Kiem chung rang buoc (Checklist Ngay 4, Task D)
-- =============================================================

\echo '=== 1. Test INSERT hop le ==='
INSERT INTO source.zones (zone_id, zone_name, city, area_km2)
VALUES (999, 'Test Zone', 'HCMC', 10.5) ON CONFLICT DO NOTHING;

INSERT INTO source.customers (customer_id, customer_name, phone)
VALUES (999, 'Test Customer', '0901234567') ON CONFLICT DO NOTHING;

INSERT INTO source.drivers (driver_id, driver_name, hire_date, current_zone_id, is_active)
VALUES (999, 'Test Driver', '2025-01-01', 999, true) ON CONFLICT DO NOTHING;

INSERT INTO source.orders (
    order_id, customer_id, driver_id, zone_id, pickup_time,
    promised_time, delivered_time, status, delivery_fee, created_at, updated_at
) VALUES (
    999999, 999, 999, 999, '2026-07-01 10:00:00',
    '2026-07-01 11:00:00', '2026-07-01 10:50:00', 'DELIVERED', 25000,
    '2026-07-01 09:30:00', '2026-07-01 10:50:00'
);
\echo '-> INSERT hop le thanh cong!'

\echo '=== 2. Test INSERT status sai (ky vong: ERROR check constraint) ==='
DO $$
BEGIN
    INSERT INTO source.orders (
        order_id, customer_id, zone_id, promised_time, status
    ) VALUES (
        999998, 999, 999, '2026-07-01 12:00:00', 'WRONG_STATUS'
    );
    RAISE EXCEPTION 'FAIL: Cho phep status sai!';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'SUCCESS: Status sai bi tu choi boi CHECK constraint!';
END $$;

\echo '=== 3. Test INSERT customer_id khong ton tai (ky vong: ERROR foreign key) ==='
DO $$
BEGIN
    INSERT INTO source.orders (
        order_id, customer_id, zone_id, promised_time, status
    ) VALUES (
        999997, 88888, 999, '2026-07-01 12:00:00', 'CREATED'
    );
    RAISE EXCEPTION 'FAIL: Cho phep customer_id khong ton tai!';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'SUCCESS: customer_id khong ton tai bi tu choi boi FK constraint!';
END $$;

\echo '=== 4. Test INSERT delivery_fee am (ky vong: ERROR check constraint) ==='
DO $$
BEGIN
    INSERT INTO source.orders (
        order_id, customer_id, zone_id, promised_time, status, delivery_fee
    ) VALUES (
        999996, 999, 999, '2026-07-01 12:00:00', 'CREATED', -5
    );
    RAISE EXCEPTION 'FAIL: Cho phep delivery_fee am!';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'SUCCESS: delivery_fee am bi tu choi boi CHECK constraint!';
END $$;

\echo '=== 5. Test Trigger updated_at khi UPDATE ==='
SELECT order_id, updated_at AS old_updated_at FROM source.orders WHERE order_id = 999999;
-- Chờ 1 giây để thấy rõ timestamp thay đổi
SELECT pg_sleep(1);
UPDATE source.orders SET status = 'IN_TRANSIT' WHERE order_id = 999999;
SELECT order_id, updated_at AS new_updated_at FROM source.orders WHERE order_id = 999999;

\echo '=== 6. Don dep du lieu thu nghiem ==='
TRUNCATE source.orders, source.drivers, source.customers, source.zones RESTART IDENTITY CASCADE;

\echo '=== 7. Kiem tra bang trong sau khi truncate ==='
SELECT
    'zones' AS t, COUNT(*) FROM source.zones
UNION ALL SELECT 'customers', COUNT(*) FROM source.customers
UNION ALL SELECT 'drivers', COUNT(*) FROM source.drivers
UNION ALL SELECT 'orders', COUNT(*) FROM source.orders;
