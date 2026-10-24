# Catalogue of Injected Data Defects (Answer Key)

This document catalogs the intentional defects injected into the `source` operational data by `scripts/generate_source_data.py`. These defects provide ground-truth anomalies to test the Data Quality framework and rejected-record routing (`error_table`) in **V6**.

Each order is corrupted with **at most one** defect to ensure unambiguous SQL detection counts matching the answer key.

---

## 1. List of Injected Defects

- **`DELIVERED_NO_TIME`**
  - **Định nghĩa:** Đơn hàng có trạng thái `DELIVERED` nhưng thời gian giao `delivered_time` bị NULL.
  - **Tỷ lệ:** 2.0% trên tổng số đơn (2,000 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `2,000`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE status = 'DELIVERED' AND delivered_time IS NULL;
    ```

- **`DELIVERED_BEFORE_PICKUP`**
  - **Định nghĩa:** Thời gian giao hàng `delivered_time` sớm hơn thời gian lấy hàng `pickup_time` (nghịch lý thời gian).
  - **Tỷ lệ:** 1.0% trên tổng số đơn (1,000 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `1,000`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE delivered_time < pickup_time;
    ```

- **`STATUS_TIME_MISMATCH`**
  - **Định nghĩa:** Trạng thái đơn là `FAILED` hoặc `CANCELLED` nhưng lại có `delivered_time` được ghi nhận.
  - **Tỷ lệ:** 0.5% trên tổng số đơn (500 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `500`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE status <> 'DELIVERED' AND delivered_time IS NOT NULL;
    ```

- **`DRIVER_MISSING`**
  - **Định nghĩa:** Đơn hàng đã giao thành công (`DELIVERED`) nhưng không có thông tin tài xế (`driver_id IS NULL`).
  - **Tỷ lệ:** 1.0% trên tổng số đơn (1,000 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `1,000`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE driver_id IS NULL AND status NOT IN ('CREATED', 'CANCELLED');
    ```

- **`FEE_MISSING`**
  - **Định nghĩa:** Cước phí giao hàng `delivery_fee` bị NULL.
  - **Tỷ lệ:** 2.0% trên tổng số đơn (2,000 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `2,000`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE delivery_fee IS NULL;
    ```

- **`LATE_UPDATED`**
  - **Định nghĩa:** Cập nhật trạng thái trễ; trường `updated_at` bị trễ từ 1 đến 5 ngày sau khi đơn đã giao (`delivered_time`). Thử thách cơ chế incremental load theo watermark.
  - **Tỷ lệ:** 3.0% trên tổng số đơn (3,000 đơn / 100,000 đơn).
  - **Số lượng kỳ vọng:** `3,000`
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) 
    FROM source.orders 
    WHERE status = 'DELIVERED' AND updated_at - delivered_time > interval '1 day';
    ```

- **`DUPLICATE_CUSTOMER`**
  - **Định nghĩa:** Hai bản ghi khách hàng khác nhau (`customer_id` khác nhau) nhưng trùng cả số điện thoại `phone` và tên `customer_name`.
  - **Tỷ lệ:** 1.0% trên số lượng khách hàng (200 cặp / 20,000 khách hàng).
  - **Số lượng kỳ vọng:** `200` nhóm số điện thoại bị trùng
  - **SQL phát hiện:**
    ```sql
    SELECT COUNT(*) FROM (
        SELECT phone 
        FROM source.customers 
        GROUP BY phone 
        HAVING COUNT(*) > 1
    ) t;
    ```

---

## 2. Lưu ý phân biệt NULL hợp lệ và Lỗi dữ liệu

Các đơn hàng đang trong quá trình xử lý (In-flight orders: `CREATED`, `ASSIGNED`, `PICKED_UP`, `IN_TRANSIT`) hoặc đơn bị hủy (`CANCELLED`) có các giá trị NULL là hoàn toàn hợp lệ theo quy trình vận hành thực tế:
- `pickup_time IS NULL`: Hợp lệ với đơn `CREATED`, `ASSIGNED`, `CANCELLED`.
- `driver_id IS NULL`: Hợp lệ với đơn mới tạo `CREATED` chưa gán tài xế, hoặc `CANCELLED` trước khi gán.
- `delivered_time IS NULL`: Hợp lệ với toàn bộ đơn chưa giao thành công (`CREATED`, `ASSIGNED`, `PICKED_UP`, `IN_TRANSIT`, `FAILED`, `CANCELLED`).
