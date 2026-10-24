"""Generate synthetic data for the source (OLTP) schema.

Day 5 (clean data only):
    python scripts/generate_source_data.py --reset --no-defects
Day 6 (with intentional defects):
    python scripts/generate_source_data.py --reset
"""
import argparse
import json
import logging
import random
import sys
from datetime import datetime, timedelta
from pathlib import Path

from faker import Faker
from psycopg2.extras import execute_values

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from config.db import get_connection  # noqa: E402

log = logging.getLogger("generator")

# All timestamps are Vietnam local time (UTC+7), naive.
START = datetime(2026, 7, 1)
DAYS = 90
END = START + timedelta(days=DAYS)

ZONES = [
    # name, area_km2 (approximate), demand weight, extra late probability
    ("Quan 1", 7.73, 12, 0.02),
    ("Quan 3", 4.92, 8, 0.01),
    ("Quan 5", 4.27, 5, 0.00),
    ("Quan 7", 35.69, 9, 0.03),
    ("Quan 10", 5.72, 6, 0.00),
    ("Binh Thanh", 20.76, 11, 0.02),
    ("Phu Nhuan", 4.88, 6, 0.00),
    ("Go Vap", 19.74, 8, 0.03),
    ("Tan Binh", 22.38, 9, 0.03),
    ("Thu Duc", 211.56, 10, 0.07),
    ("Binh Tan", 51.89, 6, 0.06),
    ("Quan 12", 52.78, 5, 0.06),
]

HOURS = list(range(7, 22))
HOUR_WEIGHTS = [2, 3, 4, 6, 9, 10, 6, 4, 4, 5, 7, 10, 9, 5, 2]
PEAK_HOURS = {11, 12, 18, 19}

# Rates are relative to the number of orders (customers for DUPLICATE_CUSTOMER).
DEFECT_RATES = {
    "DELIVERED_NO_TIME": 0.02,
    "DELIVERED_BEFORE_PICKUP": 0.01,
    "STATUS_TIME_MISMATCH": 0.005,
    "DRIVER_MISSING": 0.01,
    "FEE_MISSING": 0.02,
    "LATE_UPDATED": 0.03,
    "DUPLICATE_CUSTOMER": 0.01,
}

DEFECT_DESCRIPTIONS = {
    "DELIVERED_NO_TIME": "status = DELIVERED but delivered_time is NULL",
    "DELIVERED_BEFORE_PICKUP": "delivered_time earlier than pickup_time",
    "STATUS_TIME_MISMATCH": "status is FAILED/CANCELLED but delivered_time is set",
    "DRIVER_MISSING": "status = DELIVERED but driver_id is NULL",
    "FEE_MISSING": "delivery_fee is NULL",
    "LATE_UPDATED": "updated_at is 1-5 days after delivered_time (late update)",
    "DUPLICATE_CUSTOMER": "customer shares phone and name with another customer id",
}


# ---------------------------------------------------------------- reference data
def make_reference_data(rng, fake, n_drivers, n_customers):
    zones = [
        {"zone_id": i + 1, "zone_name": z[0], "city": "HCMC", "area_km2": z[1]}
        for i, z in enumerate(ZONES)
    ]
    zone_ids = [z["zone_id"] for z in zones]
    zone_weights = [z[2] for z in ZONES]

    drivers = []
    for i in range(1, n_drivers + 1):
        drivers.append({
            "driver_id": i,
            "driver_name": fake.name(),
            "hire_date": (datetime(2023, 1, 1) + timedelta(days=rng.randint(0, 1250))).date(),
            "current_zone_id": rng.choices(zone_ids, weights=zone_weights)[0],
            "is_active": rng.random() < 0.9,
        })

    phones = set()
    customers = []
    for i in range(1, n_customers + 1):
        while True:
            phone = f"0{rng.choice(['90', '91', '93', '97', '98'])}{rng.randint(1000000, 9999999)}"
            if phone not in phones:
                phones.add(phone)
                break
        customers.append({
            "customer_id": i,
            "customer_name": fake.name(),
            "phone": phone,
            "created_at": datetime(2025, 1, 1)
            + timedelta(days=rng.randint(0, 545), seconds=rng.randint(0, 86399)),
        })

    active = [d for d in drivers if d["is_active"]]
    drivers_by_zone = {}
    for d in active:
        drivers_by_zone.setdefault(d["current_zone_id"], []).append(d["driver_id"])

    ctx = {
        "zone_ids": zone_ids,
        "zone_weights": zone_weights,
        "late_bonus": {i + 1: z[3] for i, z in enumerate(ZONES)},
        "drivers_by_zone": drivers_by_zone,
        "active_driver_ids": [d["driver_id"] for d in active],
        "n_customers": n_customers,
    }
    return zones, drivers, customers, ctx


