"""
apps/triage/prepare.py

Build a triage run bundle for the dev's own Claude Code session to classify.

Usage:
    python3 -m apps.triage.prepare \
        --baseline-source {db,csv,api,tar} --baseline-build-id <N> \
            [--baseline-csv <path>] [--baseline-tar <path>] \
            [--baseline-hash <sha>] [--baseline-name <str>] \
        --target-source   {db,csv,api,tar} --target-build-id <N> \
            [--target-csv <path>] [--target-tar <path>] \
            [--target-hash <sha>] [--target-name <str>] \
        [--classifier <label>]

tar source: Testray JUnit XML tar.gz (the format Jenkins ships to GCP / Testray
before DB ingest). Behaves like csv — joins on (case_name, component_name);
--{side}-build-id is optional (auto-extracted from testray.build.name in the
XML); --{side}-hash is required.  tar × api is not supported (no shared key).

Emits apps/triage/runs/r_<ts>_<A>_<B>/:
    run.yml              metadata (build ids, hashes, routine, sources)
    diff_list.csv        one row per PASSED→FAILED/BLOCKED/UNTESTED case,
                         enriched with component/team + pre_classification
    hunks.txt            filtered git diff (hunks matching failing tests)
    git_diff_full.diff   full unfiltered diff (for fallback inspection)
    test_fragments.txt   fragments fed to extract_relevant_hunks.py
    prompt.md            instructions for the dev's Claude Code session
    results.schema.json  JSON schema validating results.json

The dev's Claude Code session reads prompt.md, classifies, writes
results.json. Then `submit.py <run_dir>` validates and upserts.
"""

import argparse
import json
import re
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
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

SOURCE_DB  = "db"
SOURCE_CSV = "csv"
SOURCE_API = "api"
SOURCE_TAR = "tar"
SOURCES    = (SOURCE_DB, SOURCE_CSV, SOURCE_API, SOURCE_TAR)

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
# Side specification
# ---------------------------------------------------------------------------

@dataclass
class SideSpec:
    """One side of the triage pair (baseline or target)."""
    role:     str            # "baseline" or "target"
    source:   str            # SOURCE_DB | SOURCE_CSV | SOURCE_API | SOURCE_TAR
    build_id: int
    csv:      Path | None = None
    tar:      Path | None = None
    hash:     str  | None = None
    name:     str  | None = None

    @property
    def flag_prefix(self) -> str:
        return f"--{self.role}"


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
# Step 1: test_diff — per-source fetchers, one output shape
# ---------------------------------------------------------------------------
#
# Downstream (git diff → hunks → prompt) needs a DataFrame with:
#
#   case_id, case_name, case_flaky, component_name, team_name,
#   status, errors, jira_issue
#
# Three sources, each lossy in different dimensions:
#
#   source  case_id   case_name   component_name   linked_issues
#   ------  -------   ---------   --------------   -------------
#   db        ✓          ✓             ✓                ✓
#   csv       ✗          ✓             ✓                ✓
#   api       ✓          ✗             ✗                ✗ (backlog)
#
# Combos that share at least one of {case_id, (case_name, component_name)}
# work; csv×api does not (see validate_combo).
# ---------------------------------------------------------------------------

# Worst-status-wins order for de-duping retry rows.
_STATUS_RANK = {"FAILED": 4, "BLOCKED": 3, "UNTESTED": 2, "PASSED": 1}


def fetch_build_caseresults(build_id: int, db_cfg: dict) -> pd.DataFrame:
    """All case results for a single build from testray_analytical — raw rows
    (one per run × case). Aggregation happens in compute_test_diff."""
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
            "Both are required for api sources."
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
    """Follow Liferay Objects pagination until lastPage."""
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


def fetch_case_metadata(case_ids: list[int], cfg: dict) -> dict[int, dict]:
    """Fetch per-case metadata (name + flaky flag) from Testray's case object.
    Returns {case_id: {"name": str, "flaky": bool}}; case_ids that 404 are
    omitted. Used by enrich_api_case_names() to backfill test_case columns
    that api caseresults don't populate.

    One GET /o/c/cases/{id} per case_id; expected ≤ ~100 case_ids per run
    after diff dedup, so per-id calls are acceptable. Batch via
    `filter=id in (...)` if this becomes a hot path."""
    if not case_ids:
        return {}
    token = _testray_oauth_token(cfg)
    base = cfg["base_url"].rstrip("/")
    out: dict[int, dict] = {}
    for cid in case_ids:
        url = f"{base}/o/c/cases/{cid}"
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise SystemExit("Testray API 401 — token expired. Re-run.")
            if e.code == 404:
                continue
            raise
        out[int(cid)] = {
            "name":  body.get("name") or "",
            "flaky": str(body.get("flaky")).lower() == "true",
        }
        time.sleep(0.05)
    return out


