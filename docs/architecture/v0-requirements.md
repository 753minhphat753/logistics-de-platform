# V0 — Requirements & Problem Definition

**Project:** Logistics & Last-Mile Delivery Analytics Platform
**Version:** V0 (tag `v0.1-problem-definition`)
**Status:** Draft v0.1 — all schemas and volumes below are *planned* and will be validated in V1–V2
**Last updated:** 2026-10-19

---

## Table of contents

1. Business problem
2. Stakeholders and business questions
3. KPI definitions and business rules
4. Required data fields (KPI → field traceability)
5. Data source specifications
6. Functional requirements
7. Non-functional requirements
8. Scope
9. Preliminary data model
10. Architecture layers (summary)
11. Assumptions
12. Open questions
13. Risks
14. Requirement-to-version map
15. Glossary

---

## 1. Business problem

A last-mile delivery company cannot see its own delivery performance in one place. On-time delivery, cost per order, and driver workload are tracked separately by different teams, from different systems, with different definitions. Operational data sits in the order database, driver working hours live in manually exported spreadsheets, and raw GPS logs are never analysed.

The consequences:
- Operations only learns that a zone is struggling **after** customers complain
- Finance learns about cost overruns at month-end, when it is too late to act
- Customer service cannot explain *why* an order was late and answers complaints with guesses
- Management receives reports in which "on time" is calculated differently by each team

**The platform's purpose:** consolidate these sources into a single, trusted analytical dataset with one agreed definition per KPI, refreshed automatically, with data quality problems detected and recorded instead of silently corrupting reports.

**Identity of the project:** this is a **Data Engineering** system. The deliverable is the reliable pipeline, the data model, and the quality controls — not the dashboards or models built on top of them.

---

## 2. Stakeholders and business questions

Every table and column in later versions must trace back to one of the questions below.

Question types used: **M** = monitoring, **C** = comparison, **D** = diagnostic, **T** = trend.

### 2.1 Operations team (dispatchers)

- **Role:** assigns drivers to zones during the day
- **Key decision:** which zone to reinforce and which to draw drivers from, every morning and several times a day
- **Today's pain:** manual cross-checking of Excel schedules and the order database; problems are visible only after complaints
- **Frequency:** daily, ideally several times a day

Questions:
- **BQ-OPS-1 (M):** What is today's on-time rate for each zone?
- **BQ-OPS-2 (C):** Which zones have an on-time rate noticeably below their own normal level (same weekday, last 4 weeks)?
- **BQ-OPS-3 (D):** Is a struggling zone understaffed, i.e. is the number of orders per on-shift driver unusually high?
- **BQ-OPS-4 (D):** In which zones is the weather currently bad, and is the late rate higher there?

Follow-up actions: move drivers between zones, call in standby drivers, warn customer service in advance.

### 2.2 Finance

- **Role:** controls delivery operating cost
- **Key decision:** budget approval, review of expensive zones, negotiations with partners
- **Today's pain:** cost is compiled manually at month-end; overruns are discovered late and the source of cost is unclear
- **Frequency:** weekly and monthly

Questions:
- **BQ-FIN-1 (M):** What is the average delivery cost per order this month?
- **BQ-FIN-2 (C):** Which zones cost more per order than the city-wide average, and by what percentage?
- **BQ-FIN-3 (D):** Is a cost increase driven by longer average distance per delivery or by something else?
- **BQ-FIN-4 (T):** How has cost per delivery changed over the last 8 weeks?

Follow-up actions: adjust service areas, review pricing for abnormal zones, set early cost thresholds.

### 2.3 Customer service

- **Role:** handles complaints about late deliveries
- **Key decision:** explain the cause of a late order and decide on compensation
- **Today's pain:** has to ask Operations or search orders one by one; explanations are vague and unconvincing
- **Frequency:** per order, during the day

