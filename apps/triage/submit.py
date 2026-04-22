"""
apps/triage/submit.py

Consume a classification bundle produced by prepare.py + the dev's own
Claude Code session, validate results.json, and upsert into
fact_triage_results + triage_run_log.

Usage:
    python3 apps/triage/submit.py runs/r_<id>
    python3 apps/triage/submit.py runs/r_<id> --no-upsert

--no-upsert prints the validated summary but does NOT write to the DB.
Useful on dev laptops where fact_triage_results is an ephemeral local copy.
"""

import argparse
import json
import sys
from pathlib import Path

import pandas as pd
import yaml

from apps.triage.store import (
    ensure_schema, ensure_run_log, upsert_triage_results, log_run,
)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

_CLASSIFICATIONS = {"BUG", "NEEDS_REVIEW", "FALSE_POSITIVE"}
_CONFIDENCES     = {"high", "medium", "low"}


def validate_results(payload: dict, expected_case_ids: set[int]) -> list[dict]:
    """
    Validate results.json against the run's diff_list. Returns the
    results list on success; raises SystemExit on any violation with a
    human-readable message.
    """
    errs: list[str] = []

    for key in ("run_id", "classifier", "results"):
        if key not in payload:
            errs.append(f"missing top-level key: {key!r}")
    if errs:
        _fail(errs)

    results = payload["results"]
    if not isinstance(results, list):
        _fail([f"`results` must be a list, got {type(results).__name__}"])

    seen_ids: set[int] = set()
    for i, r in enumerate(results):
        prefix = f"results[{i}]"
        if not isinstance(r, dict):
            errs.append(f"{prefix} must be an object")
            continue
        cid = r.get("testray_case_id")
        if not isinstance(cid, int):
            errs.append(f"{prefix}.testray_case_id must be an int")
        elif cid in seen_ids:
            errs.append(f"{prefix} duplicate testray_case_id={cid}")
        else:
            seen_ids.add(cid)
            if cid not in expected_case_ids:
                errs.append(f"{prefix} testray_case_id={cid} not in diff_list.csv "
                            f"(pre-classified or flaky cases must not appear)")

        cls = r.get("classification")
        if cls not in _CLASSIFICATIONS:
            errs.append(f"{prefix}.classification must be one of {_CLASSIFICATIONS}, got {cls!r}")
        conf = r.get("confidence")
        if conf not in _CONFIDENCES:
            errs.append(f"{prefix}.confidence must be one of {_CONFIDENCES}, got {conf!r}")
        if not isinstance(r.get("reason"), str) or not r["reason"].strip():
            errs.append(f"{prefix}.reason must be a non-empty string")

        culprit = r.get("culprit_file")
        if cls == "BUG":
            if not isinstance(culprit, str) or not culprit.strip():
                errs.append(f"{prefix} classification=BUG requires non-empty culprit_file")
        elif culprit is not None and not isinstance(culprit, str):
            errs.append(f"{prefix}.culprit_file must be string or null")

        specific = r.get("specific_change")
        if specific is not None and not isinstance(specific, str):
            errs.append(f"{prefix}.specific_change must be string or null")

    if errs:
        _fail(errs)

    missing = expected_case_ids - seen_ids
    if missing:
        print(f"WARNING: {len(missing)} case(s) in diff_list.csv have no entry "
              f"in results.json — they will not be persisted: "
              f"{sorted(missing)[:10]}{'...' if len(missing) > 10 else ''}",
              file=sys.stderr)

    return results


def _fail(errs: list[str]) -> None:
    print("results.json validation failed:", file=sys.stderr)
    for e in errs:
        print(f"  - {e}", file=sys.stderr)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# Assembly — combine agent results + AUTO_CLASSIFIED + flaky-excluded
# ---------------------------------------------------------------------------