def enrich_api_case_names(df: pd.DataFrame, cfg: dict) -> pd.DataFrame:
    """When an api source contributed rows lacking `test_case` (api
    caseresults don't carry case names), fetch names from the Testray case
    object and backfill. Idempotent — does nothing if every row already has
    a name. Also backfills `known_flaky` from the case-level flaky flag."""
    if df.empty:
        return df
    name_col = "test_case"
    if name_col not in df.columns:
        return df
    needs_mask = df[name_col].isna() | (df[name_col].astype(str).str.strip() == "")
    if not needs_mask.any():
        return df
    case_ids = sorted({
        int(x) for x in df.loc[needs_mask, "testray_case_id"].dropna()
    })
    if not case_ids:
        return df

    print(f"   enriching {len(case_ids)} case name(s) from Testray REST …")
    metadata = fetch_case_metadata(case_ids, cfg)
    if not metadata:
        print(f"   no cases returned — leaving rows unenriched", file=sys.stderr)
        return df

    df = df.copy()
    name_filled = 0
    flaky_marked = 0
    for cid, meta in metadata.items():
        row_mask = df["testray_case_id"] == cid
        if meta.get("name"):
            current = df.loc[row_mask, name_col]
            blank = current.isna() | (current.astype(str).str.strip() == "")
            df.loc[row_mask & blank, name_col] = meta["name"]
            name_filled += int(blank.sum())
        if meta.get("flaky"):
            df.loc[row_mask, "known_flaky"] = True
            flaky_marked += int(row_mask.sum())
    print(f"   filled {name_filled} test_case value(s); marked {flaky_marked} as known_flaky")
    return df


def fetch_build_caseresults_api(build_id: int, cfg: dict) -> pd.DataFrame:
    """Fetch all case results for a build via Testray REST. Same column shape
    as fetch_build_caseresults / parse_testray_csv; `case_name`,
    `component_name`, `team_name`, `jira_issue` are left blank.
    `case_name` is backfilled post-diff via `enrich_api_case_names()` so the
    fragment-based hunk matcher has something to anchor on. Component, team,
    and jira remain blank (separate per-case lookups — backlog)."""
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
    """Parse a Testray CSV export into the common shape. `case_id` is blank —
    filled later by joining to a side that has names and case_ids."""
    raw = pd.read_csv(path)
    required = {"Case Name", "Component", "Status"}
    missing = required - set(raw.columns)
    if missing:
        raise SystemExit(f"Testray CSV at {path} is missing columns: {missing}")

    return pd.DataFrame({
        "case_id":        [None] * len(raw),
        "case_name":      raw["Case Name"].astype(str),
        "case_flaky":     [None] * len(raw),
        "component_name": raw["Component"].astype(str),
        "team_name":      raw.get("Team",    pd.Series([None] * len(raw))),
        "status":         raw["Status"].astype(str),
        "errors":         raw.get("Errors",  pd.Series([None] * len(raw))),
        "jira_issue":     raw.get("Issues",  pd.Series([None] * len(raw))),
    })


_TAR_STATUS_MAP = {
    "FAILED":      "FAILED",
    "PASSED":      "PASSED",
    "BLOCKED":     "BLOCKED",
    "UNTESTED":    "UNTESTED",
    "IN PROGRESS": "UNTESTED",
    "DID NOT RUN": "UNTESTED",
}


def _extract_build_meta_from_tar(path: Path) -> dict:
    """Read build-level properties from the first TESTS-*.xml in the archive.
    Returns {'build_name': str|None, 'build_id': int|None}.
    build_id is extracted from testray.build.name via ' - <N> - ' pattern."""
    with tarfile.open(path, "r:gz") as tf:
        for member in tf.getmembers():
            basename = member.name.split("/")[-1]
            if not (member.name.endswith(".xml") and basename.startswith("TESTS-")):
                continue
            f = tf.extractfile(member)
            if f is None:
                continue
            try:
                root = ET.parse(f).getroot()
            except ET.ParseError:
                continue
            props = {
                p.get("name"): p.get("value")
                for p in root.findall(".//properties/property")
                if p.get("name") and p.get("value")
            }
            build_name = props.get("testray.build.name")
            build_id = None
            if build_name:
                m = re.search(r" - (\d+) - ", build_name)
                if m:
                    build_id = int(m.group(1))
            return {"build_name": build_name, "build_id": build_id}
    return {"build_name": None, "build_id": None}