Questions:
- **BQ-CS-1 (M):** How many orders are currently past their promised time and not yet completed, per zone?
- **BQ-CS-2 (D):** By how many minutes was a specific order late?
- **BQ-CS-3 (D):** Was there bad weather in the delivery zone at the time of this order?
- **BQ-CS-4 (C):** Is this late order an isolated case, or part of a bad day for the whole zone?

Follow-up actions: give the customer a factual explanation, decide compensation, feed operational failures back to Operations.

### 2.4 Management

- **Role:** monitors overall performance and allocates resources
- **Key decision:** where to invest, what KPI targets to set, which zones to expand or shrink
- **Today's pain:** manual reports with inconsistent definitions between departments
- **Frequency:** weekly and monthly

Questions:
- **BQ-MGT-1 (M):** What is the OTIF rate across the whole system this week?
- **BQ-MGT-2 (C):** Which zones are best and worst on OTIF, and by how much?
- **BQ-MGT-3 (T):** Is OTIF improving or declining over the last 12 weeks?
- **BQ-MGT-4 (C):** Is there a large performance gap between drivers (orders per day, on-time rate)?

Follow-up actions: concentrate resources on weak zones, adjust targets, plan driver training or hiring.

### 2.5 Note on "early warning"

Questions phrased with "currently" describe the **present state** from real data and are in scope. Questions that predict the future ("which zone *will* be late this afternoon") require predictive modelling and are **out of scope** for the initial build (see Section 8).

---

## 3. KPI definitions and business rules

One definition per KPI, used everywhere. The warehouse exists to enforce this.

### 3.1 Order status model (planned)

Statuses: `created`, `assigned`, `picked_up`, `in_transit`, `delivered`, `failed`, `cancelled`.

- **Completed delivery:** status `delivered` with a non-null `delivered_time`
- **Open order:** `created`, `assigned`, `picked_up`, or `in_transit`
- **Failed / cancelled:** tracked separately, **excluded** from the on-time denominator

### 3.2 KPI definitions

**KPI-1 On-time delivery rate**
- Order is on time when `delivered_time <= promised_time + grace_minutes`
- `grace_minutes` default: 0 (configurable in `config/`)
- Rate = on-time completed deliveries / all completed deliveries
- Grain: completed delivery. Sliced by: zone, date, hour bucket, driver, weather condition
- Exclusions: open, failed, and cancelled orders are not in the denominator
- Sources: Order DB

**KPI-2 OTIF rate (On-Time-In-Full)**
- Order is OTIF when it is on time **and** `items_delivered = items_ordered`
- Rate = OTIF completed deliveries / all completed deliveries
- Decision recorded: the Order DB will include `items_ordered` and `items_delivered` so the "In-Full" half is computable
- Sources: Order DB

**KPI-3 Average delay**
- `delay_minutes = max(0, delivered_time − promised_time)` per delivery, reported as average over **late** deliveries only
- Also reported: average `actual_minutes` and `promised_minutes`
  - `actual_minutes = delivered_time − pickup_time`
  - `promised_minutes = promised_time − pickup_time`
- Sources: Order DB

**KPI-4 Cost per delivery**
- `delivery_cost = distance_km × cost_per_km + base_fee`
- `cost_per_km` and `base_fee` are configuration parameters
- **This is a simplified, simulated cost model**, not accounting data; it exists to give the pipeline a derived money metric
- Cost per delivery = total delivery cost / completed deliveries, sliced by zone and period
- Sources: Order DB (coordinates) + configuration

**KPI-5 Distance per delivery**
- `distance_km` = great-circle (haversine) distance between pickup and drop-off coordinates
- Known limitation: straight-line distance underestimates real road distance
- Sources: Order DB

**KPI-6 Driver productivity**
- Deliveries per driver per day; on-time rate per driver
- Sources: Order DB + Driver Schedule

**KPI-7 Zone load**
- Orders per on-shift driver, by zone and time window
- Sources: Order DB + Driver Schedule

**KPI-8 Late open orders**
- Count of open orders where `now > promised_time`, by zone
- Sources: Order DB (latest snapshot)

