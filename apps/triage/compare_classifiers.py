"""
apps/triage/compare_classifiers.py

Compare two classifier runs against the same build pair in
fact_triage_results. Used as the validation gate before trusting API
mode (api:claude-opus-4-7) as a substitute for Claude Code mode
(agent:claude-opus-4-7) in headless / Jenkins contexts.

The comparison joins rows on testray_case_id and reports:
    - overall agreement rate (same classification)
    - confusion matrix (BUG / NEEDS_REVIEW / FALSE_POSITIVE / AUTO_CLASSIFIED)
    - culprit_file agreement on shared BUG rows
    - rows present in one classifier but missing from the other

Usage:
    python3 -m apps.triage.compare_classifiers \\
        --build-id-b 461433913 \\
        --classifier-a agent:claude-opus-4-7 \\
        --classifier-b api:claude-opus-4-7

    # Omit --build-id-b to compare across all shared builds:
    python3 -m apps.triage.compare_classifiers \\
        --classifier-a agent:claude-opus-4-7 \\
        --classifier-b api:claude-opus-4-7
"""

import argparse
import sys
from collections import Counter
from pathlib import Path

import pandas as pd

from apps.triage.db import get_rap_conn, query_df


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

def fetch_pair(
    classifier_a: str, classifier_b: str, build_id_b: int | None,
) -> pd.DataFrame:
    """Join fact_triage_results on (build_id_b, testray_case_id) across the
    two classifiers. Returns one row per case present in either classifier,
    with _a / _b suffixed columns for classification + culprit info."""
    filter_sql  = "WHERE a.build_id_b = %s" if build_id_b else ""
    filter_args: tuple = (classifier_a, classifier_b)
    if build_id_b:
        filter_args = (classifier_a, classifier_b, build_id_b)

    sql = f"""
        WITH a AS (
            SELECT build_id_b, testray_case_id, test_case, component_name,
                   classification, reason
            FROM fact_triage_results
            WHERE classifier = %s
        ),
        b AS (
            SELECT build_id_b, testray_case_id, test_case, component_name,
                   classification, reason
            FROM fact_triage_results
            WHERE classifier = %s
        )
        SELECT
            COALESCE(a.build_id_b,      b.build_id_b)      AS build_id_b,
            COALESCE(a.testray_case_id, b.testray_case_id) AS testray_case_id,
            COALESCE(a.test_case,       b.test_case)       AS test_case,
            COALESCE(a.component_name,  b.component_name)  AS component_name,
            a.classification AS classification_a,
            b.classification AS classification_b,
            a.reason         AS reason_a,
            b.reason         AS reason_b
        FROM a
        FULL OUTER JOIN b USING (build_id_b, testray_case_id)
        {filter_sql.replace("a.build_id_b", "COALESCE(a.build_id_b, b.build_id_b)")}
        ORDER BY build_id_b, testray_case_id
    """
    with get_rap_conn() as conn:
        return query_df(conn, sql, params=filter_args)


# ---------------------------------------------------------------------------
# Culprit-file extraction — submit.py stores it appended to `reason`
# ---------------------------------------------------------------------------

