"""
apps/triage/prepare.py

Build a triage run bundle for the dev's own Claude Code session to classify.

Usage:
    python3 apps/triage/prepare.py from-db --build-a <A> --build-b <B>

Emits apps/triage/runs/r_<ts>_<A>_<B>/:
    run.yml              metadata (build ids, hashes, routine, input mode)
    diff_list.csv        one row per PASSED→FAILED/BLOCKED/UNTESTED case,
                         enriched with component/team + pre_classification
    hunks.txt            filtered git diff (hunks matching failing tests)
    git_diff_full.diff   full unfiltered diff (for fallback inspection)
    test_fragments.txt   fragments fed to extract_relevant_hunks.py
    prompt.md            instructions for the dev's Claude Code session
    results.schema.json  JSON schema validating results.json

The dev's Claude Code session reads prompt.md, classifies, writes
results.json. Then `submit.py <run_dir>` validates and upserts.

CSV and API input modes are planned but not yet implemented here (step 2).
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras
import yaml

from apps.triage import prompt_helpers

PROJECT_ROOT = Path(__file__).resolve().parents[2]
TRIAGE_DIR   = Path(__file__).resolve().parent
RUNS_DIR     = TRIAGE_DIR / "runs"
CONFIG_PATH  = PROJECT_ROOT / "config" / "config.yml"

DEFAULT_CLASSIFIER = "agent:claude-opus-4-7"

GIT_DIFF_EXCLUDES = [
    ":!**/artifact.properties",
    ":!**/.releng/**",
    ":!**/liferay-releng.changelog",
    ":!**/app.changelog",
    ":!**/app.properties",
    ":!**/bnd.bnd",
    ":!**/packageinfo",
    ":!**/*.xml",
    ":!**/*.properties",
    ":!**/*.yml",
    ":!**/*.yaml",
    ":!**/*.tf",
    ":!**/*.sh",
    ":!**/*.scss",
    ":!**/*.css",
    ":!**/*.gradle",
    ":!**/package.json",
    ":!**/*.json",
    ":!cloud/**",
]


# ---------------------------------------------------------------------------
# Config + DB
# ---------------------------------------------------------------------------

def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def _connect(db_cfg: dict):
    return psycopg2.connect(
        host=db_cfg["host"], port=int(db_cfg.get("port", 5432)),
        dbname=db_cfg["dbname"], user=db_cfg["user"], password=db_cfg["password"],
    )


def _strip_sql_comments(sql: str) -> str:
    return "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--"))


# ---------------------------------------------------------------------------
# Step 1: test_diff — three input paths, one output shape
# ---------------------------------------------------------------------------
#
# The downstream pipeline (git diff → hunks → prompt) needs a DataFrame with
# these columns:
#
#   testray_case_id, test_case, known_flaky, testray_component_name,
#   status_a, status_b, error_message, linked_issues
#
# We produce that shape from three possible sources for the target side:
#   - from-db  (both baseline and target from testray_analytical)
#   - from-csv (baseline from DB, target from a Testray CSV export)
#   - from-api (baseline from DB, target from Testray REST) — future
# ---------------------------------------------------------------------------

# Worst-status-wins order for de-duping retry rows in a Testray CSV export.
_STATUS_RANK = {"FAILED": 4, "BLOCKED": 3, "UNTESTED": 2, "PASSED": 1}


def fetch_build_caseresults(build_id: int, db_cfg: dict) -> pd.DataFrame:
    """All case results for a single build from testray_analytical — returns
    raw rows (one per run × case). Aggregation happens inside
    compute_test_diff so baseline and target can use different semantics.
    """
    sql = """
        SELECT case_id, case_name, case_flaky, component_name, team_name,
               status, errors, jira_issue
        FROM caseresult_analytical
        WHERE build_id = %s
    """
    with _connect(db_cfg) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, (build_id,))
            return pd.DataFrame(cur.fetchall())


def _testray_oauth_token(cfg: dict) -> str:
    """OAuth2 client_credentials flow against the Testray Liferay instance.
    Returns a bearer token. Mirrors extract/extract_testray.R::get_token()."""
    base = cfg["base_url"].rstrip("/")
    if not cfg.get("client_id") or not cfg.get("client_secret"):
        raise SystemExit(
            "testray.client_id / testray.client_secret missing from config.yml. "
            "Both are required for from-api mode."
        )
    data = urllib.parse.urlencode({
        "grant_type":    "client_credentials",
        "client_id":     cfg["client_id"],
        "client_secret": cfg["client_secret"],
    }).encode()
    req = urllib.request.Request(f"{base}/o/oauth2/token", data=data)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    token = body.get("access_token")
    if not token:
        raise SystemExit(f"OAuth2 token response had no access_token: {body}")
    return token


def _testray_fetch_paginated(
    endpoint: str, params: dict, token: str, base_url: str,
    page_size: int = 500, sleep_between: float = 0.3,
) -> list[dict]:
    """Follow Liferay Objects pagination until lastPage. Handles token
    refresh on 401 by raising SystemExit (caller should get a fresh one)."""
    base = base_url.rstrip("/")
    items: list[dict] = []
    page = 1
    while True:
        q = dict(params)
        q["page"]     = page
        q["pageSize"] = page_size
        url = f"{base}{endpoint}?{urllib.parse.urlencode(q)}"
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise SystemExit("Testray API 401 — token expired. Re-run.")
            raise
        items.extend(data.get("items", []))
        last_page = data.get("lastPage", 1)
        if page >= last_page:
            break
        page += 1
        time.sleep(sleep_between)
    return items


def fetch_build_caseresults_api(build_id: int, cfg: dict) -> pd.DataFrame:
    """Fetch all case results for a build via Testray REST. Returns the
    same column shape as parse_testray_csv / fetch_build_caseresults, with
    `case_name`, `component_name`, `team_name` left blank (filled from
    baseline on case_id match in compute_test_diff).

    `linked_issues` (Jira) is NOT populated — not a direct field on the
    caseresult object. Documented gap; can be enriched later by following
    the subtask link if needed.
    """
    token = _testray_oauth_token(cfg)
    items = _testray_fetch_paginated(
        "/o/c/caseresults",
        {
            "filter": f"r_buildToCaseResult_c_buildId eq '{build_id}'",
            "fields": "id,dueStatus,errors,"
                      "r_caseToCaseResult_c_caseId,"
                      "r_componentToCaseResult_c_componentId,"
                      "r_teamToCaseResult_c_teamId",
        },
        token=token, base_url=cfg["base_url"],
    )
    if not items:
        return pd.DataFrame()
    return pd.DataFrame({
        "case_id":        [it.get("r_caseToCaseResult_c_caseId") for it in items],
        "case_name":      [None] * len(items),
        "case_flaky":     [None] * len(items),
        "component_name": [None] * len(items),
        "team_name":      [None] * len(items),
        "status":         [(it.get("dueStatus") or {}).get("key") for it in items],
        "errors":         [it.get("errors") for it in items],
        "jira_issue":     [None] * len(items),
    })


def parse_testray_csv(path: Path) -> pd.DataFrame:
    """Parse a Testray CSV export (one build's results) into a DataFrame with
    the same column names as fetch_build_caseresults. `case_id` is blank —
    it's filled later by matching to the baseline DataFrame on
    (case_name, component). Returns raw rows (one per run)."""
    raw = pd.read_csv(path)
    required = {"Case Name", "Component", "Status"}
    missing = required - set(raw.columns)
    if missing:
        raise SystemExit(f"Testray CSV at {path} is missing columns: {missing}")

    return pd.DataFrame({
        "case_id":        [None] * len(raw),
        "case_name":      raw["Case Name"].astype(str),
        "case_flaky":     [None] * len(raw),    # filled from baseline on match
        "component_name": raw["Component"].astype(str),
        "team_name":      raw.get("Team",    pd.Series([None] * len(raw))),
        "status":         raw["Status"].astype(str),
        "errors":         raw.get("Errors",  pd.Series([None] * len(raw))),
        "jira_issue":     raw.get("Issues",  pd.Series([None] * len(raw))),
    })


def _aggregate_baseline(df: pd.DataFrame, key_cols: list[str]) -> pd.DataFrame:
    """For each key, status='PASSED' if any retry passed — otherwise worst
    status wins. Matches the semantics of test_diff.sql's PASSED filter,
    where any passing run is enough to count the case as "passing" in A."""
    if df.empty:
        return df
    df = df.copy()
    df["_is_pass"] = (df["status"] == "PASSED").astype(int)
    df["_rank"]    = df["status"].map(_STATUS_RANK).fillna(0).astype(int)
    # Prefer passing rows; fall back to worst-status row.
    df = df.sort_values(["_is_pass", "_rank"], ascending=[False, False])
    out = df.drop_duplicates(subset=key_cols, keep="first") \
            .drop(columns=["_is_pass", "_rank"]) \
            .reset_index(drop=True)
    return out


def _aggregate_target(df: pd.DataFrame, key_cols: list[str]) -> pd.DataFrame:
    """For each key, keep the worst-status row — any failed retry should
    surface (and bring its error_message / linked issues with it)."""
    if df.empty:
        return df
    df = df.copy()
    df["_rank"] = df["status"].map(_STATUS_RANK).fillna(0).astype(int)
    out = df.sort_values("_rank", ascending=False) \
            .drop_duplicates(subset=key_cols, keep="first") \
            .drop(columns="_rank") \
            .reset_index(drop=True)
    return out


def compute_test_diff(baseline: pd.DataFrame, target: pd.DataFrame) -> pd.DataFrame:
    """Inner-join baseline (A) and target (B) and keep cases that PASSED in A
    and FAILED/BLOCKED/UNTESTED in B.

    Join key:
      - Both sides have non-null case_id → join on case_id (DB × DB, DB × API).
      - Target lacks case_id (Testray CSV) → join on (case_name, component).
        Baseline's case_id is inherited on match; unmatched target rows are
        dropped (no persistable key).
    """
    if baseline.empty or target.empty:
        return pd.DataFrame()

    target_has_ids = target["case_id"].notna().any()
    key_cols = ["case_id"] if target_has_ids else ["case_name", "component_name"]

    b = _aggregate_baseline(baseline, key_cols=key_cols)
    t = _aggregate_target(target,     key_cols=key_cols)

    merged = b.merge(t, on=key_cols, how="inner", suffixes=("_a", "_b"))
    diff = merged[
        (merged["status_a"] == "PASSED")
        & merged["status_b"].isin(["FAILED", "BLOCKED", "UNTESTED"])
    ].copy()

    # After merge, the join keys stay un-suffixed; other shared columns get
    # _a / _b suffixes. Pick the baseline side for identity metadata.
    case_id_col = "case_id"          if target_has_ids     else "case_id_a"
    name_col    = "case_name_a"      if target_has_ids     else "case_name"
    comp_col    = "component_name_a" if target_has_ids     else "component_name"
    flaky_col   = "case_flaky_a"   # case_flaky is always a shared non-join column

    out = pd.DataFrame({
        "testray_case_id":        diff[case_id_col],
        "test_case":              diff[name_col],
        "known_flaky":            diff[flaky_col].fillna(False),
        "testray_component_name": diff[comp_col],
        "status_a":               diff["status_a"],
        "status_b":               diff["status_b"],
        "error_message":          diff["errors_b"],
        "linked_issues":          diff["jira_issue_b"],
    })
    out = out.dropna(subset=["testray_case_id"]).reset_index(drop=True)
    return out


# ---------------------------------------------------------------------------
# Step 2: git_hash + routine lookup from dim_build
# ---------------------------------------------------------------------------

def fetch_build_metadata(build_id: int, db_cfg: dict) -> dict | None:
    """Fetch git_hash / routine_id / build_name for a single build from
    dim_build. Returns None if not found."""
    sql = """
        SELECT build_id, build_name, git_hash, routine_id
        FROM dim_build
        WHERE build_id = %s
    """
    with _connect(db_cfg) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, (build_id,))
            row = cur.fetchone()
    return dict(row) if row else None


def resolve_build_metadata(build_a: int, build_b: int, db_cfg: dict) -> dict:
    ra = fetch_build_metadata(build_a, db_cfg)
    rb = fetch_build_metadata(build_b, db_cfg)
    missing = [b for b, r in ((build_a, ra), (build_b, rb)) if r is None]
    if missing:
        raise SystemExit(f"Build(s) not in dim_build: {missing}")
    if ra["routine_id"] != rb["routine_id"]:
        print(f"WARNING: builds are on different routines "
              f"(A={ra['routine_id']}, B={rb['routine_id']}). "
              f"Diff may still be meaningful but test_diff will miss cases "
              f"that don't run on both.", file=sys.stderr)
    return {
        "hash_a":       ra["git_hash"],
        "hash_b":       rb["git_hash"],
        "routine_id":   ra["routine_id"],
        "build_a_name": ra["build_name"],
        "build_b_name": rb["build_name"],
    }


# ---------------------------------------------------------------------------
# Step 3: git diff with exclusions
# ---------------------------------------------------------------------------

def run_git_diff(git_repo: Path, hash_a: str, hash_b: str, out_path: Path) -> int:
    git_dir = Path(git_repo).expanduser()
    if not (git_dir / ".git").is_dir():
        raise SystemExit(f"Not a git repo: {git_dir}. "
                         f"Set git.repo_path in config/config.yml.")

    for h in (hash_a, hash_b):
        r = subprocess.run(
            ["git", "-C", str(git_dir), "cat-file", "-e", f"{h}^{{commit}}"],
            capture_output=True,
        )
        if r.returncode != 0:
            print(f"Fetching {h[:12]}...", file=sys.stderr)
            subprocess.run(["git", "-C", str(git_dir), "fetch", "--quiet", "origin"],
                           check=False)

    cmd = ["git", "-C", str(git_dir), "diff", hash_a, hash_b, "--"] + GIT_DIFF_EXCLUDES
    with open(out_path, "wb") as f:
        subprocess.run(cmd, stdout=f, check=True)
    return sum(1 for _ in open(out_path))


# ---------------------------------------------------------------------------
# Step 4: fragments + relevant hunks
# ---------------------------------------------------------------------------

def derive_test_fragments(df: pd.DataFrame) -> set[str]:
    """Extract module/class tokens from test_case names — used by
    extract_relevant_hunks.py to filter the diff to relevant files."""
    fragments: set[str] = set()
    for name in df["test_case"].dropna():
        name = str(name)
        if ".spec.ts" in name or ".spec.js" in name:
            spec = re.split(r"[/\s>]", name)[0].split("/")[-1]
            if spec:
                fragments.add(spec)
            parts = name.split("/")
            if len(parts) > 1:
                fragments.add(parts[0])
        elif "." in name and ">" not in name:
            classname = name.split(".")[-1].split("#")[0].strip()
            if classname:
                fragments.add(classname + ".java")
            for part in name.split("."):
                if part not in ("com", "liferay", "internal", "test", "impl") \
                        and len(part) > 4:
                    fragments.add(part)
                    break
        elif name.startswith("LocalFile."):
            module = name.replace("LocalFile.", "").split("#")[0]
            fragments.add(module.lower())
    return fragments


def run_extract_hunks(diff_path: Path, fragments_path: Path, out_path: Path) -> None:
    subprocess.run(
        ["python3", str(TRIAGE_DIR / "extract_relevant_hunks.py"),
         str(diff_path), str(fragments_path),
         "--auto", "--stats", "--unmatched",
         "-o", str(out_path)],
        check=True,
    )


# ---------------------------------------------------------------------------
# Step 5: component/team enrichment (optional) + pre-classification
# ---------------------------------------------------------------------------

def enrich_and_pre_classify(df: pd.DataFrame) -> pd.DataFrame:
    cfg        = prompt_helpers.load_triage_config()
    extra_pats = cfg.get("auto_classify_patterns") or {}

    df = df.rename(columns={"testray_component_name": "component_name"}).copy()

    if "team_name" not in df.columns:
        df["team_name"] = None

    # CSV-based team_name enrichment (no DB dependency — works on dev laptops
    # without release_analytics DB).
    df["team_name"] = df["component_name"].apply(
        prompt_helpers.team_for_component
    ).fillna(df["team_name"])

    df["pre_classification"] = df["error_message"].apply(
        lambda e: prompt_helpers.pre_classify(e, extra_pats)
    )

    return df


# ---------------------------------------------------------------------------
# Step 6: artifacts
# ---------------------------------------------------------------------------

RESULTS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "TriageResults",
    "type": "object",
    "required": ["run_id", "classifier", "results"],
    "additionalProperties": False,
    "properties": {
        "run_id":     {"type": "string"},
        "classifier": {"type": "string"},
        "notes":      {"type": "string"},
        "results": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["testray_case_id", "classification", "confidence", "reason"],
                "additionalProperties": False,
                "properties": {
                    "testray_case_id": {"type": "integer"},
                    "classification":  {"enum": ["BUG", "NEEDS_REVIEW", "FALSE_POSITIVE"]},
                    "confidence":      {"enum": ["high", "medium", "low"]},
                    "culprit_file":    {"type": ["string", "null"]},
                    "specific_change": {"type": ["string", "null"]},
                    "reason":          {"type": "string"},
                },
                # BUG must name a culprit_file — enforced in submit.py too
                "if":   {"properties": {"classification": {"const": "BUG"}}},
                "then": {"required": ["culprit_file"],
                          "properties": {"culprit_file": {"type": "string"}}},
            },
        },
    },
}


def write_results_schema(run_dir: Path) -> None:
    (run_dir / "results.schema.json").write_text(
        json.dumps(RESULTS_SCHEMA, indent=2), encoding="utf-8",
    )


def write_run_yml(run_dir: Path, *, run_id: str, input_mode: str,
                  build_a: int, build_b: int, hash_a: str, hash_b: str,
                  routine_id: int, build_a_name: str, build_b_name: str,
                  classifier: str, total_failures: int, auto_classified: int,
                  flaky_excluded: int) -> None:
    metadata = {
        "run_id":              run_id,
        "input_mode":          input_mode,
        "classifier":          classifier,
        "build_id_a":          build_a,
        "build_id_b":          build_b,
        "git_hash_a":          hash_a,
        "git_hash_b":          hash_b,
        "routine_id":          routine_id,
        "build_a_name":        build_a_name,
        "build_b_name":        build_b_name,
        "total_failures":      total_failures,
        "auto_classified":     auto_classified,
        "flaky_excluded":      flaky_excluded,
        "prepared_at":         datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }
    (run_dir / "run.yml").write_text(
        yaml.safe_dump(metadata, sort_keys=False), encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Step 7: prompt.md
# ---------------------------------------------------------------------------

PROMPT_HEADER = """# Triage run `{run_id}`

Classify PASSED→FAILED/BLOCKED/UNTESTED test regressions between two builds.
The diff hunks relevant to each failure are already extracted; your job is to
judge whether each failure is caused by a hunk in the diff.

## Context

- **Baseline (A):** {build_a} — `{hash_a_short}` — {build_a_name}
- **Target   (B):** {build_b} — `{hash_b_short}` — {build_b_name}
- **Routine:** {routine_id}
- **Classifier:** `{classifier}`
- **Failures to classify:** {n_to_classify}  (+ {n_auto} auto-classified, + {n_flaky} known-flaky excluded)

## Files in this run

| File | What it is |
|---|---|
| `diff_list.csv` | One row per failure with component/team, error text, linked Jira, and `pre_classification` (non-null = already auto-classified, skip) |
| `hunks.txt` | Git diff filtered to files matching failing tests — your primary evidence |
| `git_diff_full.diff` | Full unfiltered diff — consult if `hunks.txt` looks too narrow |
| `results.schema.json` | JSON schema for the `results.json` you will write |

## Rubric

- **BUG** — a hunk in the diff plausibly caused this failure, OR a linked Jira confirms it, OR the component+error pattern clearly points at a code regression in this range. **MUST name a `culprit_file`**, even at low confidence. Downstream `pr_outcomes` training needs labeled culprits.
- **NEEDS_REVIEW** — evidence genuinely insufficient after real investigation. Not a default; use sparingly.
- **FALSE_POSITIVE** — not caused by code in this diff. Common patterns:
  - Chronic intermittent (>30% fail rate across recent runs in unrelated builds)
  - Environmental (DB, chrome version, CI infra, TEST_SETUP_ERROR)
  - Timeout/timing tolerance — almost never diff-caused
  - No relevant hunk + error unrelated to any changed module

Rows in `diff_list.csv` with `pre_classification` already set (BUILD_FAILURE, ENV_*, NO_ERROR) are auto-classified upstream and should **not** appear in `results.json`.

## How to classify, per row

1. Read `error_message` in `diff_list.csv`.
2. Scan `hunks.txt` for files whose path contains tokens from `component_name` or `test_case`.
3. If a hunk plausibly causes the error → **BUG**, name `culprit_file` = the specific file path from the diff.
4. If a hunk is thematically related but not clearly the cause → **NEEDS_REVIEW**.
5. If the error is a classic flake pattern (timeout, element-not-present, concurrent-thread assertion, setup error) and no hunk touches the relevant module → **FALSE_POSITIVE**.
6. When the filtered `hunks.txt` seems too narrow, consult `git_diff_full.diff`.

## Output

Write `results.json` in this directory, validating against `results.schema.json`:

```json
{{
  "run_id": "{run_id}",
  "classifier": "{classifier}",
  "results": [
    {{
      "testray_case_id": 12345,
      "classification": "BUG",
      "confidence": "high",
      "culprit_file": "modules/apps/.../Foo.java",
      "specific_change": "Foo.java:42 removed null check in bar()",
      "reason": "Diff removed the null check the test relies on — test asserts behavior when input is null."
    }}
  ]
}}
```

Then submit:

```
python3 apps/triage/submit.py runs/{run_dir_name}
```

Add `--no-upsert` to inspect the validated summary without writing to `fact_triage_results`.

---

## Failures to classify

"""


def write_prompt(run_dir: Path, *, run_id: str, classifier: str,
                 build_a: int, build_b: int, hash_a: str, hash_b: str,
                 routine_id: int, build_a_name: str, build_b_name: str,
                 df_to_classify: pd.DataFrame, df_auto: pd.DataFrame,
                 df_flaky: pd.DataFrame, hunks_path: Path) -> None:

    try:
        diff_blocks = prompt_helpers.parse_diff_blocks(hunks_path)
    except FileNotFoundError:
        diff_blocks = {}

    body_lines: list[str] = []
    for i, (_, row) in enumerate(df_to_classify.iterrows(), start=1):
        short = prompt_helpers.shorten_test_name(str(row.get("test_case") or ""))
        component = row.get("component_name") or "Unknown"
        team      = row.get("team_name") or ""
        case_id   = row.get("testray_case_id")

        header = f"### {i}. `{short}`"
        meta   = f"**case_id:** {case_id} · **component:** {component}"
        if team:
            meta += f" ({team})"
        meta += f" · **status_b:** {row.get('status_b', 'FAILED')}"
        body_lines.append(header)
        body_lines.append(meta)

        if row.get("linked_issues") and not pd.isna(row.get("linked_issues")):
            body_lines.append(f"**jira:** {row['linked_issues']}")

        err = str(row.get("error_message") or "")[:500].replace("\n", " ")
        body_lines.append(f"**error:** {err}")
        body_lines.append("")

        blocks = prompt_helpers.find_diff_blocks(
            test_case=str(row.get("test_case") or ""),
            component_name=row.get("component_name"),
            matched_diff_files=None,
            diff_blocks=diff_blocks,
        )
        if blocks:
            for fp, hunk in blocks:
                body_lines.append(f"```diff")
                body_lines.append(hunk)
                body_lines.append("```")
                body_lines.append("")
        else:
            body_lines.append(
                "_No diff hunk matched by path heuristics. Likely FALSE_POSITIVE "
                "unless error directly names a component that changed; scan "
                "`git_diff_full.diff` before deciding._"
            )
            body_lines.append("")

        body_lines.append("---")
        body_lines.append("")

    header = PROMPT_HEADER.format(
        run_id=run_id,
        classifier=classifier,
        build_a=build_a, build_b=build_b,
        hash_a_short=hash_a[:12] if hash_a else "?",
        hash_b_short=hash_b[:12] if hash_b else "?",
        routine_id=routine_id,
        build_a_name=build_a_name,
        build_b_name=build_b_name,
        n_to_classify=len(df_to_classify),
        n_auto=len(df_auto),
        n_flaky=len(df_flaky),
        run_dir_name=run_dir.name,
    )

    (run_dir / "prompt.md").write_text(header + "\n".join(body_lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Orchestrator — from-db mode
# ---------------------------------------------------------------------------

def _finalize_bundle(
    df: pd.DataFrame, run_id: str, run_dir: Path,
    classifier: str, input_mode: str,
    build_a: int, build_b: int, hash_a: str, hash_b: str,
    routine_id: int, build_a_name: str, build_b_name: str,
    git_repo: Path,
) -> Path:
    """Shared steps 3-6: git diff → hunks → enrich → prompt + schema + run.yml.
    `df` is the compute_test_diff output (pre-dedup)."""
    print(f"→ Step 3/6 git diff …")
    diff_path = run_dir / "git_diff_full.diff"
    diff_lines = run_git_diff(git_repo, hash_a, hash_b, diff_path)
    print(f"   {diff_lines} lines → {diff_path.relative_to(PROJECT_ROOT)}")

    print(f"→ Step 4/6 fragments + filtered hunks …")
    fragments = derive_test_fragments(df)
    fragments_path = run_dir / "test_fragments.txt"
    fragments_path.write_text("\n".join(sorted(fragments)), encoding="utf-8")
    hunks_path = run_dir / "hunks.txt"
    run_extract_hunks(diff_path, fragments_path, hunks_path)
    print(f"   {len(fragments)} fragments → {hunks_path.relative_to(PROJECT_ROOT)}")

    print(f"→ Step 5/6 enrich + pre-classify …")
    df = enrich_and_pre_classify(df)
    df = df.drop_duplicates(subset="testray_case_id", keep="first").reset_index(drop=True)
    df_flaky    = df[df["known_flaky"].fillna(False)].copy()
    df_nonflaky = df[~df["known_flaky"].fillna(False)].copy()
    df_auto     = df_nonflaky[df_nonflaky["pre_classification"].notna()].copy()
    df_to_cls   = df_nonflaky[df_nonflaky["pre_classification"].isna()].copy()
    print(f"   {len(df)} unique cases: "
          f"{len(df_to_cls)} to classify, {len(df_auto)} auto, "
          f"{len(df_flaky)} flaky (excluded)")

    diff_list_cols = [
        "testray_case_id", "test_case", "component_name", "team_name",
        "status_a", "status_b", "known_flaky", "linked_issues",
        "error_message", "pre_classification",
    ]
    df[diff_list_cols].to_csv(run_dir / "diff_list.csv", index=False)

    print(f"→ Step 6/6 prompt + schema + run.yml …")
    write_results_schema(run_dir)
    write_prompt(
        run_dir,
        run_id=run_id, classifier=classifier,
        build_a=build_a, build_b=build_b,
        hash_a=hash_a, hash_b=hash_b,
        routine_id=routine_id,
        build_a_name=build_a_name, build_b_name=build_b_name,
        df_to_classify=df_to_cls, df_auto=df_auto, df_flaky=df_flaky,
        hunks_path=hunks_path,
    )
    write_run_yml(
        run_dir,
        run_id=run_id, input_mode=input_mode, classifier=classifier,
        build_a=build_a, build_b=build_b,
        hash_a=hash_a, hash_b=hash_b,
        routine_id=routine_id,
        build_a_name=build_a_name, build_b_name=build_b_name,
        total_failures=len(df),
        auto_classified=len(df_auto),
        flaky_excluded=len(df_flaky),
    )

    rel = run_dir.relative_to(PROJECT_ROOT)
    print(f"\nRun bundle ready: {rel}")
    print(f"Next: open {rel}/prompt.md in your Claude Code session and classify.")
    print(f"Then: python3 apps/triage/submit.py {rel}")
    return run_dir


def prepare_from_db(build_a: int, build_b: int, classifier: str) -> Path:
    cfg      = load_config()
    testray  = cfg["databases"]["testray"]
    git_repo = Path(cfg["git"]["repo_path"]).expanduser()

    ts      = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id  = f"r_{ts}_{build_a}_{build_b}"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"→ Step 1/6 test_diff (DB × DB) …")
    baseline = fetch_build_caseresults(build_a, testray)
    target   = fetch_build_caseresults(build_b, testray)
    if baseline.empty or target.empty:
        raise SystemExit(f"No case results for build_a={build_a} or build_b={build_b}.")
    df = compute_test_diff(baseline, target)
    if df.empty:
        raise SystemExit("test_diff returned 0 rows.")
    print(f"   {len(df)} regressions — status_b: "
          f"{df['status_b'].value_counts().to_dict()}")

    print(f"→ Step 2/6 build metadata …")
    meta = resolve_build_metadata(build_a, build_b, testray)
    print(f"   routine_id={meta['routine_id']}  "
          f"A={meta['hash_a'][:12]}  B={meta['hash_b'][:12]}")

    return _finalize_bundle(
        df=df, run_id=run_id, run_dir=run_dir,
        classifier=classifier, input_mode="from-db",
        build_a=build_a, build_b=build_b,
        hash_a=meta["hash_a"], hash_b=meta["hash_b"],
        routine_id=meta["routine_id"],
        build_a_name=meta["build_a_name"], build_b_name=meta["build_b_name"],
        git_repo=git_repo,
    )


def prepare_from_api(
    baseline_build: int,
    target_build_id: int,
    target_hash: str | None,
    classifier: str,
    target_name: str | None = None,
) -> Path:
    """Baseline from DB, target fetched live from Testray REST.

    If target_hash is omitted, we try to resolve it from dim_build (in case
    the build is already ingested). Otherwise it's required.
    """
    cfg          = load_config()
    testray_db   = cfg["databases"]["testray"]
    testray_api  = cfg["testray"]
    git_repo     = Path(cfg["git"]["repo_path"]).expanduser()

    ts      = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id  = f"r_{ts}_{baseline_build}_{target_build_id}"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"→ Step 1/6 test_diff (DB × Testray API) …")
    baseline = fetch_build_caseresults(baseline_build, testray_db)
    if baseline.empty:
        raise SystemExit(f"No case results in DB for baseline build {baseline_build}.")
    print(f"   baseline rows: {len(baseline)}")
    print(f"   fetching target build {target_build_id} from Testray API …")
    target = fetch_build_caseresults_api(target_build_id, testray_api)
    if target.empty:
        raise SystemExit(f"Testray API returned 0 case results for build {target_build_id}.")
    print(f"   target rows:   {len(target)}")
    print(f"   NOTE: from-api does not populate `linked_issues` — the Jira",
          file=sys.stderr)
    print(f"         column in diff_list.csv will be blank for target-side failures.",
          file=sys.stderr)
    print(f"         Use from-db or from-csv if Jira ticket context is needed.",
          file=sys.stderr)

    df = compute_test_diff(baseline, target)
    if df.empty:
        raise SystemExit("test_diff returned 0 rows (no PASSED→FAILED after matching).")
    print(f"   {len(df)} regressions — status_b: "
          f"{df['status_b'].value_counts().to_dict()}")

    print(f"→ Step 2/6 build metadata …")
    ra = fetch_build_metadata(baseline_build, testray_db)
    if ra is None:
        raise SystemExit(f"Baseline build {baseline_build} not in dim_build.")
    rb = fetch_build_metadata(target_build_id, testray_db)
    resolved_hash = target_hash or (rb or {}).get("git_hash")
    if not resolved_hash:
        raise SystemExit(
            f"Target build {target_build_id} is not in dim_build and no "
            f"--target-hash was supplied. Pass --target-hash <sha>."
        )
    target_final = {
        "build_name": (rb or {}).get("build_name") or target_name or f"api:{target_build_id}",
        "git_hash":   resolved_hash,
        "routine_id": (rb or {}).get("routine_id") or ra["routine_id"],
    }
    if rb and target_hash and rb["git_hash"] != target_hash:
        print(f"WARNING: --target-hash={target_hash[:12]} differs from dim_build "
              f"git_hash={rb['git_hash'][:12]}. Using --target-hash.",
              file=sys.stderr)
    print(f"   routine_id={target_final['routine_id']}  "
          f"A={ra['git_hash'][:12]}  B={target_final['git_hash'][:12]}")

    return _finalize_bundle(
        df=df, run_id=run_id, run_dir=run_dir,
        classifier=classifier, input_mode="from-api",
        build_a=baseline_build, build_b=target_build_id,
        hash_a=ra["git_hash"], hash_b=target_final["git_hash"],
        routine_id=target_final["routine_id"],
        build_a_name=ra["build_name"],
        build_b_name=target_final["build_name"],
        git_repo=git_repo,
    )


def prepare_from_csv(
    baseline_build: int,
    target_csv: Path,
    target_build_id: int,
    target_hash: str,
    classifier: str,
    target_name: str | None = None,
) -> Path:
    """Baseline from DB, target from a Testray CSV export.

    Dev supplies target_build_id + target_hash because the CSV doesn't carry
    them. If the target build happens to also be in dim_build, metadata fills
    in automatically; otherwise the dev's values are authoritative.
    """
    cfg      = load_config()
    testray  = cfg["databases"]["testray"]
    git_repo = Path(cfg["git"]["repo_path"]).expanduser()

    target_csv = target_csv.expanduser().resolve()
    if not target_csv.exists():
        raise SystemExit(f"Target CSV not found: {target_csv}")

    ts      = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id  = f"r_{ts}_{baseline_build}_{target_build_id}"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"→ Step 1/6 test_diff (DB × CSV) …")
    baseline = fetch_build_caseresults(baseline_build, testray)
    if baseline.empty:
        raise SystemExit(f"No case results in DB for baseline build {baseline_build}.")
    target = parse_testray_csv(target_csv)
    if target.empty:
        raise SystemExit(f"Target CSV is empty: {target_csv}")

    # Sanity diagnostic: how many target rows will actually match the baseline?
    matched = target.merge(
        baseline[["case_name", "component_name"]],
        on=["case_name", "component_name"], how="inner",
    )
    print(f"   baseline rows: {len(baseline)}")
    print(f"   target rows:   {len(target)}  (matched to baseline: {len(matched)})")
    unmatched = len(target) - len(matched)
    if unmatched > 0:
        print(f"   unmatched:     {unmatched} (target-only — no case_id, cannot persist)")

    df = compute_test_diff(baseline, target)
    if df.empty:
        raise SystemExit("test_diff returned 0 rows (no PASSED→FAILED after matching).")
    print(f"   {len(df)} regressions — status_b: "
          f"{df['status_b'].value_counts().to_dict()}")

    print(f"→ Step 2/6 build metadata …")
    ra = fetch_build_metadata(baseline_build, testray)
    if ra is None:
        raise SystemExit(f"Baseline build {baseline_build} not in dim_build.")
    # Target: try DB first, fall back to dev-supplied values.
    rb = fetch_build_metadata(target_build_id, testray)
    target_final = {
        "build_id":   target_build_id,
        "build_name": (rb or {}).get("build_name") or target_name or f"csv:{target_csv.name}",
        "git_hash":   (rb or {}).get("git_hash")   or target_hash,
        "routine_id": (rb or {}).get("routine_id") or ra["routine_id"],
    }
    if rb and rb["git_hash"] and rb["git_hash"] != target_hash:
        print(f"WARNING: --target-hash={target_hash[:12]} differs from dim_build "
              f"git_hash={rb['git_hash'][:12]}. Using --target-hash.",
              file=sys.stderr)
        target_final["git_hash"] = target_hash
    print(f"   routine_id={target_final['routine_id']}  "
          f"A={ra['git_hash'][:12]}  B={target_final['git_hash'][:12]}")

    return _finalize_bundle(
        df=df, run_id=run_id, run_dir=run_dir,
        classifier=classifier, input_mode="from-csv",
        build_a=baseline_build, build_b=target_build_id,
        hash_a=ra["git_hash"], hash_b=target_final["git_hash"],
        routine_id=target_final["routine_id"],
        build_a_name=ra["build_name"],
        build_b_name=target_final["build_name"],
        git_repo=git_repo,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Prepare a triage run bundle for in-session classification.",
    )
    sub = ap.add_subparsers(dest="mode", required=True)

    db = sub.add_parser("from-db",
        help="Both builds from testray_analytical.")
    db.add_argument("--build-a", type=int, required=True, help="Baseline build id")
    db.add_argument("--build-b", type=int, required=True, help="Target build id")
    db.add_argument("--classifier", default=DEFAULT_CLASSIFIER,
                    help=f"Provenance label (default: {DEFAULT_CLASSIFIER})")

    cv = sub.add_parser("from-csv",
        help="Baseline from testray_analytical, target from a Testray CSV export.")
    cv.add_argument("--baseline-build",  type=int, required=True,
                    help="Baseline build id (must be in testray_analytical)")
    cv.add_argument("--target-csv",      type=Path, required=True,
                    help="Path to Testray CSV export for the target build")
    cv.add_argument("--target-build-id", type=int, required=True,
                    help="Build id for the target (written to fact_triage_results)")
    cv.add_argument("--target-hash",     required=True,
                    help="Git hash for the target build")
    cv.add_argument("--target-name",     default=None,
                    help="Optional display name for the target build")
    cv.add_argument("--classifier",      default=DEFAULT_CLASSIFIER,
                    help=f"Provenance label (default: {DEFAULT_CLASSIFIER})")

    ap_api = sub.add_parser("from-api",
        help="Baseline from testray_analytical, target fetched live from Testray REST "
             "(OAuth2 client_credentials — needs testray.client_id/client_secret in config.yml).")
    ap_api.add_argument("--baseline-build",  type=int, required=True,
                        help="Baseline build id (must be in testray_analytical)")
    ap_api.add_argument("--target-build-id", type=int, required=True,
                        help="Target build id (fetched from Testray API)")
    ap_api.add_argument("--target-hash",     default=None,
                        help="Git hash for target. Optional if target is also "
                             "in dim_build; required otherwise.")
    ap_api.add_argument("--target-name",     default=None,
                        help="Optional display name for the target build")
    ap_api.add_argument("--classifier",      default=DEFAULT_CLASSIFIER,
                        help=f"Provenance label (default: {DEFAULT_CLASSIFIER})")

    args = ap.parse_args()
    if args.mode == "from-db":
        prepare_from_db(args.build_a, args.build_b, args.classifier)
    elif args.mode == "from-csv":
        prepare_from_csv(
            baseline_build=args.baseline_build,
            target_csv=args.target_csv,
            target_build_id=args.target_build_id,
            target_hash=args.target_hash,
            classifier=args.classifier,
            target_name=args.target_name,
        )
    elif args.mode == "from-api":
        prepare_from_api(
            baseline_build=args.baseline_build,
            target_build_id=args.target_build_id,
            target_hash=args.target_hash,
            classifier=args.classifier,
            target_name=args.target_name,
        )
    else:
        raise SystemExit(f"Unknown mode: {args.mode}")


if __name__ == "__main__":
    main()