**KPI-9 Driver average speed (V7)**
- Mean `speed_kmh` from valid GPS events, by driver and time window
- Sources: GPS logs

### 3.3 Business rules to apply consistently

- A delivery without `delivered_time` is "open", never "late"
- All timestamps are stored in **UTC** at the staging layer; local-time conversion happens in `dim_time`
- Weather is joined to a delivery by **zone + hour of `delivered_time`**
- Late-arriving updates (e.g. an order status changed after the daily load) must be picked up by the incremental load (see source specification)

---

## 4. Required data fields (KPI → field traceability)

Working backwards from the KPIs to the data that must exist. Fields marked **NEW** were missing from the initial schema and are added to the planned source design.

- **KPI-1 On-time rate** needs: `promised_time`, `delivered_time`, `status` → Order DB (exists)
- **KPI-2 OTIF** needs: `items_ordered`, `items_delivered` → Order DB (**NEW**)
- **KPI-3 Delay / durations** needs: `pickup_time`, `promised_time`, `delivered_time` → Order DB (exists)
- **KPI-4 / KPI-5 Cost and distance** need: `pickup_lat`, `pickup_lon`, `dropoff_lat`, `dropoff_lon` → Order DB (**NEW**); plus `cost_per_km`, `base_fee` → config (**NEW**)
- **Slicing by zone** needs: `zone_id` on each order → Order DB (exists); `dim_zone` with centroid coordinates (`centroid_lat`, `centroid_lon`) to call the weather API (**NEW**)
- **BQ-OPS-4, BQ-CS-3 Weather link** needs: zone ↔ coordinates mapping, weather timestamp with a known timezone, `condition`, `temperature`, `precipitation` → Weather API (exists after mapping)
- **KPI-6 / KPI-7 Driver and load** need: `driver_id`, `shift_date`, `shift_start`, `shift_end`, `assigned_zone` → Driver Schedule CSV (exists)
- **Driver zone history (SCD2)** needs: `assigned_zone` per `driver_id` over time, with a date → Driver Schedule CSV (exists)
- **KPI-9 Speed** needs: `driver_id`, `speed_kmh`, `event_timestamp` → GPS logs (exists)
- **BQ-CS-4 / BQ-OPS-2 Baselines** need: at least 4 weeks of simulated history → data generation requirement (**NEW**: the generator must produce multi-week history, not a single day)

---

## 5. Data source specifications

All schemas below are **planned** and will be validated and corrected when the data generator is built in V1–V2. Source 1, 3, and 4 are simulated; Source 2 is a real public API.

### 5.1 Source 1 — Order & Delivery database (OLTP, PostgreSQL)

- **Role:** system of record for orders; the highest-business-value source
- **Planned table `orders`:**
  - `order_id` (PK), `customer_id`
  - `pickup_time`, `promised_time`, `delivered_time` (nullable)
  - `driver_id`, `zone_id`
  - `status`
  - `items_ordered`, `items_delivered` (nullable)
  - `pickup_lat`, `pickup_lon`, `dropoff_lat`, `dropoff_lon`
  - `created_at`, `updated_at`
- **Generation:** a Python script produces multi-week history and a continuing daily feed; statuses progress realistically over time
- **Ingestion:** batch, incremental using `updated_at` as the watermark; daily initially, hourly in later versions
- **Defects to inject deliberately:**
  - `delivered_time` null for open orders (expected, not an error)
  - status updated late (an order appears as `in_transit` in one load and `delivered` in the next)
  - `driver_id` that does not exist in the driver schedule
  - `delivered_time` earlier than `pickup_time`
  - `items_delivered > items_ordered`
  - duplicate rows caused by repeated extraction
- **Failure modes:** database connection lost mid-load; incremental load skipping rows updated after the watermark was read
- **Mitigations (planned):** idempotent upserts keyed on `order_id`; overlap window on the watermark; retry on connection errors

### 5.2 Source 2 — Weather API (public REST, JSON)