def extract_culprit(reason: str | None) -> str | None:
    """submit.py appends `  [culprit_file=...]` to reason when a BUG row
    has a culprit. Pull it back out for comparison."""
    if not reason:
        return None
    marker = "[culprit_file="
    i = reason.find(marker)
    if i < 0:
        return None
    j = reason.find("]", i)
    if j < 0:
        return None
    return reason[i + len(marker):j].strip()


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def report(df: pd.DataFrame, classifier_a: str, classifier_b: str) -> None:
    if df.empty:
        print("No rows found for either classifier on the requested filter.")
        return

    both    = df[df["classification_a"].notna() & df["classification_b"].notna()]
    only_a  = df[df["classification_a"].notna() & df["classification_b"].isna()]
    only_b  = df[df["classification_a"].isna()  & df["classification_b"].notna()]

    print(f"Classifier A: {classifier_a}")
    print(f"Classifier B: {classifier_b}")
    print(f"Build(s):     {sorted(df['build_id_b'].dropna().unique().tolist())}")
    print()
    print(f"Shared cases: {len(both):>5d}")
    print(f"Only in A:    {len(only_a):>5d}")
    print(f"Only in B:    {len(only_b):>5d}")

    if both.empty:
        print("\nNo shared cases to compare. Did both classifiers run on the "
              "same build pair?")
        return

    agree = both[both["classification_a"] == both["classification_b"]]
    agreement_pct = 100 * len(agree) / len(both)
    print(f"\nAgreement:    {len(agree)}/{len(both)} ({agreement_pct:.1f}%)  "
          f"[validation gate: ≥85%]")

    # Confusion matrix
    print("\nConfusion matrix (rows = A, cols = B, diagonals = agreement):")
    labels = sorted(set(both["classification_a"]) | set(both["classification_b"]))
    conf: dict[tuple[str, str], int] = Counter(
        zip(both["classification_a"], both["classification_b"])
    )

    col_w = max(len(l) for l in labels + ["A \\ B"]) + 2
    print(" " * col_w + "".join(f"{l:>{col_w}}" for l in labels))
    for a in labels:
        row = f"{a:<{col_w}}"
        for b in labels:
            row += f"{conf.get((a, b), 0):>{col_w}d}"
        print(row)

    # Disagreements — show the top 10 most common pairs
    disagree = both[both["classification_a"] != both["classification_b"]]
    if not disagree.empty:
        print(f"\nTop disagreements ({len(disagree)} total):")
        top = Counter(zip(disagree["classification_a"],
                          disagree["classification_b"])).most_common(10)
        for (a, b), n in top:
            print(f"  {a:>15} → {b:<15}  {n}")

    # Culprit-file agreement on shared BUG rows
    shared_bug = both[(both["classification_a"] == "BUG")
                      & (both["classification_b"] == "BUG")].copy()
    if not shared_bug.empty:
        shared_bug["culprit_a"] = shared_bug["reason_a"].apply(extract_culprit)
        shared_bug["culprit_b"] = shared_bug["reason_b"].apply(extract_culprit)
        same_culprit = shared_bug[
            shared_bug["culprit_a"].notna()
            & shared_bug["culprit_b"].notna()
            & (shared_bug["culprit_a"] == shared_bug["culprit_b"])
        ]
        both_named = shared_bug[shared_bug["culprit_a"].notna()
                                & shared_bug["culprit_b"].notna()]
        print(f"\nShared BUG rows: {len(shared_bug)}")
        if not both_named.empty:
            pct = 100 * len(same_culprit) / len(both_named)
            print(f"  Both named a culprit_file: {len(both_named)}")
            print(f"  Exact culprit match:       {len(same_culprit)}  ({pct:.1f}%)")
        missing = shared_bug[shared_bug["culprit_a"].isna()
                             | shared_bug["culprit_b"].isna()]
        if not missing.empty:
            print(f"  Missing culprit on one side: {len(missing)} "
                  f"(submit.py should have rejected these — investigate)")

    if not only_a.empty or not only_b.empty:
        print(f"\nCoverage gaps:")
        if not only_a.empty:
            cls_a = only_a["classification_a"].value_counts().to_dict()
            print(f"  Only in {classifier_a}: {len(only_a)} ({cls_a})")
        if not only_b.empty:
            cls_b = only_b["classification_b"].value_counts().to_dict()
            print(f"  Only in {classifier_b}: {len(only_b)} ({cls_b})")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Compare two classifiers on shared cases in "
                    "fact_triage_results. Use to validate API mode agrees "
                    "with Claude Code mode before trusting Jenkins runs.",
    )
    ap.add_argument("--classifier-a", default="agent:claude-opus-4-7",
                    help="First classifier label (default: agent:claude-opus-4-7)")
    ap.add_argument("--classifier-b", default="api:claude-opus-4-7",
                    help="Second classifier label (default: api:claude-opus-4-7)")
    ap.add_argument("--build-id-b", type=int, default=None,
                    help="Restrict comparison to a single build_id_b. "
                         "Omit to compare across all shared builds.")
    ap.add_argument("--csv", type=Path, default=None,
                    help="Optional path to dump the joined comparison as CSV.")
    args = ap.parse_args()

    df = fetch_pair(args.classifier_a, args.classifier_b, args.build_id_b)
    report(df, args.classifier_a, args.classifier_b)

    if args.csv:
        df.to_csv(args.csv, index=False)
        print(f"\nJoined comparison written to {args.csv}")


if __name__ == "__main__":
    main()
