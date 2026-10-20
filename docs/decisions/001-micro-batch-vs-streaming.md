# ADR-001 — GPS Ingestion: Micro-Batch vs. True Streaming

**Status:** Accepted  
**Date:** 2026-10-19  
**Deciders:** Solo developer (portfolio project)  
**Related requirements:** FR-4, NFR-2, NFR-6, NFR-7, Section 5.4 (GPS source spec), Section 8 (Scope)

---

## 1. Context

The platform ingests GPS / telemetry events produced by ~200 drivers during their shifts. Each driver emits roughly one ping every 10 seconds, yielding approximately **700,000 events per day** at baseline volume (and up to ~1.8 million under the V7 stress scenario — see NFR-6 and Section 5.5).

These events are used to:
- Compute **KPI-9** (driver average speed per time window), sliced by driver and zone.
- Populate **`agg_gps_zone_window`** — the second grain table in the warehouse (one row per zone × time window).
- Support **BQ-OPS-3** (zone load / driver overload detection).

The freshness requirement (NFR-2) states that GPS-derived aggregates must be available within **15 minutes plus processing time** of the micro-batch window closing.

Two approaches were considered:

| Approach | Description |
|---|---|
| **A — Micro-batch (chosen)** | GPS files are dumped every 5–15 minutes; a scheduled job picks them up, applies quality checks, and aggregates them with PySpark (V7) |
| **B — True streaming** | A real Kafka cluster receives events continuously; a Flink or Spark Structured Streaming job processes them in near-real-time |

---

## 2. Decision

**We use micro-batch ingestion (Approach A) for the entire duration of the portfolio project.**

GPS events are written as JSON/CSV files covering 5–15 minute windows. A scheduled job reads each batch, validates and deduplicates records, and aggregates them into `agg_gps_zone_window`. Processing is done with PySpark (introduced in V7) to demonstrate distributed-compute skills without requiring a running Kafka cluster.

True streaming (Approach B) is explicitly **out of scope** for the initial 4-month build and is documented as the natural next evolution of this design.

---

## 3. Rationale

### 3.1 Why micro-batch is sufficient

- **The business latency target is 15 minutes.** No stakeholder question requires sub-second or second-level freshness for GPS data. The Ops team's decision cycle (reinforcing a zone, calling in standby drivers) operates at 30-minute to 1-hour granularity. A 5–15 minute batch window satisfies NFR-2 comfortably.
- **The GPS source is already file-based in the simulation.** The data generator writes GPS records as files per time window (Section 5.4). Polling for new files is a natural fit; there is no producer that pushes events to a broker.
- **Micro-batch processing is idempotent by design.** Each batch file covers a fixed time window and can be replayed without side effects (NFR-1). True streaming requires careful offset management and exactly-once semantics, which add significant engineering complexity.
- **Late-arriving events are handled explicitly.** GPS devices can go offline and upload buffered events late (Section 5.4 defect catalogue). With micro-batch, late events are simply picked up in a later batch window; the aggregation uses **event-time** timestamps, not ingestion time. The lateness policy will be finalised in V7 (OQ-4).

### 3.2 Why true streaming is deferred

- **Operational overhead.** Running a production-grade Kafka cluster (or a cloud-managed equivalent) adds infrastructure cost and complexity that is not justified by the business latency requirement. Free-tier cloud options for Kafka are limited.
- **Scope constraint.** The project scope explicitly excludes a "real Kafka cluster and true event streaming" (Section 8, Out of scope). Adding it without a demonstrated need would be scope creep (Risk R-2), which requires an ADR to justify.
- **Portfolio signal.** The bigger engineering challenge at V7 is demonstrating that **PySpark** can handle the GPS volume that outgrows single-machine pandas (NFR-6). This signal is cleanly delivered by micro-batch + Spark without the noise of broker management.

### 3.3 Why this is not just a workaround

Micro-batch is the industry-standard pattern for exactly this latency tier. Apache Spark's own Structured Streaming implements micro-batch execution internally. Choosing micro-batch is an affirmative design decision, not a limitation imposed by tooling gaps.

---

## 4. Alternatives considered

### Option B — True streaming with Kafka + Spark Structured Streaming

| Dimension | Assessment |
|---|---|
| Latency | Sub-second to a few seconds — far below the 15-minute requirement |
| Complexity | High: Kafka cluster, topic management, consumer group offsets, exactly-once config |
| Cost | Exceeds free-tier limits for a managed Kafka service |
| Late data | Requires watermark tuning in Structured Streaming; more brittle |
| Portfolio value | Strong signal on streaming skills, but at the cost of obscuring the core DE pipeline work |
| Fit with simulation | The simulated GPS source does not push to a broker; a Kafka producer shim would be needed |

**Verdict:** The overhead is not proportionate to the latency gain. Deferred to a future extension.

### Option C — Pure batch (daily GPS load)

Ingest all GPS events once per day alongside the main order batch.

**Verdict:** Rejected. A daily aggregation cannot support BQ-OPS-3 (zone overload during the day) or the 15-minute freshness requirement (NFR-2). The GPS data has fundamentally different temporal granularity from the order data and must be treated separately.

---

## 5. Consequences

### Positive

- Simple, reliable, and idempotent ingestion loop with a clear trigger (new file in the landing zone).
- Easy to test: replay any batch file in isolation without a running broker.
- PySpark is introduced at the right moment (V7) motivated by a real volume problem (NFR-6), not added speculatively.
- The design makes the streaming upgrade path clear and low-friction (see Section 6).

### Negative / trade-offs

- Maximum freshness is bounded by the batch window (5–15 minutes). If a future business requirement demands true real-time alerting (e.g. a driver speeding alert within seconds), this design cannot satisfy it without the streaming upgrade.
- Each batch window must be kept small enough to meet NFR-2. The scheduler (Airflow, V5) must reliably trigger every 5–15 minutes; missed triggers accumulate lag.
- Late-arriving events that cross a batch window boundary require a lateness policy (OQ-4, resolved in V7).

---

## 6. Future upgrade path

When the business requires sub-minute latency (e.g. real-time driver tracking or instant zone alerts), this design can be extended as follows without replacing it:

1. **Add a Kafka producer** on the GPS file writer side — minimal change to the simulation layer.
2. **Replace the file-polling job** with a Spark Structured Streaming job reading from the Kafka topic — same transformation logic, different trigger.
3. **Retain micro-batch as a fallback** for replay or backfill scenarios.

The transformation and aggregation code in V7 will be written in a way that is compatible with both micro-batch and streaming triggers (i.e., no assumptions about file-based input beyond the V7 implementation).

---

## 7. Revisit when

This decision should be reconsidered if any of the following occurs:

- A stakeholder requirement appears that needs GPS-based alerts in under 1 minute (e.g. instant speeding or off-route alerts).
- Micro-batch processing time exceeds the batch window for 3 consecutive runs (the job can no longer keep up, so lag accumulates).
- More than X% of GPS events arrive late enough to force reprocessing of closed windows (set X after measuring the real late-arrival rate in V1/V7).
- The GPS source changes from files to a push-based producer (events already arrive through a broker).

---

## 8. References

- `docs/architecture/v0-requirements.md` — FR-4, NFR-2, NFR-6, Section 5.4, Section 8
- `README.md` — Data Sources table (Source 4: GPS / Telemetry Logs, micro-batch 5–15 min)
- [Apache Spark — Structured Streaming Programming Guide](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html)
- [Martin Kleppmann — *Designing Data-Intensive Applications*, Ch. 11 — Stream Processing](https://dataintensive.net/)