def parse_testray_tar(path: Path) -> pd.DataFrame:
    """Parse a Testray JUnit XML tar.gz into the common case-result shape.

    Same output columns as parse_testray_csv; case_id and jira_issue are blank
    (not present in the pre-ingest XML format). Status values are normalized to
    uppercase. Joins to a db/csv baseline on (case_name, component_name)."""
    rows = []
    with tarfile.open(path, "r:gz") as tf:
        for member in tf.getmembers():
            basename = member.name.split("/")[-1]
            if not (member.name.endswith(".xml") and basename.startswith("TESTS-")):
                continue
            f = tf.extractfile(member)
            if f is None:
                continue
            try:
                root = ET.parse(f).getroot()
            except ET.ParseError:
                print(f"WARNING: could not parse {member.name} — skipping",
                      file=sys.stderr)
                continue
            for tc in root.findall("testcase"):
                tc_props = {
                    p.get("name"): p.get("value")
                    for p in tc.findall("properties/property")
                    if p.get("name")
                }
                status_raw = (tc_props.get("testray.testcase.status") or "").upper()
                failure_el = tc.find("failure")
                rows.append({
                    "case_id":        None,
                    "case_name":      tc_props.get("testray.testcase.name"),
                    "case_flaky":     None,
                    "component_name": tc_props.get("testray.main.component.name"),
                    "team_name":      tc_props.get("testray.team.name"),
                    "status":         _TAR_STATUS_MAP.get(status_raw, status_raw) or None,
                    "errors":         failure_el.get("message") if failure_el is not None else None,
                    "jira_issue":     None,
                })

    if not rows:
        raise SystemExit(
            f"No test cases found in {path}. "
            "Verify the archive contains TESTS-*.xml files."
        )
    return pd.DataFrame(rows)


def fetch_caseresults(spec: SideSpec, cfg: dict) -> pd.DataFrame:
    """Dispatch a SideSpec to the matching fetcher."""
    if spec.source == SOURCE_DB:
        return fetch_build_caseresults(spec.build_id, cfg["databases"]["testray"])
    if spec.source == SOURCE_CSV:
        assert spec.csv is not None
        return parse_testray_csv(spec.csv)
    if spec.source == SOURCE_API:
        return fetch_build_caseresults_api(spec.build_id, cfg["testray"])
    if spec.source == SOURCE_TAR:
        assert spec.tar is not None
        return parse_testray_tar(spec.tar)
    raise SystemExit(f"Unknown source: {spec.source}")


def _aggregate_baseline(df: pd.DataFrame, key_cols: list[str]) -> pd.DataFrame:
    """Per key, status='PASSED' if any retry passed; else worst status wins.
    Matches test_diff.sql semantics — any passing run counts as passing in A."""
    if df.empty:
        return df
    df = df.copy()
    df["_is_pass"] = (df["status"] == "PASSED").astype(int)
    df["_rank"]    = df["status"].map(_STATUS_RANK).fillna(0).astype(int)
    df = df.sort_values(["_is_pass", "_rank"], ascending=[False, False])
    out = df.drop_duplicates(subset=key_cols, keep="first") \
            .drop(columns=["_is_pass", "_rank"]) \
            .reset_index(drop=True)
    return out


def _aggregate_target(df: pd.DataFrame, key_cols: list[str]) -> pd.DataFrame:
    """Per key, keep the worst-status row — any failed retry should surface."""
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
    """Inner-join baseline and target; keep cases that PASSED in A and
    FAILED/BLOCKED/UNTESTED in B.

    Join key: `case_id` if the target has one (db, api targets); otherwise
    `(case_name, component_name)` (csv targets). A final dropna on
    `testray_case_id` discards rows with no persistable id."""
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

    case_id_col = "case_id"          if target_has_ids     else "case_id_a"
    name_col    = "case_name_a"      if target_has_ids     else "case_name"
    comp_col    = "component_name_a" if target_has_ids     else "component_name"
    flaky_col   = "case_flaky_a"

    out = pd.DataFrame({
        "testray_case_id":        diff[case_id_col],
        "test_case":              diff[name_col],
        "known_flaky":            diff[flaky_col].fillna(False).astype(bool),
        "testray_component_name": diff[comp_col],
        "status_a":               diff["status_a"],
        "status_b":               diff["status_b"],
        "error_message":          diff["errors_b"],
        "linked_issues":          diff["jira_issue_b"],
    })
    out = out.dropna(subset=["testray_case_id"]).reset_index(drop=True)
    return out


# ---------------------------------------------------------------------------
# Step 2: metadata — dim_build lookup per side, fall back to spec args
# ---------------------------------------------------------------------------

def fetch_build_metadata(build_id: int, db_cfg: dict) -> dict | None:
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


