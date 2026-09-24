# Logistics DE Platform

A Data Engineering platform for tracking last-mile delivery performance: on-time delivery rate (OTIF), operating cost, driver performance, and early warning for zones at risk of delivery delays.

---

## 1. Business Problem

A last-mile delivery company has no centralized way to track:
- On-time delivery rate (OTIF — On-Time-In-Full)
- Operating cost per order / per zone
- Driver performance
- Zones at risk of delivery delays (due to weather or driver overload)

Data currently lives scattered across the operational database, driver work schedules (Excel/CSV), and raw GPS logs — with no one consolidating it to support daily operational decisions.

## 2. Stakeholders

- **Ops team** — coordinates drivers by zone / in near real-time
- **Finance** — tracks delivery cost by order / zone
- **Customer Service** — anticipates and explains delay-related complaints
- **Management** — regional KPIs, overall operational performance

## 3. Data Sources

| # | Source | Format | Frequency |
|---|--------|--------|-----------|
| 1 | Order & Delivery DB (PostgreSQL, OLTP) | Relational tables | Batch, daily |
| 2 | Weather API (public) | JSON via REST | Scheduled polling |
| 3 | Driver Schedule CSV | CSV/Excel | Batch, per shift/day |
| 4 | Driver GPS / Telemetry Logs | JSON/CSV log | Micro-batch (5–15 min) |