- **Role:** explanatory context for delays
- **Candidate API:** a free public API supporting hourly weather by latitude/longitude (for example Open-Meteo). **To verify before V2:** rate limits, terms of use, hourly granularity, historical coverage, and returned timezone
- **Planned fields:** `zone_id` (from our mapping), `observation_time`, `condition`, `temperature_c`, `precipitation_mm`
- **Ingestion:** scheduled polling, hourly or daily by version; one request per zone centroid
- **Defects and risks:**
  - rate limiting
  - missing hours for some zones
  - timezone different from the Order DB
  - response schema changes without notice
  - API downtime
- **Mitigations (planned):** store raw JSON responses as received; explicit timezone parameter and conversion to UTC; flag stale or missing weather rather than reusing old values silently

### 5.3 Source 3 — Driver Schedule (CSV / Excel)

- **Role:** who works, where, and when; origin of `dim_driver` history
- **Planned columns:** `driver_id`, `driver_name`, `hire_date`, `shift_date`, `shift_start`, `shift_end`, `assigned_zone`
- **Generation:** a script produces one file per day or per shift period, mimicking manual exports
- **Ingestion:** batch, file pickup; processed files are tracked so re-exports are not double-loaded
- **Defects to inject deliberately:**
  - inconsistent date/time formats between exports
  - renamed columns in some files (schema drift)
  - duplicate rows from repeated exports
  - missing files for some days
  - driver assigned to two zones in the same shift
- **Failure modes:** file missing, file malformed, partially written file
- **Mitigations (planned):** schema validation before load with alert on mismatch; file-level checksum or name registry; quarantine of bad files

### 5.4 Source 4 — GPS / telemetry logs (event data)

- **Role:** highest-volume source; basis for geospatial processing and speed metrics
- **Planned fields:** `driver_id`, `lat`, `lon`, `speed_kmh`, `event_timestamp`; the pipeline adds `ingested_at` and `source_batch_id`
- **Generation:** simulated pings during driver shifts (roughly one per 10 seconds), as JSON or CSV files per time window
- **Ingestion:** micro-batch every 5–15 minutes (see ADR-001)
- **Defects to inject deliberately:**
  - coordinates outside the city bounds
  - impossible speeds
  - timestamps in the future or far in the past
  - duplicates on `(driver_id, event_timestamp)`
  - late-arriving events (device offline, uploaded later)
  - gaps in signal
- **Failure modes:** sudden volume spikes, partial batch files, re-sent batches
- **Mitigations (planned):** reject-and-log for invalid records; deduplication on `(driver_id, event_timestamp)`; event-time based aggregation with an explicit lateness policy (decided in V7)

### 5.5 Volume assumptions (to be validated)

- Baseline simulation: ~200 drivers, ~6,000 orders per day, ~700,000 GPS events per day (200 drivers × 1 ping / 10 s × 10 h)
- Stress scenario for V7: scale up to ~500 drivers (~1.8 million GPS events per day) and beyond, to demonstrate why a distributed engine is justified
- These numbers are design assumptions, recorded so they can be challenged and revised

---

## 6. Functional requirements

Each requirement traces to business questions (BQ) and KPIs.

