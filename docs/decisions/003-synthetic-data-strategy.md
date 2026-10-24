# ADR-003 — Synthetic Data Strategy & Intentional Defect Injection

**Status:** Accepted  
**Date:** 2026-10-24  
**Deciders:** Solo developer (portfolio project)  
**Related requirements:** FR-1, FR-5, FR-12, NFR-1, NFR-4, Section 5.1 (Source 1 spec), Section 13 (Risk R-1)

---

## 1. Context

To build and validate the end-to-end logistics analytics platform (OLTP $\to$ Raw $\to$ Staging $\to$ Warehouse $\to$ Serving), realistic transactional data is required. However, real-world delivery operational databases are proprietary and confidential.

Key requirements for the data foundation:
- **Reproducibility:** Multiple test runs, CI pipelines, and peer review must produce identical datasets given the same random seed.
- **Realistic business signals:** Downstream metrics (OTIF, delay distribution, cost per delivery, driver productivity) must exhibit meaningful patterns (e.g. peak hours have higher delay rates, outer suburban zones suffer higher delay).
- **Testable data quality (V6 preparation):** In order to build a verifiable Data Quality framework with automated error logging, we need a baseline of known defects with an exact "answer key" (count and IDs) to prevent false positives and missed defects.

---

## 2. Decision

We implement an in-house synthetic data generator (`scripts/generate_source_data.py`) with the following principles:

1. **Deterministic Randomness:**
   - Independent instance of `random.Random(seed=42)` and `Faker.seed_instance(42)` ensures no reliance on global state or execution time.
   - Clean data is generated first, and intentional defects are injected afterwards in memory before insertion.
2. **Controlled Scope & Scale:**
   - 12 delivery zones (covering HCMC urban and suburban areas), 80 drivers, 20,000 customers, and 100,000 orders spanning 90 days (starting 2026-07-01).
   - All timestamps represent Vietnam local time (UTC+7, naive `TIMESTAMP`). Historical dates do not use dynamic `now()`.
3. **Intentional Defect Injection with 1:1 Defect Isolation:**
   - Specific defects (`DELIVERED_NO_TIME`, `DELIVERED_BEFORE_PICKUP`, `STATUS_TIME_MISMATCH`, `DRIVER_MISSING`, `FEE_MISSING`, `LATE_UPDATED`, `DUPLICATE_CUSTOMER`) are injected into designated percentages of records.
   - **Crucial Rule:** Each order receives **at most one** defect. This guarantees that SQL verification queries match the expected answer key count exactly without ambiguous cross-defect interference.
   - Defect injection occurs **in-memory before INSERT**, avoiding `UPDATE` statements that would fire database triggers (`trg_orders_updated_at`) and overwrite intentional anomaly watermarks.
4. **Answer Key Generation:**
   - The generator outputs summary counts to `docs/data_dictionary/injected_defects.json` (tracked in git) and detailed ID sets to `data/defect_ids.json` (gitignored).

---

## 3. Considered Alternatives

### Alternative A: Using Public Datasets (e.g., Brazilian E-Commerce / Olist, NYC Taxi)
- *Pros:* Real-world human noise and organic behavior.
- *Cons:* Schema does not align with last-mile driver telemetry or scheduled delivery slots; lack of known ground truth for specific defect injection; difficult to test incremental CDC-like loading on `updated_at`.

### Alternative B: Generating Only Clean Synthetic Data
- *Pros:* Simpler generator logic, no risk of corrupted business calculations.
- *Cons:* Ineffective for testing a production-grade Data Quality pipeline. A pipeline that only ingests pristine data cannot demonstrate anomaly detection, error table isolation, or alert thresholds (V6).

---

## 4. Consequences & Known Limitations

### Positive Consequences
- **Automated Verification:** The exact count of injected defects matches SQL assertion queries 100%, enabling automated regression testing.
- **Realistic Trends:** Higher delay rates in peak hours (11–12h, 18–19h) and outer districts (Thu Duc, Binh Tan, District 12) provide authentic signals for BI reporting.
- **Safety & Idempotency:** The script enforces `--reset` protection to prevent accidental duplicate inserts into non-empty tables.

### Known Limitations (Recorded for transparency)
- **Uniform Customer Demand:** Orders are uniformly sampled across customers, whereas in reality Pareto distributions apply (20% of power customers drive 80% of volume).
- **No Day-of-Week Seasonality:** Order volumes per day are roughly uniform across weekdays and weekends.
- **No Weather Correlation in V1:** Weather impacts on delivery delays will be coupled at V2 when ingesting the Open-Meteo Weather API.
