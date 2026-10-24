import os

import psycopg2
from dotenv import load_dotenv

load_dotenv()


def _env(*names, default=None):
    for name in names:
        value = os.getenv(name)
        if value:
            return value
    return default


def get_connection():
    return psycopg2.connect(
        host=_env("POSTGRES_HOST", "PGHOST", default="localhost"),
        port=_env("POSTGRES_PORT", "PGPORT", default="5432"),
        dbname=_env("POSTGRES_DB", "PGDATABASE", default="logistics"),
        user=_env("POSTGRES_USER", "PGUSER", default="postgres"),
        password=_env("POSTGRES_PASSWORD", "PGPASSWORD"),
    )