- **FR-1 Order ingestion:** ingest orders from the Order DB incrementally on a daily schedule. *(BQ-OPS-1, BQ-MGT-1)*
- **FR-2 Weather ingestion:** retrieve hourly or daily weather for every zone from a public API. *(BQ-OPS-4, BQ-CS-3)*
- **FR-3 Schedule ingestion:** load driver schedule files per day or shift, tolerant of known format differences. *(BQ-OPS-3, BQ-MGT-4)*
- **FR-4 GPS ingestion:** load driver GPS events in micro-batches of 5–15 minutes. *(KPI-9)*
- **FR-5 Raw preservation:** store every source's data unmodified in a raw layer with ingestion metadata, so any later step can be replayed.
- **FR-6 Standardisation:** convert timestamps to UTC and unify formats across sources.
- **FR-7 Delivery metrics:** compute `distance_km`, `promised_minutes`, `actual_minutes`, `delay_minutes`, `is_on_time`, `is_otif`, `delivery_cost` per completed delivery. *(KPI-1 to KPI-5)*
- **FR-8 Dimensional warehouse:** expose `fact_delivery` with `dim_driver`, `dim_zone`, `dim_weather`, `dim_time`. *(all BQ-C and BQ-T questions)*
- **FR-9 Driver history:** preserve driver-to-zone history using SCD Type 2 so that "which zone was driver X in on date Y" is answerable. *(BQ-MGT-4)*
- **FR-10 Reporting views:** provide SQL views for on-time rate, OTIF, cost per delivery, driver productivity, and zone load. *(BQ-OPS-1/2/3, BQ-FIN-1..4, BQ-MGT-1..4)*
- **FR-11 Open-order visibility:** expose open and overdue orders per zone. *(BQ-CS-1, KPI-8)*
- **FR-12 Data quality handling:** invalid records are rejected or flagged and written to an error table with a reason; they are never dropped silently.
- **FR-13 GPS aggregation (V7):** aggregate GPS events into zone × time-window metrics. *(KPI-9, BQ-OPS-3)*
- **FR-14 Orchestration:** run the full pipeline on a schedule with dependencies, retries, and visible failures (V5).

---

## 7. Non-functional requirements

Targets are initial and measurable; they will be reviewed after V3 using real timings.

- **NFR-1 Idempotency:** re-running any ingestion or transformation for the same period produces identical results and zero duplicate rows. *Test:* run the same load twice and compare row counts and checksums.
- **NFR-2 Freshness:** the warehouse reflects all orders up to the end of the previous day by 07:00 local time. GPS-derived aggregates are available within 15 minutes plus processing time of the micro-batch window.
- **NFR-3 Reliability:** a failed task is retried automatically up to 3 times with backoff; if it still fails, a visible alert is raised and downstream tasks do not run on partial data. *Test:* kill a source mid-run.
- **NFR-4 Data quality:** records violating defined rules are rejected or flagged into an error table with the rule name and timestamp. Target: 100% of injected defect types detected and logged.
- **NFR-5 Performance:** the daily batch for the baseline volume (~6,000 orders) completes in under 5 minutes; a 100,000-order run completes in under 15 minutes. *Reviewed after V3.*
- **NFR-6 Scalability:** the GPS processing design must handle a simulated volume beyond what comfortably fits in single-machine pandas memory (V7).
- **NFR-7 Reproducibility:** the entire stack starts from a clean machine with a single `docker-compose up` plus documented configuration (V8).
- **NFR-8 Observability:** every run logs row counts in/out, rejected counts, and duration per task.
- **NFR-9 Security:** no credentials in the repository; secrets come from environment variables; `.env` is git-ignored and `.env.example` documents required keys.
- **NFR-10 Cost:** cloud usage stays within free-tier limits; an estimated production cost is documented (V9).
- **NFR-11 Maintainability and testability:** transformation logic is in small, unit-testable functions; CI runs tests on every push (V8).

---

## 8. Scope

### In scope

- Four sources: Order DB, Weather API, Driver Schedule CSV, GPS logs
- Raw, staging, and warehouse layers
- Star-schema warehouse with an SCD Type 2 driver dimension
- Orchestrated batch pipeline and micro-batch GPS processing
- Systematic data quality checks with an error table
- PySpark aggregation for GPS data
- Docker packaging, automated tests, basic CI/CD
- Basic cloud deployment (proof of concept within free tier)
- Reporting SQL views and a simple BI/dashboard layer for validation

### Out of scope (initial 4 months)

- Real Kafka cluster and true event streaming (documented as a future extension; see ADR-001)
- Predictive modelling and machine learning, including delay prediction
- Route optimisation
- Real-time dashboards
- Multiple cities or vehicle types
- Customer dimension and customer analytics
- Real production data or real financial data
- Kubernetes deployment
- NoSQL storage (no use case that justifies it)