def resolve_side_metadata(spec: SideSpec, testray_db: dict) -> dict:
    """Resolve git_hash / routine_id / build_name for one side.

    Strategy (per side):
      - Try dim_build lookup.
      - If source=db: row MUST be found.
      - Else: merge dim_build values (if any) with spec-supplied values
        (hash, name). Spec wins for hash/name if both are present (with a
        warning); dim_build's routine_id is used if present.
      - If git_hash still unresolved, error with guidance to pass the
        appropriate --{role}-hash flag.
    """
    row = fetch_build_metadata(spec.build_id, testray_db)

    if spec.source == SOURCE_DB:
        if row is None:
            raise SystemExit(
                f"Build {spec.build_id} not found in dim_build "
                f"(source={SOURCE_DB}). Re-run the testray load, "
                f"or switch {spec.flag_prefix}-source to csv/api."
            )
        return {
            "build_name": row["build_name"],
            "git_hash":   row["git_hash"],
            "routine_id": row["routine_id"],
        }

    # csv / api
    git_hash = spec.hash or (row or {}).get("git_hash")
    if row and spec.hash and row["git_hash"] != spec.hash:
        print(f"WARNING: {spec.flag_prefix}-hash={spec.hash[:12]} differs from "
              f"dim_build git_hash={row['git_hash'][:12]}. Using "
              f"{spec.flag_prefix}-hash.", file=sys.stderr)

    if not git_hash:
        raise SystemExit(
            f"Build {spec.build_id} is not in dim_build and no "
            f"{spec.flag_prefix}-hash was supplied. Pass "
            f"{spec.flag_prefix}-hash <sha>."
        )

    fallback_name = (
        spec.name
        or (row or {}).get("build_name")
        or (f"{spec.source}:{spec.csv.name}" if spec.source == SOURCE_CSV
            else f"{spec.source}:{spec.tar.name}" if spec.source == SOURCE_TAR
            else f"{spec.source}:{spec.build_id}")
    )
    return {
        "build_name": fallback_name,
        "git_hash":   git_hash,
        "routine_id": (row or {}).get("routine_id"),
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
    """Module/class tokens from test_case names — fed to
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


def write_run_yml(run_dir: Path, *, run_id: str,
                  baseline_source: str, target_source: str,
                  build_a: int, build_b: int, hash_a: str, hash_b: str,
                  routine_id: int | None, build_a_name: str, build_b_name: str,
                  classifier: str, total_failures: int, auto_classified: int,
                  flaky_excluded: int) -> None:
    metadata = {
        "run_id":              run_id,
        "baseline_source":     baseline_source,
        "target_source":       target_source,
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

**Confidence is structural, not metadata.** Your `confidence` field gates which classification you may use:

- **BUG** — only when confidence is **`high`** AND a hunk in the diff (direct or via imports/lifecycle) clearly caused the failure. **MUST name a `culprit_file`.** A plausible-sounding theory at `medium` confidence is NOT a BUG — it is NEEDS_REVIEW. A linked Jira ticket confirming the regression also qualifies.
- **NEEDS_REVIEW** — the safe default for any of:
  - Confidence is `medium` or `low` and you have a candidate theory you cannot fully verify from this prompt
  - The failing test plausibly imports, extends, or depends on code in another changed module that has no hunk matching the test's name
  - **Two or more ticket clusters (LPD/LPP/LPS-XXXXX) in this diff plausibly affect the failing test's space** — list all candidates separated by `; ` in `specific_change`. Do not pick the most plausible one; the human reviewer disambiguates.
  - The error message is generic enough (e.g. "compileTestIntegrationJava failed", "BUILD FAILED", aggregate batch status) that multiple changes in this range could explain it
  - You'd want a human to confirm before calling it
- **FALSE_POSITIVE** — clearly environmental or genuinely unrelated. May be `high` confidence (timeouts, gradle build infrastructure, chrome version, TEST_SETUP_ERROR are confidently environmental). Common patterns:
  - Environmental (DB, chrome version, CI infra, TEST_SETUP_ERROR, gradle build infrastructure)
  - Timeout/timing tolerance — almost never diff-caused
  - Chronic intermittent (>30% fail rate across recent runs in unrelated builds)
  - No relevant hunk + error unrelated to any changed module **AND** no plausible import / lifecycle / framework dependency

### Transitive dependencies — do not dismiss without verification

Per-failure hunks are matched by path tokens, but **a test class can fail because a file it _imports_ changed, even if the test's own file has no hunk in the diff**. You cannot read source files from this prompt — when:

- the failing test's class name plausibly imports, extends, or depends on code in another changed module,
- multiple commits in this range cluster under the same ticket (e.g. LPD-XXXXX) and touch related infrastructure,
- a smoke test or site-initializer test fails and shared lifecycle / layout / importer code changed,

…**default to NEEDS_REVIEW**, not FALSE_POSITIVE. Note the suspected file in `specific_change` so the human reviewer can verify the import. Do not invent reasons to dismiss — explicit dismissal of a plausible cluster ("the test's name doesn't match the changed file's name") is exactly the failure mode this rule is here to prevent.

### Multiple candidate causes — list, don't pick

If two or more ticket clusters in the diff plausibly affect the failing test's module (e.g. one cluster rewrote the persistence layer the test depends on, a second cluster restructured the test framework or build tooling), **classify NEEDS_REVIEW even at high confidence and list ALL candidates** in `specific_change`, separated by `; `. Locking in a single theory hides the alternatives from the human reviewer; enumerating them lets the reviewer pick. Generic error messages (build failed, compile error, batch failed) are a strong signal that multiple changes could explain the failure.

Rows in `diff_list.csv` with `pre_classification` already set (BUILD_FAILURE, ENV_*, NO_ERROR) are auto-classified upstream and should **not** appear in `results.json`.

## How to classify, per row

1. Read `error_message` in `diff_list.csv`.
2. Scan `hunks.txt` for files whose path contains tokens from `component_name` or `test_case`.
3. If a hunk plausibly causes the error → **BUG**, name `culprit_file` = the specific file path from the diff.
4. If a hunk is thematically related but not clearly the cause → **NEEDS_REVIEW**.
5. If no per-failure hunk matches, **check the changed-files manifest and commit cluster sections below** for transitive candidates (test class name → likely importee in a changed module). Note the candidate in `specific_change` and classify NEEDS_REVIEW.
6. If the error is a classic flake pattern (timeout, element-not-present, concurrent-thread assertion, setup error) AND no hunk touches the relevant module AND no transitive candidate exists → **FALSE_POSITIVE**.
7. When the filtered `hunks.txt` seems too narrow, consult `git_diff_full.diff`.

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

"""

_FAILURES_HEADER = "\n---\n\n## Failures to classify\n\n"

_DIFF_HDR_RE = re.compile(r"^diff --git a/(.+?) b/(.+)$")
_LPD_RE      = re.compile(r"\b((?:LPD|LPP|LPS)-\d+)\b")


def _module_key(path: str) -> str:
    """Group key for the file manifest. modules/<group>/<module>/... → that
    module folder; other paths fall back to the top two segments."""
    parts = path.split("/")
    if len(parts) >= 3 and parts[0] == "modules" and parts[1] in ("apps", "dxp", "test"):
        return "/".join(parts[:3]) + "/"
    if len(parts) >= 2:
        return "/".join(parts[:2]) + "/"
    return parts[0]


def parse_full_diff_manifest(diff_path: Path) -> dict[str, int]:
    """Walk git_diff_full.diff once and return {file_path: lines_changed}.
    Counts +/- lines (mirrors `git diff --stat`)."""
    files: dict[str, int] = {}
    current: str | None = None
    count = 0
    if not diff_path.exists():
        return files
    for line in diff_path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _DIFF_HDR_RE.match(line)
        if m:
            if current is not None:
                files[current] = count
            current = m.group(2)
            count = 0
            continue
        if line.startswith(("+", "-")) and not line.startswith(("+++", "---")):
            count += 1
    if current is not None:
        files[current] = count
    return files


def fetch_commits_in_range(git_repo: Path, hash_a: str, hash_b: str) -> list[tuple[str, str]]:
    """Run `git log A..B --pretty=format:'%h\\t%s'` in the liferay-portal
    repo. Returns [(short_hash, subject), ...] in newest-first order."""
    if not (git_repo / ".git").is_dir():
        return []
    try:
        out = subprocess.run(
            ["git", "-C", str(git_repo), "log",
             "--pretty=format:%h\t%s", f"{hash_a}..{hash_b}"],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
    except (subprocess.SubprocessError, FileNotFoundError):
        return []
    commits = []
    for line in out.splitlines():
        if "\t" in line:
            h, subj = line.split("\t", 1)
            commits.append((h, subj))
    return commits


def render_changed_files_section(manifest: dict[str, int]) -> list[str]:
    """Markdown block listing every changed file by module folder, sorted
    by total lines descending. Gives the model a manifest for transitive-dep
    inference when per-failure hunk matching is empty."""
    if not manifest:
        return []
    by_module: dict[str, list[tuple[str, int]]] = {}
    for path, lc in manifest.items():
        by_module.setdefault(_module_key(path), []).append((path, lc))
    total_files = len(manifest)
    total_lines = sum(manifest.values())

    lines = [
        "## All changed files in this diff",
        "",
        f"_{total_files} files, {total_lines} +/- lines, grouped by module. "
        f"Use this as a manifest of what changed across the diff. If a "
        f"failing test plausibly imports or extends a file shown here that "
        f"is **not** in its per-failure hunks above, treat it as a candidate "
        f"culprit and classify NEEDS_REVIEW (not FALSE_POSITIVE) — note the "
        f"candidate path in `specific_change`._",
        "",
    ]
    for mod in sorted(by_module, key=lambda m: -sum(lc for _, lc in by_module[m])):
        files = sorted(by_module[mod], key=lambda x: -x[1])
        mod_total = sum(lc for _, lc in files)
        lines.append(f"### {mod} ({mod_total} lines, {len(files)} file(s))")
        for path, lc in files:
            lines.append(f"- `{path}` ({lc})")
        lines.append("")
    lines.append("---")
    lines.append("")
    return lines


def render_commits_section(commits: list[tuple[str, str]]) -> list[str]:
    """Markdown block listing commits in this range, clustered by ticket
    (LPD-XXXXX / LPP-XXXXX / LPS-XXXXX) when present. Multi-commit clusters
    under one ticket often represent a single refactor — explicit candidate
    root causes for transitive-dep failures."""
    if not commits:
        return []
    by_ticket: dict[str, list[tuple[str, str]]] = {}
    for h, subj in commits:
        m = _LPD_RE.search(subj)
        key = m.group(1) if m else "(no ticket)"
        by_ticket.setdefault(key, []).append((h, subj))

    lines = [
        "## Commits in this range",
        "",
        f"_{len(commits)} commits between baseline and target. Multi-commit "
        f"clusters under the same ticket often represent a single refactor — "
        f"if a ticket touches a file related to a failing test (even via "
        f"imports), treat the cluster as a candidate root cause._",
        "",
    ]
    # Clusters with most commits first; "(no ticket)" last.
    def sort_key(t: str) -> tuple[int, int, str]:
        return (1 if t == "(no ticket)" else 0, -len(by_ticket[t]), t)
    for ticket in sorted(by_ticket, key=sort_key):
        cs = by_ticket[ticket]
        if len(cs) > 1:
            lines.append(f"### {ticket} ({len(cs)} commits)")
        else:
            lines.append(f"### {ticket}")
        for h, subj in cs:
            lines.append(f"- `{h}` {subj}")
        lines.append("")
    lines.append("---")
    lines.append("")
    return lines


def write_prompt(run_dir: Path, *, run_id: str, classifier: str,
                 build_a: int, build_b: int, hash_a: str, hash_b: str,
                 routine_id: int | None, build_a_name: str, build_b_name: str,
                 df_to_classify: pd.DataFrame, df_auto: pd.DataFrame,
                 df_flaky: pd.DataFrame, hunks_path: Path,
                 full_diff_path: Path, git_repo: Path) -> None:

    try:
        diff_blocks = prompt_helpers.parse_diff_blocks(hunks_path)
    except FileNotFoundError:
        diff_blocks = {}

    chrome_changes = prompt_helpers.find_ui_chrome_changes(diff_blocks)

    chrome_lines: list[str] = []
    if chrome_changes:
        chrome_lines.append("## UI chrome changes")
        chrome_lines.append("")
        chrome_lines.append(
            "Files changed in shared layout / navigation / taglib / theme "
            "paths — these can break UI tests in *other* components (the "
            "failing test's component won't show a matching hunk). Cross-"
            "reference against per-failure sections below when the error "
            "is UI-shaped (strict mode violation, element-not-found, "
            "visibility timeout, getByText not found)."
        )
        chrome_lines.append("")
        chrome_lines.append(f"_{len(chrome_changes)} shared-UI files changed. "
                            f"Sorted by change size, smallest last._")
        chrome_lines.append("")
        chrome_lines.append("| Changed lines | File |")
        chrome_lines.append("|---:|---|")
        for path, n in chrome_changes:
            chrome_lines.append(f"| {n} | `{path}` |")
        chrome_lines.append("")
        chrome_lines.append("---")
        chrome_lines.append("")

    has_chrome = bool(chrome_changes)
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
            if has_chrome:
                body_lines.append(
                    "_No direct hunk match by path. If the error is UI-shaped "
                    "(strict mode violation, element-not-found, visibility "
                    "timeout), cross-check the **UI chrome changes** section "
                    "at the top — a shared layout or navigation file may be "
                    "the real culprit even though it's in a different "
                    "component. Consult `git_diff_full.diff` to confirm._"
                )
            else:
                body_lines.append(
                    "_No diff hunk matched by path heuristics. Before "
                    "concluding FALSE_POSITIVE, scan the **All changed files** "
                    "and **Commits in this range** sections below for "
                    "transitive candidates — this test class may import or "
                    "extend code in a different changed module. If you find "
                    "a plausible candidate you cannot fully verify from "
                    "this prompt alone, classify NEEDS_REVIEW with the "
                    "suspected file in `specific_change`._"
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
        routine_id=routine_id if routine_id is not None else "unknown",
        build_a_name=build_a_name,
        build_b_name=build_b_name,
        n_to_classify=len(df_to_classify),
        n_auto=len(df_auto),
        n_flaky=len(df_flaky),
        run_dir_name=run_dir.name,
    )

    # Manifest + commits sections — give the model context for transitive
    # deps when per-failure hunk matching is empty.
    manifest = parse_full_diff_manifest(full_diff_path)
    commits  = fetch_commits_in_range(git_repo, hash_a, hash_b) if hash_a and hash_b else []
    manifest_lines = render_changed_files_section(manifest)
    commit_lines   = render_commits_section(commits)

    parts = [header]
    if chrome_lines:
        parts.append("\n".join(chrome_lines))
    if manifest_lines:
        parts.append("\n".join(manifest_lines))
    if commit_lines:
        parts.append("\n".join(commit_lines))
    parts.append(_FAILURES_HEADER)
    parts.append("\n".join(body_lines))
    (run_dir / "prompt.md").write_text("".join(parts), encoding="utf-8")


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def validate_combo(baseline: SideSpec, target: SideSpec) -> None:
    """Hard-error on combos we can't currently join.

    csv/tar × api (either direction): CSV and tar carry (case_name,
    component_name) but no case_id; API carries case_id but no names.
    No common join key → zero-row join.
    """
    sides = {baseline.source, target.source}
    if sides == {SOURCE_CSV, SOURCE_API}:
        raise SystemExit(
            "For this PoC, csv and api sources can't be combined "
            f"(baseline={baseline.source}, target={target.source}). CSV exports "
            "carry (case_name, component_name) but no case_id; API responses "
            "carry case_id but no names. No common join key.\n"
            "\n"
            "Workarounds today: use db on at least one side, or use the same "
            "source on both sides (api×api, csv×csv).\n"
            "\n"
            "Backlog: enrich api rows with case names (follow the case link), "
            "or csv rows with case_ids (lookup by (name, component))."
        )
    if sides == {SOURCE_TAR, SOURCE_API}:
        raise SystemExit(
            f"tar and api sources can't be combined "
            f"(baseline={baseline.source}, target={target.source}). tar archives "
            "carry (case_name, component_name) but no case_id; API responses "
            "carry case_id but no names. No common join key.\n"
            "\n"
            "Workarounds: use db or csv on one side instead of api."
        )


def _finalize_bundle(
    df: pd.DataFrame, run_id: str, run_dir: Path,
    classifier: str,
    baseline_source: str, target_source: str,
    build_a: int, build_b: int, hash_a: str, hash_b: str,
    routine_id: int | None, build_a_name: str, build_b_name: str,
    git_repo: Path,
) -> Path:
    print(f"→ Step 3/6 git diff …")
    diff_path = run_dir / "git_diff_full.diff"
    diff_lines = run_git_diff(git_repo, hash_a, hash_b, diff_path)
    print(f"   {diff_lines} lines → {diff_path.relative_to(PROJECT_ROOT)}")

    print(f"→ Step 4/6 fragments + filtered hunks …")
    fragments = derive_test_fragments(df)
    fragments_path = run_dir / "test_fragments.txt"
    fragments_path.write_text("\n".join(sorted(fragments)), encoding="utf-8")
    hunks_path = run_dir / "hunks.txt"
    if fragments:
        run_extract_hunks(diff_path, fragments_path, hunks_path)
        print(f"   {len(fragments)} fragments → {hunks_path.relative_to(PROJECT_ROOT)}")
    else:
        # Happens when neither side carries case_name (e.g. api × api): no
        # tokens to narrow the diff. Fall back to the full diff; classify
        # by reading hunks.txt directly.
        hunks_path.write_bytes(diff_path.read_bytes())
        print(f"   WARNING: no test_case fragments (both sides lack case_name). "
              f"Copying full diff → hunks.txt unfiltered.", file=sys.stderr)

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
        full_diff_path=diff_path,
        git_repo=git_repo,
    )
    write_run_yml(
        run_dir,
        run_id=run_id,
        baseline_source=baseline_source, target_source=target_source,
        classifier=classifier,
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


def prepare(baseline: SideSpec, target: SideSpec, classifier: str) -> Path:
    validate_combo(baseline, target)

    cfg         = load_config()
    testray_db  = cfg["databases"]["testray"]
    git_repo    = Path(cfg["git"]["repo_path"]).expanduser()

    ts      = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id  = f"r_{ts}_{baseline.build_id}_{target.build_id}"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"→ Step 1/6 test_diff "
          f"(baseline={baseline.source} × target={target.source}) …")
    baseline_df = fetch_caseresults(baseline, cfg)
    if baseline_df.empty:
        raise SystemExit(f"No case results for baseline build {baseline.build_id} "
                         f"(source={baseline.source}).")
    target_df = fetch_caseresults(target, cfg)
    if target_df.empty:
        raise SystemExit(f"No case results for target build {target.build_id} "
                         f"(source={target.source}).")
    print(f"   baseline rows: {len(baseline_df)}  target rows: {len(target_df)}")

    if target.source in (SOURCE_API, SOURCE_TAR):
        print(f"   NOTE: {target.source} targets do not populate `linked_issues` — the Jira",
              file=sys.stderr)
        print("         column in diff_list.csv will be blank for target-side failures.",
              file=sys.stderr)
        print("         Use db or csv on the target if Jira ticket context is needed.",
              file=sys.stderr)

    if target.source in (SOURCE_CSV, SOURCE_TAR):
        matched = target_df.merge(
            baseline_df[["case_name", "component_name"]].dropna(),
            on=["case_name", "component_name"], how="inner",
        )
        unmatched = len(target_df) - len(matched)
        if unmatched > 0:
            print(f"   unmatched target rows: {unmatched} "
                  f"(no baseline match — cannot persist)")

    df = compute_test_diff(baseline_df, target_df)
    if df.empty:
        raise SystemExit("test_diff returned 0 rows (no PASSED→FAILED after matching).")
    print(f"   {len(df)} regressions — status_b: "
          f"{df['status_b'].value_counts().to_dict()}")

    # api caseresults don't carry case names. If either side is api,
    # backfill test_case from the Testray case object so the fragment
    # matcher has something to anchor on (and so prompt.md doesn't say
    # `### N. \`\`` with no test name).
    if SOURCE_API in (baseline.source, target.source):
        df = enrich_api_case_names(df, cfg["testray"])

    print(f"→ Step 2/6 build metadata …")
    meta_a = resolve_side_metadata(baseline, testray_db)
    meta_b = resolve_side_metadata(target,   testray_db)

    routine_id = meta_a["routine_id"] or meta_b["routine_id"]
    if meta_a["routine_id"] and meta_b["routine_id"] \
            and meta_a["routine_id"] != meta_b["routine_id"]:
        print(f"WARNING: builds are on different routines "
              f"(A={meta_a['routine_id']}, B={meta_b['routine_id']}). "
              f"Diff may still be meaningful but test_diff will miss cases "
              f"that don't run on both.", file=sys.stderr)
    print(f"   routine_id={routine_id}  "
          f"A={meta_a['git_hash'][:12]}  B={meta_b['git_hash'][:12]}")

    return _finalize_bundle(
        df=df, run_id=run_id, run_dir=run_dir,
        classifier=classifier,
        baseline_source=baseline.source, target_source=target.source,
        build_a=baseline.build_id, build_b=target.build_id,
        hash_a=meta_a["git_hash"], hash_b=meta_b["git_hash"],
        routine_id=routine_id,
        build_a_name=meta_a["build_name"], build_b_name=meta_b["build_name"],
        git_repo=git_repo,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _add_side_args(ap: argparse.ArgumentParser, role: str) -> None:
    """Add --{role}-source / --{role}-build-id / --{role}-csv / --{role}-tar /
    --{role}-hash / --{role}-name to the parser."""
    ap.add_argument(f"--{role}-source",   choices=SOURCES, required=True,
                    help=f"Where to load the {role} build's case results from.")
    ap.add_argument(f"--{role}-build-id", type=int, required=False, default=None,
                    help=f"Build id for the {role} build. Required for db/csv/api; "
                         f"optional for tar (auto-extracted from testray.build.name).")
    ap.add_argument(f"--{role}-csv",      type=Path, default=None,
                    help=f"Path to Testray CSV export "
                         f"(required when --{role}-source=csv).")
    ap.add_argument(f"--{role}-tar",      type=Path, default=None,
                    help=f"Path to Testray JUnit XML tar.gz "
                         f"(required when --{role}-source=tar).")
    ap.add_argument(f"--{role}-hash",     default=None,
                    help=f"Git hash for the {role} build. Required for csv/tar; "
                         f"for api, optional — falls back to dim_build.")
    ap.add_argument(f"--{role}-name",     default=None,
                    help=f"Optional display name for the {role} build. "
                         f"For tar, auto-populated from testray.build.name if omitted.")


def _build_spec(args: argparse.Namespace, role: str) -> SideSpec:
    source   = getattr(args, f"{role}_source")
    csv      = getattr(args, f"{role}_csv")
    tar      = getattr(args, f"{role}_tar")
    hash_    = getattr(args, f"{role}_hash")
    build_id = getattr(args, f"{role}_build_id")
    name     = getattr(args, f"{role}_name")

    if source == SOURCE_CSV:
        if csv is None:
            raise SystemExit(f"--{role}-csv is required when --{role}-source=csv.")
        csv = csv.expanduser().resolve()
        if not csv.exists():
            raise SystemExit(f"{role} CSV not found: {csv}")
        if not hash_:
            raise SystemExit(f"--{role}-hash is required when --{role}-source=csv "
                             f"(CSV exports don't carry the build's git sha).")

    if source == SOURCE_TAR:
        if tar is None:
            raise SystemExit(f"--{role}-tar is required when --{role}-source=tar.")
        tar = tar.expanduser().resolve()
        if not tar.exists():
            raise SystemExit(f"{role} tar not found: {tar}")
        if not hash_:
            raise SystemExit(f"--{role}-hash is required when --{role}-source=tar "
                             f"(tar archives don't carry the build's git sha).")
        if build_id is None or name is None:
            meta = _extract_build_meta_from_tar(tar)
            if build_id is None:
                build_id = meta["build_id"] or 0
            if name is None:
                name = meta.get("build_name")

    if source not in (SOURCE_CSV, SOURCE_TAR) and build_id is None:
        raise SystemExit(
            f"--{role}-build-id is required when --{role}-source={source}."
        )

    if source != SOURCE_CSV and csv is not None:
        print(f"WARNING: --{role}-csv ignored (source={source}).", file=sys.stderr)
    if source != SOURCE_TAR and tar is not None:
        print(f"WARNING: --{role}-tar ignored (source={source}).", file=sys.stderr)

    return SideSpec(
        role=role, source=source,
        build_id=build_id if build_id is not None else 0,
        csv=csv if source == SOURCE_CSV else None,
        tar=tar if source == SOURCE_TAR else None,
        hash=hash_,
        name=name,
    )


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Prepare a triage run bundle for in-session classification. "
                    "Each side (baseline, target) independently selects a source: "
                    "db (testray_analytical), csv (Testray CSV export), api "
                    "(Testray REST), or tar (Jenkins JUnit XML tar.gz).",
    )
    _add_side_args(ap, "baseline")
    _add_side_args(ap, "target")
    ap.add_argument("--classifier", default=DEFAULT_CLASSIFIER,
                    help=f"Provenance label (default: {DEFAULT_CLASSIFIER})")

    args = ap.parse_args()
    baseline = _build_spec(args, "baseline")
    target   = _build_spec(args, "target")
    prepare(baseline, target, args.classifier)


if __name__ == "__main__":
    main()