# ---------------------------------------------------------------- orders
def make_order(order_id, rng, ctx):
    zone_id = rng.choices(ctx["zone_ids"], weights=ctx["zone_weights"])[0]
    hour = rng.choices(HOURS, weights=HOUR_WEIGHTS)[0]
    created = START + timedelta(
        days=rng.randint(0, DAYS - 1),
        hours=hour,
        minutes=rng.randint(0, 59),
        seconds=rng.randint(0, 59),
    )
    promised = created + timedelta(minutes=rng.choice([45, 60, 90, 120]))
    fee = rng.randrange(15000, 60001, 1000)
    in_flight = created >= END - timedelta(days=1) and rng.random() < 0.4

    def pick_driver():
        local = ctx["drivers_by_zone"].get(zone_id)
        if local and rng.random() < 0.9:
            return rng.choice(local)
        return rng.choice(ctx["active_driver_ids"])

    if in_flight:
        # Legitimate NULLs: these orders are still being processed.
        status = rng.choice(["CREATED", "ASSIGNED", "PICKED_UP", "IN_TRANSIT"])
        driver_id = None if status == "CREATED" else pick_driver()
        pickup = None if status in ("CREATED", "ASSIGNED") else created + timedelta(minutes=rng.randint(5, 30))
        delivered = None
        updated = created + timedelta(minutes=rng.randint(1, 30))
    else:
        status = rng.choices(["DELIVERED", "FAILED", "CANCELLED"], weights=[93, 4, 3])[0]
        if status == "CANCELLED":
            driver_id = pick_driver() if rng.random() < 0.4 else None
            pickup = None
            delivered = None
            updated = created + timedelta(minutes=rng.randint(2, 20))
        else:
            driver_id = pick_driver()
            pickup = created + timedelta(minutes=rng.randint(5, 30))
            if status == "FAILED":
                delivered = None
                updated = pickup + timedelta(minutes=rng.randint(20, 90))
            else:
                p_late = 0.10 + ctx["late_bonus"][zone_id] + (0.08 if hour in PEAK_HOURS else 0.0)
                delay = rng.randint(5, 60) if rng.random() < p_late else -rng.randint(0, 25)
                delivered = max(promised + timedelta(minutes=delay), pickup + timedelta(minutes=10))
                updated = delivered + timedelta(seconds=rng.randint(0, 300))

    return {
        "order_id": order_id,
        "customer_id": rng.randint(1, ctx["n_customers"]),
        "driver_id": driver_id,
        "zone_id": zone_id,
        "pickup_time": pickup,
        "promised_time": promised,
        "delivered_time": delivered,
        "status": status,
        "delivery_fee": fee,
        "created_at": created,
        "updated_at": updated,
    }


# ---------------------------------------------------------------- defects
def inject_defects(orders, customers, rng):
    """Corrupt a known number of rows in memory. Each order gets at most one defect."""
    n = len(orders)
    used = set()
    ids = {}

    def count(name):
        return round(DEFECT_RATES[name] * n)

    def pick(name, eligible, k):
        pool = [o for o in eligible if o["order_id"] not in used]
        chosen = rng.sample(pool, min(k, len(pool)))
        for o in chosen:
            used.add(o["order_id"])
        ids[name] = sorted(o["order_id"] for o in chosen)
        return chosen

    delivered = [o for o in orders if o["status"] == "DELIVERED"]

    for o in pick("DELIVERED_NO_TIME", delivered, count("DELIVERED_NO_TIME")):
        o["delivered_time"] = None

    for o in pick("DELIVERED_BEFORE_PICKUP", delivered, count("DELIVERED_BEFORE_PICKUP")):
        o["delivered_time"] = o["pickup_time"] - timedelta(minutes=rng.randint(5, 120))

    failed_or_cancelled = [o for o in orders if o["status"] in ("FAILED", "CANCELLED")]
    for o in pick("STATUS_TIME_MISMATCH", failed_or_cancelled, count("STATUS_TIME_MISMATCH")):
        o["delivered_time"] = o["promised_time"] + timedelta(minutes=10)

    for o in pick("DRIVER_MISSING", delivered, count("DRIVER_MISSING")):
        o["driver_id"] = None

    for o in pick("FEE_MISSING", orders, count("FEE_MISSING")):
        o["delivery_fee"] = None

    late_eligible = [
        o for o in delivered
        if o["delivered_time"] is not None and o["delivered_time"] <= END - timedelta(days=6)
    ]
    for o in pick("LATE_UPDATED", late_eligible, count("LATE_UPDATED")):
        o["updated_at"] = o["delivered_time"] + timedelta(
            days=rng.randint(1, 5), minutes=rng.randint(1, 1439)
        )

    # Duplicate customers: same phone and name, different customer_id.
    k = round(DEFECT_RATES["DUPLICATE_CUSTOMER"] * len(customers))
    sample = rng.sample(customers, 2 * k)
    dups, originals = sample[:k], sample[k:]
    for d, o in zip(dups, originals):
        d["phone"] = o["phone"]
        d["customer_name"] = o["customer_name"]
    ids["DUPLICATE_CUSTOMER"] = sorted(d["customer_id"] for d in dups)

    return ids