---

## 9. Preliminary data model

Full design (ERD, keys, SCD2 mechanics) is done in V2 and V4. This section fixes the decisions that must not be left ambiguous.

### 9.1 Kimball four steps

- **Business process:** completing a delivery
- **Grain of `fact_delivery`:** **one row per completed delivery (one order that reached status `delivered`)**
- **Dimensions:** driver, zone, date/time, weather
- **Measures:** `distance_km`, `promised_minutes`, `actual_minutes`, `delay_minutes`, `is_on_time`, `is_otif`, `delivery_cost`

### 9.2 Planned tables

- **`fact_delivery`:** keys `delivery_id` (PK), `order_id` (degenerate dimension), foreign keys to driver, zone, date/time, weather
- **`dim_driver`:** SCD Type 2; attributes `driver_name`, `hire_date`, `current_zone` / `assigned_zone`, `is_active`, validity dates, current-row flag
- **`dim_zone`:** `zone_name`, `city`, `area_km2`, `centroid_lat`, `centroid_lon`
- **`dim_weather`:** per zone and hour: `condition`, `temperature_c`, `precipitation_mm`
- **`dim_time`:** date attributes, day of week, holiday flag, hour bucket
- **Second grain (V7):** `agg_gps_zone_window`, one row per zone per time window, for GPS-derived metrics — kept separate from `fact_delivery` because the grains differ by orders of magnitude

### 9.3 Known design issues to resolve later (not now)

- `dim_driver` with SCD2 holds several rows per driver, so the fact table needs a **surrogate key** or a date-aware join (V4)
- Whether open orders are stored anywhere in the warehouse, or only in a snapshot view used for KPI-8 (V3)
- How weather rows are joined: zone + hour of delivery, and what to do when weather is missing (V2–V3)
- Timezone handling across orders, weather, and `dim_time` (V2)
- Handling of orders whose status is corrected after the fact (late updates to `fact_delivery`) (V3)

---

## 10. Architecture layers (summary)

The diagram is in `docs/architecture/` (Task 8); this section defines each layer's responsibility.

- **Sources:** Order DB, Weather API, Driver Schedule files, GPS files/events
- **Raw layer (`raw` schema / raw files):** data exactly as received, plus `ingested_at` and `source_batch_id`; never modified, always replayable
- **Staging layer (`staging` schema):** typed, deduplicated, timezone-standardised, quality-checked data
- **Data quality step:** rule-based checks; failures go to an **error table** and, depending on severity, stop the pipeline
- **Warehouse layer (`warehouse` schema):** star schema for analytics
- **Serving:** SQL views and a dashboard for the stakeholder questions
- **Cross-cutting (later versions):** orchestration (V5), monitoring and alerting (V5–V6), containerisation (V8), cloud storage/warehouse (V9)

Early versions use a single PostgreSQL instance with separate schemas to teach layering without extra infrastructure. This is a **logical** separation of OLTP-style raw data and OLAP-style modelled data (see README, "Why separate raw and warehouse layers").

---

## 11. Assumptions

- All data except the weather API is **synthetic**; conclusions drawn from it demonstrate engineering capability, not real-world logistics performance
- Business questions are derived from industry research and role analysis, **not validated with real users**
- One city; one time zone; one currency
- Solo developer; roughly 4 months; ~10–12 hours per week
- Cloud usage restricted to free tiers
- Cost is simulated by a simple linear model
- Straight-line (haversine) distance is acceptable as an approximation
- Zones are a fixed set (e.g. a grid or district list of roughly 12–20 zones) defined by us, not by an external authority
- Orders are created and completed within the same calendar day in most cases; multi-day orders are rare

---

## 12. Open questions

To be answered and logged as the project progresses. Each lists the version where it will be resolved.

