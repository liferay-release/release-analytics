"""
apps/triage/store.py

Persists triage results to the release_analytics PostgreSQL database.

Table: fact_triage_results
  - One row per (build_id_b, testray_case_id)
  - Upsert on conflict — re-running triage for the same build overwrites
  - Stores both Claude-classified and auto-classified rows
  - Token usage tracked for cost monitoring

Usage:
    from apps.triage.store import ensure_schema, upsert_triage_results

    ensure_schema()
    upsert_triage_results(df, build_id_a=410851196, build_id_b=451312408,
                          git_hash_a="abc123", git_hash_b="def456")
"""

import pandas as pd
from datetime import datetime
from apps.triage.db import get_rap_conn


# ---------------------------------------------------------------------------
# DDL
# ---------------------------------------------------------------------------

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS fact_triage_results (
    id                   SERIAL PRIMARY KEY,
    run_date             TIMESTAMP        NOT NULL DEFAULT NOW(),

    -- Build context
    build_id_a           BIGINT           NOT NULL,
    build_id_b           BIGINT           NOT NULL,
    git_hash_a           VARCHAR(64),
    git_hash_b           VARCHAR(64),

    -- Test case identity
    testray_case_id      BIGINT,
    test_case            TEXT,

    -- Component/team (from dim_module_component_map)
    component_name       VARCHAR(255),
    team_name            VARCHAR(255),

    -- Testray result context
    status_a             VARCHAR(32),
    status_b             VARCHAR(32),
    known_flaky          BOOLEAN          DEFAULT FALSE,
    linked_issues        VARCHAR(512),
    error_message        TEXT,
    match_strategy       VARCHAR(64),

    -- Classification
    -- pre_classification: auto-classified env/infra before reasoning
    --   BUILD_FAILURE, ENV_CHROME, ENV_DEPENDENCY, ENV_DATE, ENV_SETUP, NO_ERROR
    -- classification: reasoning output or AUTO_CLASSIFIED
    --   BUG, NEEDS_REVIEW, FALSE_POSITIVE, AUTO_CLASSIFIED
    -- classifier: who produced this row — batch:v1 (legacy Anthropic API),
    --   agent:claude-opus-4-7 (in-session Claude Code), human, etc.
    pre_classification   VARCHAR(64),
    classification       VARCHAR(32)      NOT NULL DEFAULT 'NEEDS_REVIEW',
    classifier           VARCHAR(64)      NOT NULL DEFAULT 'batch:v1',
    specific_change      TEXT,
    reason               TEXT,

    -- Run metadata
    batch_number         INTEGER,
    tokens_in            INTEGER          DEFAULT 0,
    tokens_out           INTEGER          DEFAULT 0,
    api_error            TEXT,

    -- One result per test per build_b per classifier — enables head-to-head
    UNIQUE (build_id_b, testray_case_id, classifier)
);
"""

CREATE_INDEX_SQL = [
    "CREATE INDEX IF NOT EXISTS idx_triage_build_b      ON fact_triage_results (build_id_b);",
    "CREATE INDEX IF NOT EXISTS idx_triage_classification ON fact_triage_results (classification);",
    "CREATE INDEX IF NOT EXISTS idx_triage_classifier     ON fact_triage_results (classifier);",
    "CREATE INDEX IF NOT EXISTS idx_triage_component     ON fact_triage_results (component_name);",
    "CREATE INDEX IF NOT EXISTS idx_triage_run_date      ON fact_triage_results (run_date);",
]


def ensure_schema():
    """Create fact_triage_results table and indexes if they don't exist."""
    with get_rap_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(CREATE_TABLE_SQL)
            for idx_sql in CREATE_INDEX_SQL:
                cur.execute(idx_sql)
        conn.commit()
    print("fact_triage_results schema verified.")


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------

UPSERT_SQL = """
INSERT INTO fact_triage_results (
    run_date, build_id_a, build_id_b, git_hash_a, git_hash_b,
    testray_case_id, test_case, component_name, team_name,
    status_a, status_b, known_flaky, linked_issues, error_message,
    match_strategy, pre_classification, classification, classifier,
    specific_change, reason, batch_number, tokens_in, tokens_out, api_error
)
VALUES (
    %(run_date)s, %(build_id_a)s, %(build_id_b)s, %(git_hash_a)s, %(git_hash_b)s,
    %(testray_case_id)s, %(test_case)s, %(component_name)s, %(team_name)s,
    %(status_a)s, %(status_b)s, %(known_flaky)s, %(linked_issues)s, %(error_message)s,
    %(match_strategy)s, %(pre_classification)s, %(classification)s, %(classifier)s,
    %(specific_change)s, %(reason)s, %(batch_number)s, %(tokens_in)s, %(tokens_out)s,
    %(api_error)s
)
ON CONFLICT (build_id_b, testray_case_id, classifier) DO UPDATE SET
    run_date          = EXCLUDED.run_date,
    classification    = EXCLUDED.classification,
    specific_change   = EXCLUDED.specific_change,
    reason            = EXCLUDED.reason,
    pre_classification = EXCLUDED.pre_classification,
    component_name    = EXCLUDED.component_name,
    team_name         = EXCLUDED.team_name,
    match_strategy    = EXCLUDED.match_strategy,
    tokens_in         = EXCLUDED.tokens_in,
    tokens_out        = EXCLUDED.tokens_out,
    api_error         = EXCLUDED.api_error,
    batch_number      = EXCLUDED.batch_number;
"""


