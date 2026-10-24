-- scripts/sql/10_source_profiling.sql
-- Source schema data profiling and validation queries

-- 1. So dong moi bang: zones 12, drivers 80, customers 20000, orders 100000
SELECT 'zones' AS t, COUNT(*) FROM source.zones
UNION ALL SELECT 'drivers', COUNT(*) FROM source.drivers
UNION ALL SELECT 'customers', COUNT(*) FROM source.customers
UNION ALL SELECT 'orders', COUNT(*) FROM source.orders;

-- 2. Phan bo status: DELIVERED khoang 92-93%, FAILED khoang 4%, CANCELLED khoang 3%, don dang xu ly < 1%
SELECT status, COUNT(*) AS n, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM source.orders GROUP BY status ORDER BY n DESC;

-- 3. Khoang thoi gian: tu 2026-07-01 den 2026-09-28
SELECT MIN(created_at), MAX(created_at) FROM source.orders;

-- 4. Ty le giao dung hen tong the: khoang 80-87%
SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE delivered_time <= promised_time)
       / COUNT(*) FILTER (WHERE delivered_time IS NOT NULL), 2) AS on_time_pct
FROM source.orders;

-- 5. Ty le tre theo gio: gio 11, 12, 18, 19 phai cao hon cac gio khac khoang 8 diem phan tram
SELECT EXTRACT(HOUR FROM created_at) AS hr,
       COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) FILTER (WHERE delivered_time > promised_time) / COUNT(*), 1) AS late_pct
FROM source.orders WHERE status = 'DELIVERED'
GROUP BY hr ORDER BY hr;

-- 6. Ty le tre theo zone: Thu Duc, Binh Tan, Quan 12 phai cao hon Quan 5, Quan 10, Phu Nhuan
SELECT z.zone_name, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.delivered_time > o.promised_time) / COUNT(*), 1) AS late_pct
FROM source.orders o JOIN source.zones z USING (zone_id)
WHERE o.status = 'DELIVERED'
GROUP BY z.zone_name ORDER BY late_pct DESC;

-- 7. Kiem tra cac loai loi cai dat co chu dich
-- Du lieu sach: tat ca tra ve 0
-- Du lieu co loi: Delivered_no_time=2000, before_pickup=1000, status_mismatch=500, driver_missing=1000, fee_missing=2000, late_updated=3000
SELECT
  COUNT(*) FILTER (WHERE status = 'DELIVERED' AND delivered_time IS NULL)          AS delivered_no_time,
  COUNT(*) FILTER (WHERE delivered_time < pickup_time)                             AS before_pickup,
  COUNT(*) FILTER (WHERE status <> 'DELIVERED' AND delivered_time IS NOT NULL)     AS status_mismatch,
  COUNT(*) FILTER (WHERE driver_id IS NULL AND status NOT IN ('CREATED','CANCELLED')) AS driver_missing,
  COUNT(*) FILTER (WHERE delivery_fee IS NULL)                                     AS fee_missing,
  COUNT(*) FILTER (WHERE status = 'DELIVERED' AND updated_at - delivered_time > interval '1 day') AS late_updated
FROM source.orders;

-- 8. Kiem tra duplicate customer (so phone bi trung lap, mong doi: 200)
SELECT COUNT(*) AS duplicate_phone_groups FROM (
    SELECT phone FROM source.customers GROUP BY phone HAVING COUNT(*) > 1
) t;

-- 9. Phan biet NULL hop le voi loi
SELECT status,
       COUNT(*) FILTER (WHERE pickup_time IS NULL)    AS null_pickup,
       COUNT(*) FILTER (WHERE driver_id IS NULL)      AS null_driver,
       COUNT(*) FILTER (WHERE delivered_time IS NULL) AS null_delivered
FROM source.orders GROUP BY status ORDER BY status;

-- 10. Checksum kiem tra tinh tai lap (determinism)
SELECT md5(string_agg(
    order_id::text || '|' || status || '|' || COALESCE(delivered_time::text, 'NULL')
    || '|' || COALESCE(driver_id::text, 'NULL'),
    ',' ORDER BY order_id)) AS checksum
FROM source.orders;
