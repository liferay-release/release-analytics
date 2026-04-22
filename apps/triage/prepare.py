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
# Step 1: test_diff from testray_analytical
# ---------------------------------------------------------------------------

def run_test_diff(build_a: int, build_b: int, db_cfg: dict) -> pd.DataFrame:
    sql_raw = (TRIAGE_DIR / "test_diff.sql").read_text()
    sql = _strip_sql_comments(sql_raw)
    sql = sql.replace("%(build_id_a)s", str(build_a)) \
             .replace("%(build_id_b)s", str(build_b))

    with _connect(db_cfg) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            rows = cur.fetchall()
    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Step 2: git_hash + routine lookup from dim_build
# ---------------------------------------------------------------------------

def resolve_build_metadata(build_a: int, build_b: int, db_cfg: dict) -> dict:
    sql_raw = (TRIAGE_DIR / "git_hash_lookup.sql").read_text()
    sql = _strip_sql_comments(sql_raw)
    sql = sql.replace("%(build_id_a)s", str(build_a)) \
             .replace("%(build_id_b)s", str(build_b))

    with _connect(db_cfg) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            rows = {r["build_id"]: r for r in cur.fetchall()}

    if build_a not in rows or build_b not in rows:
        missing = [b for b in (build_a, build_b) if b not in rows]
        raise SystemExit(f"Build(s) not in dim_build: {missing}")

    ra, rb = rows[build_a], rows[build_b]
    if ra["routine_id"] != rb["routine_id"]:
        print(f"WARNING: builds are on different routines "
              f"(A={ra['routine_id']}, B={rb['routine_id']}). "
              f"Diff may still be meaningful but test_diff will miss cases "
              f"that don't run on both.", file=sys.stderr)
    return {
        "hash_a":     ra["git_hash"],
        "hash_b":     rb["git_hash"],
        "routine_id": ra["routine_id"],
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

def enrich_and_pre_classify(df: pd.DataFrame, rap_cfg: dict | None) -> pd.DataFrame:
    cfg          = prompt_helpers.load_triage_config()
    extra_pats   = cfg.get("auto_classify_patterns") or {}

    df = df.rename(columns={"testray_component_name": "component_name"}).copy()

    if "team_name" not in df.columns:
        df["team_name"] = None

    if rap_cfg:
        try:
            team_map = _load_component_team_map(rap_cfg)
            df["team_name"] = df["component_name"].map(team_map).fillna(df["team_name"])
        except Exception as e:
            print(f"WARNING: team_name enrichment skipped ({e})", file=sys.stderr)

    df["pre_classification"] = df["error_message"].apply(
        lambda e: prompt_helpers.pre_classify(e, extra_pats)
    )

    return df


def _load_component_team_map(rap_cfg: dict) -> dict[str, str]:
    """Return { component_name: team_name } from dim_component."""
    with _connect(rap_cfg) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT component_name, team_name FROM dim_component")
            return {r["component_name"]: r["team_name"] for r in cur.fetchall()
                    if r["component_name"]}


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

def prepare_from_db(build_a: int, build_b: int, classifier: str) -> Path:
    cfg        = load_config()
    testray    = cfg["databases"]["testray"]
    rap_cfg    = cfg["databases"].get("release_analytics")
    git_repo   = Path(cfg["git"]["repo_path"]).expanduser()

    ts      = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id  = f"r_{ts}_{build_a}_{build_b}"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"→ Step 1/6 test_diff …")
    df = run_test_diff(build_a, build_b, testray)
    if df.empty:
        raise SystemExit("test_diff returned 0 rows.")
    print(f"   {len(df)} rows (before dedup) — status_b: "
          f"{df['status_b'].value_counts().to_dict()}")

    print(f"→ Step 2/6 build metadata …")
    meta = resolve_build_metadata(build_a, build_b, testray)
    print(f"   routine_id={meta['routine_id']}  "
          f"A={meta['hash_a'][:12]}  B={meta['hash_b'][:12]}")

    print(f"→ Step 3/6 git diff …")
    diff_path = run_dir / "git_diff_full.diff"
    diff_lines = run_git_diff(git_repo, meta["hash_a"], meta["hash_b"], diff_path)
    print(f"   {diff_lines} lines → {diff_path.relative_to(PROJECT_ROOT)}")

    print(f"→ Step 4/6 fragments + filtered hunks …")
    fragments = derive_test_fragments(df)
    fragments_path = run_dir / "test_fragments.txt"
    fragments_path.write_text("\n".join(sorted(fragments)), encoding="utf-8")
    hunks_path = run_dir / "hunks.txt"
    run_extract_hunks(diff_path, fragments_path, hunks_path)
    print(f"   {len(fragments)} fragments → {hunks_path.relative_to(PROJECT_ROOT)}")

    print(f"→ Step 5/6 enrich + pre-classify …")
    df = enrich_and_pre_classify(df, rap_cfg)
    # Dedup — SQL can return duplicates when a case has multiple result rows per build
    df = df.drop_duplicates(subset="testray_case_id", keep="first").reset_index(drop=True)
    df_flaky = df[df["known_flaky"].fillna(False)].copy()
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
        hash_a=meta["hash_a"], hash_b=meta["hash_b"],
        routine_id=meta["routine_id"],
        build_a_name=meta["build_a_name"], build_b_name=meta["build_b_name"],
        df_to_classify=df_to_cls, df_auto=df_auto, df_flaky=df_flaky,
        hunks_path=hunks_path,
    )
    write_run_yml(
        run_dir,
        run_id=run_id, input_mode="from-db", classifier=classifier,
        build_a=build_a, build_b=build_b,
        hash_a=meta["hash_a"], hash_b=meta["hash_b"],
        routine_id=meta["routine_id"],
        build_a_name=meta["build_a_name"], build_b_name=meta["build_b_name"],
        total_failures=len(df),
        auto_classified=len(df_auto),
        flaky_excluded=len(df_flaky),
    )

    rel = run_dir.relative_to(PROJECT_ROOT)
    print(f"\nRun bundle ready: {rel}")
    print(f"Next: open {rel}/prompt.md in your Claude Code session and classify.")
    print(f"Then: python3 apps/triage/submit.py {rel}")
    return run_dir


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Prepare a triage run bundle for in-session classification.",
    )
    sub = ap.add_subparsers(dest="mode", required=True)

    db = sub.add_parser("from-db",
        help="Read PASSED→FAILED cases from testray_analytical for a given build pair.")
    db.add_argument("--build-a", type=int, required=True, help="Baseline build id")
    db.add_argument("--build-b", type=int, required=True, help="Target build id")
    db.add_argument("--classifier", default=DEFAULT_CLASSIFIER,
                    help=f"Provenance label written to fact_triage_results "
                         f"(default: {DEFAULT_CLASSIFIER})")

    args = ap.parse_args()
    if args.mode == "from-db":
        prepare_from_db(args.build_a, args.build_b, args.classifier)
    else:
        raise SystemExit(f"Unknown mode: {args.mode}")


if __name__ == "__main__":
    main()