def upsert_triage_results(
    df: pd.DataFrame,
    build_id_a: int,
    build_id_b: int,
    git_hash_a: str,
    git_hash_b: str,
    classifier: str = "agent:claude-opus-4-7",
):
    """
    Upsert triage results DataFrame into fact_triage_results.

    Args:
        df:           DataFrame with one row per classified case
        build_id_a/b: Build IDs
        git_hash_a/b: Git hashes
        classifier:   Provenance label — 'batch:v1', 'agent:claude-opus-4-7',
                      'human', etc. Lets the same (build_id_b, case_id) hold
                      multiple independent classifications.
    """
    run_date = datetime.utcnow()
    rows_inserted = 0
    rows_skipped  = 0

    with get_rap_conn() as conn:
        with conn.cursor() as cur:
            for _, row in df.iterrows():
                # Skip rows without a case ID — can't unique-key them
                if not row.get("testray_case_id"):
                    rows_skipped += 1
                    continue

                params = {
                    "run_date":          run_date,
                    "build_id_a":        build_id_a,
                    "build_id_b":        build_id_b,
                    "git_hash_a":        git_hash_a,
                    "git_hash_b":        git_hash_b,
                    "testray_case_id":   _safe_int(row.get("testray_case_id")),
                    "test_case":         _safe_str(row.get("test_case")),
                    "component_name":    _safe_str(row.get("component_name")),
                    "team_name":         _safe_str(row.get("team_name")),
                    "status_a":          _safe_str(row.get("status_a")),
                    "status_b":          _safe_str(row.get("status_b")),
                    "known_flaky":       bool(row.get("known_flaky", False)),
                    "linked_issues":     _safe_str(row.get("linked_issues")),
                    "error_message":     _safe_str(row.get("error_message"), max_len=2000),
                    "match_strategy":    _safe_str(row.get("match_strategy")),
                    "pre_classification": _safe_str(row.get("pre_classification")),
                    "classification":    _safe_str(row.get("classification"), default="NEEDS_REVIEW"),
                    "classifier":        classifier,
                    "specific_change":   _safe_str(row.get("specific_change")),
                    "reason":            _safe_str(row.get("reason")),
                    "batch_number":      _safe_int(row.get("batch_number")),
                    "tokens_in":         _safe_int(row.get("tokens_in"), default=0),
                    "tokens_out":        _safe_int(row.get("tokens_out"), default=0),
                    "api_error":         _safe_str(row.get("api_error")),
                }
                cur.execute(UPSERT_SQL, params)
                rows_inserted += 1

        conn.commit()

    print(f"Upserted {rows_inserted} rows into fact_triage_results "
          f"(classifier={classifier}, {rows_skipped} skipped — no testray_case_id).")


# ---------------------------------------------------------------------------
# Run log — lightweight cost/audit trail
# ---------------------------------------------------------------------------

CREATE_RUN_LOG_SQL = """
CREATE TABLE IF NOT EXISTS triage_run_log (
    id           SERIAL PRIMARY KEY,
    run_date     TIMESTAMP  NOT NULL DEFAULT NOW(),
    build_id_a   BIGINT     NOT NULL,
    build_id_b   BIGINT     NOT NULL,
    git_hash_a   VARCHAR(64),
    git_hash_b   VARCHAR(64),
    classifier   VARCHAR(64) NOT NULL DEFAULT 'batch:v1',
    total_cases  INTEGER,
    bug_count    INTEGER,
    needs_review INTEGER,
    false_pos    INTEGER,
    auto_class   INTEGER,
    flaky_excl   INTEGER,
    total_tokens_in  INTEGER,
    total_tokens_out INTEGER,
    duration_seconds FLOAT,
    notes        TEXT
);
"""


def ensure_run_log():
    with get_rap_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(CREATE_RUN_LOG_SQL)
        conn.commit()


def log_run(
    build_id_a: int,
    build_id_b: int,
    git_hash_a: str,
    git_hash_b: str,
    df: pd.DataFrame,
    flaky_excluded: int,
    duration_seconds: float,
    notes: str = None,
    classifier: str = "agent:claude-opus-4-7",
):
    """Write a summary row to triage_run_log."""
    counts = df["classification"].value_counts().to_dict()
    tokens_in  = int(df["tokens_in"].sum())  if "tokens_in"  in df.columns else 0
    tokens_out = int(df["tokens_out"].sum()) if "tokens_out" in df.columns else 0

    with get_rap_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO triage_run_log (
                    build_id_a, build_id_b, git_hash_a, git_hash_b, classifier,
                    total_cases, bug_count, needs_review, false_pos, auto_class,
                    flaky_excl, total_tokens_in, total_tokens_out,
                    duration_seconds, notes
                ) VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s,
                    %s, %s, %s,
                    %s, %s
                )
            """, (
                build_id_a, build_id_b, git_hash_a, git_hash_b, classifier,
                len(df),
                counts.get("BUG", 0),
                counts.get("NEEDS_REVIEW", 0),
                counts.get("FALSE_POSITIVE", 0),
                counts.get("AUTO_CLASSIFIED", 0),
                flaky_excluded,
                tokens_in,
                tokens_out,
                duration_seconds,
                notes,
            ))
        conn.commit()
    print(f"Run logged to triage_run_log (classifier={classifier}).")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _safe_str(val, max_len: int = 512, default: str = None) -> str | None:
    if val is None or (isinstance(val, float) and pd.isna(val)):
        return default
    s = str(val).strip()
    return s[:max_len] if s else default


def _safe_int(val, default: int = None) -> int | None:
    if val is None or (isinstance(val, float) and pd.isna(val)):
        return default
    try:
        return int(val)
    except (ValueError, TypeError):
        return default
