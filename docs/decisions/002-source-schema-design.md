# ADR-002 — Source Schema Design for Operational Database

**Status:** Accepted  
**Date:** 2026-10-22  
**Deciders:** Solo developer (portfolio project)  
**Related requirements:** FR-1, FR-5, Section 5.1 (Source 1 spec), Checklist Ngày 3–4

---

## 1. Context

The platform requires an operational (OLTP) database simulating the last-mile delivery company's order management system. This system acts as **Source 1 (Order & Delivery DB)**, providing transactional records for customers, drivers, delivery zones, and orders.

The relational design must satisfy operational constraints (data integrity, normalization, auditability) while enabling reliable downstream ELT extraction (specifically, incremental loading via watermark tracking).

---

## 2. Decision

We define four relational tables under the `source` schema: `source.zones`, `source.customers`, `source.drivers`, and `source.orders` with the following architectural decisions:

### 2.1 Timestamp Convention: Local Naive `TIMESTAMP` (UTC+7)
- All timestamp columns (`pickup_time`, `promised_time`, `delivered_time`, `created_at`, `updated_at`) use `TIMESTAMP WITHOUT TIME ZONE`.
- **Convention:** Local Vietnam time (UTC+7).
- **Rationale:** Operational domestic systems in Vietnam frequently operate in a single local timezone without storing offset overhead. Timezone standardization to UTC is explicitly decoupled and performed during transformation in the Staging layer (FR-6).

### 2.2 Nullability Rules reflecting Business Lifecycle
- **Nullable columns in `orders`:**
  - `pickup_time`: NULL for unassigned or newly assigned orders.
  - `driver_id`: NULL for orders not yet dispatched or cancelled prior to assignment.
  - `delivered_time`: NULL for all open / in-flight / failed / cancelled orders.
- **Mandatory columns (`NOT NULL`):**
  - `order_id`, `customer_id`, `zone_id`, `promised_time`, `status`, `created_at`, `updated_at`.
- **Rationale:** Clearly delineates legitimate operational NULLs (in-flight state) from data corruption anomalies.

### 2.3 Explicit CHECK Constraints over PostgreSQL Custom ENUM Types
- Status values are restricted via `CHECK (status IN ('CREATED', 'ASSIGNED', 'PICKED_UP', 'IN_TRANSIT', 'DELIVERED', 'FAILED', 'CANCELLED'))`.
- Numerical validations: `delivery_fee >= 0`, `area_km2 > 0`.
- **Rationale:** Custom PostgreSQL ENUM types introduce DDL migration complexities and dialect lock-in. String columns with `CHECK` constraints are portable, easily testable, and provide clear constraint violation errors.

### 2.4 Watermark Tracking via `updated_at` Trigger for Incremental Load
- An automated trigger `trg_orders_updated_at` executing `source.set_updated_at()` updates `updated_at = now()` on every row modification.
- Dedicated B-Tree index on `orders(updated_at)`.
- **Rationale:** Enables efficient daily/hourly incremental extraction (`WHERE updated_at > :last_watermark`) without full table scans (FR-1).

---

## 3. Considered Alternatives

### Alternative A: `TIMESTAMPTZ` in Source
- *Pros:* Explicit offset tracking.
- *Cons:* Over-complicates the source simulation. Real-world legacy OLTP databases often store naive timestamps; handling timezone normalization in Staging better demonstrates Data Engineering transformation capabilities.

### Alternative B: Soft Deletes with `is_deleted` Flag
- *Pros:* Tracks purged orders.
- *Cons:* Out of scope for V1 order operational requirements where orders transition to terminal states (`CANCELLED`, `FAILED`, `DELIVERED`) rather than being hard deleted.

### Alternative C: Full Table Dump without `updated_at`
- *Pros:* No trigger or index required.
- *Cons:* Infeasible for high-volume production tables. Watermark-based incremental load is a foundational DE pattern required by NFR-1 and FR-1.

---

## 4. Consequences

### Positive
- Strict referential integrity (`FOREIGN KEY`) across zones, customers, drivers, and orders.
- High-performance incremental reading supported by `idx_orders_updated_at`.
- Clean separation between operational state modeling and downstream analytical warehouse modeling.

### Negative / Trade-offs
- Foreign keys prevent inserting orphaned `driver_id` defects directly into `source.orders`. Orphaned reference defects are instead deferred to V2 during Driver Schedule CSV ingestion.
