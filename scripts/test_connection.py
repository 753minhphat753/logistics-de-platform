"""
scripts/test_connection.py
Kiểm tra kết nối PostgreSQL và xác nhận 3 schema đã được tạo.
Chạy: python scripts/test_connection.py
"""

import os
import sys
from dotenv import load_dotenv

load_dotenv()

try:
    import psycopg2
except ImportError:
    print("[ERR] Thieu psycopg2. Chay: pip install psycopg2-binary")
    sys.exit(1)

try:
    conn = psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", 5432)),
        dbname=os.getenv("POSTGRES_DB", "logistics"),
        user=os.getenv("POSTGRES_USER", "postgres"),
        password=os.getenv("POSTGRES_PASSWORD"),
    )
except psycopg2.OperationalError as e:
    print(f"[ERR] Khong ket noi duoc PostgreSQL:\n{e}")
    print("\nGoi y: Kiem tra container dang chay bang `docker ps`")
    sys.exit(1)

cur = conn.cursor()

# Kiểm tra 3 schema
cur.execute(
    """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name IN ('raw', 'staging', 'warehouse')
    ORDER BY schema_name;
    """
)
schemas = [r[0] for r in cur.fetchall()]

print("[OK] Ket noi PostgreSQL thanh cong!")
print(f"   Host : {os.getenv('POSTGRES_HOST', 'localhost')}:{os.getenv('POSTGRES_PORT', 5432)}")
print(f"   DB   : {os.getenv('POSTGRES_DB', 'logistics')}")

expected = {"raw", "staging", "warehouse"}
found = set(schemas)

if found == expected:
    print(f"[OK] Schema OK : {sorted(schemas)}")
else:
    missing = expected - found
    print(f"[WARN] Schema thieu : {sorted(missing)}")
    print("   Chay: Get-Content scripts/init_db.sql | docker exec -i logistics-postgres psql -U postgres -d logistics")

cur.close()
conn.close()
