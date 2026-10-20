-- scripts/init_db.sql
-- Khởi tạo schema cho logistics-de-platform
-- Chạy một lần khi setup môi trường mới

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS warehouse;