def assemble_dataframe(diff_list: pd.DataFrame, results: list[dict]) -> pd.DataFrame:
    """
    Merge classifier results back into the diff_list. Auto-classified rows
    become classification=AUTO_CLASSIFIED; known-flaky rows are dropped
    (already excluded from what the classifier saw).
    """
    results_by_id = {r["testray_case_id"]: r for r in results}

    # Drop flaky rows — not persisted
    df = diff_list[~diff_list["known_flaky"].fillna(False)].copy()

    def _row(row):
        cid = row["testray_case_id"]
        if pd.notna(row.get("pre_classification")):
            return pd.Series({
                "classification":  "AUTO_CLASSIFIED",
                "specific_change": None,
                "reason":          f"pre_classification={row['pre_classification']}",
                "match_strategy":  "auto",
            })
        r = results_by_id.get(cid)
        if not r:
            return pd.Series({
                "classification":  "NEEDS_REVIEW",
                "specific_change": None,
                "reason":          "No entry in results.json — defaulted to NEEDS_REVIEW",
                "match_strategy":  "missing",
            })
        return pd.Series({
            "classification":  r["classification"],
            "specific_change": r.get("specific_change"),
            "reason":          r["reason"] + (
                f"  [culprit_file={r['culprit_file']}]"
                if r.get("culprit_file") else ""
            ),
            "match_strategy":  f"confidence={r['confidence']}",
        })

    df = pd.concat([df.reset_index(drop=True),
                    df.apply(_row, axis=1).reset_index(drop=True)], axis=1)
    df["tokens_in"]  = 0
    df["tokens_out"] = 0
    df["api_error"]  = None
    df["batch_number"] = None
    return df


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Submit a triage run bundle.")
    ap.add_argument("run_dir", type=Path, help="Path to runs/r_<id>/")
    ap.add_argument("--no-upsert", action="store_true",
                    help="Validate and print summary but skip DB writes.")
    args = ap.parse_args()

    run_dir: Path = args.run_dir.resolve()
    if not run_dir.is_dir():
        raise SystemExit(f"Not a directory: {run_dir}")

    run_yml   = run_dir / "run.yml"
    results_f = run_dir / "results.json"
    diff_list = run_dir / "diff_list.csv"
    for p in (run_yml, results_f, diff_list):
        if not p.exists():
            raise SystemExit(f"Missing required file: {p}")

    meta = yaml.safe_load(run_yml.read_text())
    payload = json.loads(results_f.read_text())
    diff_list_df = pd.read_csv(diff_list)

    # Validation uses the set of case_ids the classifier was expected to handle
    # (non-flaky, no pre_classification)
    expected = diff_list_df[
        ~diff_list_df["known_flaky"].fillna(False)
        & diff_list_df["pre_classification"].isna()
    ]["testray_case_id"].astype(int).tolist()
    validate_results(payload, set(expected))

    # Consistency checks against run.yml
    if payload["run_id"] != meta["run_id"]:
        print(f"WARNING: results.json run_id={payload['run_id']} "
              f"does not match run.yml run_id={meta['run_id']}",
              file=sys.stderr)
    if payload["classifier"] != meta["classifier"]:
        print(f"WARNING: results.json classifier={payload['classifier']} "
              f"overrides run.yml classifier={meta['classifier']}",
              file=sys.stderr)

    df = assemble_dataframe(diff_list_df, payload["results"])

    counts = df["classification"].value_counts().to_dict()
    bug_rows = df[df["classification"] == "BUG"]
    culprit_hits = sum(
        1 for _, r in bug_rows.iterrows()
        if "culprit_file=" in str(r.get("reason") or "")
    )
    culprit_pct = (100 * culprit_hits / len(bug_rows)) if len(bug_rows) else 0.0

    print(f"\nRun:        {meta['run_id']}")
    print(f"Classifier: {payload['classifier']}")
    print(f"Build pair: {meta['build_id_a']} → {meta['build_id_b']} "
          f"(routine {meta['routine_id']})")
    print(f"Totals:     {len(df)} rows — "
          + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print(f"BUG culprit_file coverage: {culprit_hits}/{len(bug_rows)} "
          f"({culprit_pct:.0f}%; target ≥85%)")

    if args.no_upsert:
        print("\n--no-upsert set → not writing to fact_triage_results / triage_run_log.")
        return

    ensure_schema()
    ensure_run_log()
    upsert_triage_results(
        df,
        build_id_a=meta["build_id_a"],
        build_id_b=meta["build_id_b"],
        git_hash_a=meta["git_hash_a"],
        git_hash_b=meta["git_hash_b"],
        classifier=payload["classifier"],
    )
    log_run(
        build_id_a=meta["build_id_a"],
        build_id_b=meta["build_id_b"],
        git_hash_a=meta["git_hash_a"],
        git_hash_b=meta["git_hash_b"],
        df=df,
        flaky_excluded=int(meta.get("flaky_excluded", 0)),
        duration_seconds=0.0,
        notes=payload.get("notes")
              or f"Run bundle: {run_dir.relative_to(run_dir.parents[2])}",
        classifier=payload["classifier"],
    )


if __name__ == "__main__":
    main()