# ---------------------------------------------------------------- loading
ORDER_COLS = [
    "order_id", "customer_id", "driver_id", "zone_id", "pickup_time", "promised_time",
    "delivered_time", "status", "delivery_fee", "created_at", "updated_at",
]


def load_all(cur, zones, drivers, customers, orders):
    execute_values(
        cur,
        "INSERT INTO source.zones (zone_id, zone_name, city, area_km2) VALUES %s",
        [(z["zone_id"], z["zone_name"], z["city"], z["area_km2"]) for z in zones],
    )
    execute_values(
        cur,
        "INSERT INTO source.drivers (driver_id, driver_name, hire_date, current_zone_id, is_active) VALUES %s",
        [(d["driver_id"], d["driver_name"], d["hire_date"], d["current_zone_id"], d["is_active"]) for d in drivers],
    )
    execute_values(
        cur,
        "INSERT INTO source.customers (customer_id, customer_name, phone, created_at) VALUES %s",
        [(c["customer_id"], c["customer_name"], c["phone"], c["created_at"]) for c in customers],
        page_size=5000,
    )
    execute_values(
        cur,
        f"INSERT INTO source.orders ({', '.join(ORDER_COLS)}) VALUES %s",
        [tuple(o[c] for c in ORDER_COLS) for o in orders],
        page_size=5000,
    )
    # Explicit ids were inserted, so move the sequences forward.
    for table, col in [("zones", "zone_id"), ("drivers", "driver_id"),
                       ("customers", "customer_id"), ("orders", "order_id")]:
        cur.execute(
            f"SELECT setval(pg_get_serial_sequence('source.{table}', '{col}'), "
            f"(SELECT MAX({col}) FROM source.{table}))"
        )


def write_answer_key(args, defect_ids):
    summary = {
        "seed": args.seed,
        "n_orders": args.orders,
        "n_customers": args.customers,
        "defects": {
            name: {
                "description": DEFECT_DESCRIPTIONS[name],
                "rate": DEFECT_RATES[name],
                "count": len(ids),
            }
            for name, ids in defect_ids.items()
        },
    }
    docs_path = ROOT / "docs" / "data_dictionary" / "injected_defects.json"
    docs_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    data_dir = ROOT / "data"  # gitignored
    data_dir.mkdir(exist_ok=True)
    (data_dir / "defect_ids.json").write_text(json.dumps(defect_ids), encoding="utf-8")
    log.info("Answer key written: %s", docs_path)


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic source data")
    parser.add_argument("--orders", type=int, default=100000)
    parser.add_argument("--drivers", type=int, default=80)
    parser.add_argument("--customers", type=int, default=20000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--reset", action="store_true", help="truncate source tables first")
    parser.add_argument("--no-defects", action="store_true", help="generate clean data only")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    rng = random.Random(args.seed)
    fake = Faker("vi_VN")
    fake.seed_instance(args.seed)

    zones, drivers, customers, ctx = make_reference_data(rng, fake, args.drivers, args.customers)
    orders = [make_order(i, rng, ctx) for i in range(1, args.orders + 1)]
    log.info("Generated %d orders (clean)", len(orders))

    defect_ids = {}
    if not args.no_defects:
        defect_ids = inject_defects(orders, customers, rng)
        for name, ids in defect_ids.items():
            log.info("Injected %-26s %d", name, len(ids))

    conn = get_connection()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT (SELECT count(*) FROM source.orders) + (SELECT count(*) FROM source.zones)"
                    " + (SELECT count(*) FROM source.drivers) + (SELECT count(*) FROM source.customers)"
                )
                existing = cur.fetchone()[0]
                if existing and not args.reset:
                    log.error("Source tables are not empty. Re-run with --reset to reload.")
                    sys.exit(1)
                if args.reset:
                    cur.execute(
                        "TRUNCATE source.orders, source.drivers, source.customers, source.zones "
                        "RESTART IDENTITY CASCADE"
                    )
                load_all(cur, zones, drivers, customers, orders)
        log.info("Loaded data into source schema")
    finally:
        conn.close()

    if defect_ids:
        write_answer_key(args, defect_ids)


if __name__ == "__main__":
    main()
