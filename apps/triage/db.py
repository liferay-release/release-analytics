"""
apps/triage/db.py

Database connections for the triage app.
Provides connections to both:
  - release_analytics  (RAP PostgreSQL — dim_module_component_map, dim_component, etc.)
  - testray_working_db (Testray PostgreSQL — build, caseresult, run, case)

Credentials are never hardcoded — always read from config.yml.
Mirrors the config/release_analytics_db.R pattern used in the R pipeline.

Usage:
    from apps.triage.db import get_rap_conn, get_testray_conn

    with get_rap_conn() as conn:
        df = pd.read_sql("SELECT * FROM dim_component", conn)

    with get_testray_conn() as conn:
        df = pd.read_sql("SELECT ...", conn)
"""

import os
import yaml
import psycopg2
import psycopg2.extras
from pathlib import Path
from contextlib import contextmanager


# ---------------------------------------------------------------------------
# Config loader
# ---------------------------------------------------------------------------

def _load_config() -> dict:
    """
    Load config.yml from the project root.
    Walks up from this file's location to find it.
    """
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                return yaml.safe_load(f)
    raise FileNotFoundError(
        "config.yml not found. Expected at project root (liferay-release-analytics/config.yml)"
    )


# ---------------------------------------------------------------------------
# Connection factories
# ---------------------------------------------------------------------------

@contextmanager
def get_rap_conn():
    """
    Context manager for the release_analytics PostgreSQL database.

    config.yml expected shape:
        databases:
          release_analytics:
            host: localhost
            port: 5432
            dbname: release_analytics
            user: your_user
            password: your_password
    """
    cfg = _load_config().get("databases", {}).get("release_analytics", {})
    conn = psycopg2.connect(
        host=cfg.get("host", "localhost"),
        port=int(cfg.get("port", 5432)),
        dbname=cfg.get("dbname", "release_analytics"),
        user=cfg["user"],
        password=cfg["password"],
    )
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def get_testray_conn():
    """
    Context manager for the testray_working_db PostgreSQL database.

    config.yml expected shape:
        databases:
          testray:
            host: localhost
            port: 5432
            dbname: testray_working_db
            user: your_user
            password: your_password
    """
    cfg = _load_config().get("databases", {}).get("testray", {})
    conn = psycopg2.connect(
        host=cfg.get("host", "localhost"),
        port=int(cfg.get("port", 5432)),
        dbname=cfg.get("dbname", "testray_working_db"),
        user=cfg["user"],
        password=cfg["password"],
    )
    try:
        yield conn
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Query helper
# ---------------------------------------------------------------------------

def query_df(conn, sql: str, params: tuple = None):
    """
    Execute a SQL query and return results as a pandas DataFrame.
    Uses cursor directly to avoid pandas SQLAlchemy requirement.
    """
    import pandas as pd
    import psycopg2.extras
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()
    return pd.DataFrame(rows)