- **OQ-1:** Does the chosen weather API provide hourly data with adequate history and acceptable rate limits for ~12–20 zones? *(V2)*
- **OQ-2:** What is the real size of the generated GPS data, and is it large enough to justify Spark? *(V1 data generation, V7)*
- **OQ-3:** Should `grace_minutes` be non-zero (for example 5 minutes) for on-time? *(V3, with stakeholders' definition)*
- **OQ-4:** How should late-arriving GPS events be treated — drop, reprocess the window, or add to a correction table? *(V7)*
- **OQ-5:** ETL or ELT for the main transformation layer? *(V3, ADR planned)*
- **OQ-6:** Do open orders belong in the warehouse? *(V3)*
- **OQ-7:** Which data quality framework — dbt tests, Great Expectations, or custom? *(V6, ADR planned)*
- **OQ-8:** Which cloud provider and which managed warehouse fit the free tier best? *(V9)*
- **OQ-9:** Are the injected defect rates (for example 1–3% per defect type) realistic enough to make the quality layer meaningful? *(V1, V6)*

---

## 13. Risks

- **R-1 Synthetic data too clean or too artificial:** quality and modelling work becomes meaningless. *Mitigation:* injected defect catalogue (Section 5), reviewed in V1.
- **R-2 Scope creep:** adding technologies without a problem to solve them. *Mitigation:* every technology needs an ADR stating the problem it solves; out-of-scope list above.
- **R-3 Weather API limits or changes:** pipeline fails or has gaps. *Mitigation:* store raw responses, flag stale data, keep a mock fallback for testing.
- **R-4 Time constraint:** later versions (Spark, cloud) squeezed. *Mitigation:* V0–V5 are the minimum viable portfolio; V7 and V9 can be reduced in scope if needed.
- **R-5 Ambiguous KPI definitions:** inconsistent numbers later. *Mitigation:* Section 3 is the single source of truth; changes require a log entry.
- **R-6 Overstating results in the README or interviews:** *Mitigation:* README states what is implemented versus planned and that data is synthetic.

---

## 14. Requirement-to-version map

- **V1 (Weeks 3–4):** FR-1, FR-5, NFR-1, NFR-8 (basic); data generator for Source 1
- **V2 (Weeks 5–6):** FR-2, FR-3, FR-6; ERD for the star schema; Weather API ingestion; generator and ingestion for the driver schedule CSV (Source 3)
- **V3 (Weeks 7–8):** FR-7, FR-8 (initial), FR-10, FR-11; NFR-5 timing review
- **V4 (Weeks 9–10):** FR-8 (complete), FR-9
- **V5 (Weeks 11–12):** FR-14, NFR-3
- **V6 (Week 13):** FR-12, NFR-4
- **V7 (Week 14):** FR-4 (micro-batch processing), FR-13, NFR-6
- **V8 (Week 15):** NFR-7, NFR-9 (complete), NFR-11
- **V9 (Week 16):** NFR-10
- **Weeks 17–18:** buffer, documentation polish, interview preparation

> Note: FR-4 ingestion of GPS files into the raw layer can be prototyped earlier than V7; the Spark-based processing is what V7 delivers.

---

## 15. Glossary

- **OLTP:** database optimised for many small transactions (the Order DB)
- **OLAP:** analytical store optimised for large aggregations (the warehouse)
- **OTIF:** On-Time-In-Full; a delivery that is both on time and complete
- **Grain:** what exactly one row in a fact table represents
- **Fact table:** records business events with numeric measures
- **Dimension table:** descriptive context used to slice facts
- **SCD Type 2:** dimension history technique that keeps old versions of a row with validity dates
- **Idempotent:** running the same job repeatedly gives the same result
- **Micro-batch:** batch processing run at short intervals (minutes)
- **Watermark:** the position (such as the maximum `updated_at` seen) from which the next incremental load starts
- **Late-arriving data:** events that reach the system after the time window they belong to has been processed
- **ADR:** Architecture Decision Record; a short document explaining one technical decision and its trade-offs
