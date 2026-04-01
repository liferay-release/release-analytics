"""
apps/triage/prompt_builder.py

Builds batched Claude prompts from:
  - test_diff DataFrame    (PASSED→FAILED/BLOCKED/UNTESTED cases)
  - triage_diff_precise.md (filtered git diff hunks)
  - module_matcher         (component/team enrichment)

Pipeline position:
    test_diff.sql → [this file] → triage_claude.py

Outputs a list of TriageBatch objects, each containing:
  - prompt text (~24k tokens)
  - metadata (failure indices, build IDs, etc.)

Pre-classification:
  Before sending to Claude, errors matching known env/infra patterns
  are auto-classified and excluded from the prompt. This keeps
  Claude API costs down and focuses the prompt on real candidates.
"""

import re
import yaml
import pandas as pd
from dataclasses import dataclass, field
from pathlib import Path

from apps.triage.module_matcher import ModuleMatcher, enrich_test_diff_with_components


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_triage_config() -> dict:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                cfg = yaml.safe_load(f)
                return cfg.get("triage", {})
    return {}


# ---------------------------------------------------------------------------
# Pre-classifier — keeps obvious env/infra failures out of Claude
# ---------------------------------------------------------------------------

# Default patterns — augmented by config.yml auto_classify_patterns
DEFAULT_AUTO_CLASSIFY = {
    "BUILD_FAILURE": [
        "The build failed prior to running the test",
    ],
    "ENV_CHROME": [
        "chrome=100.0",
        "Session info: chrome=1",
    ],
    "ENV_DEPENDENCY": [
        "org.tensorflow",
        "repository-cdn.liferay.com",
        "Downloaded https://repository-cdn",
    ],
    "ENV_DATE": [
        r"data-startdate,'11/\d{2}/20\d{2}'",   # hardcoded date XPaths
    ],
    "ENV_SETUP": [
        "TEST_SETUP_ERROR",
    ],
}


def pre_classify(error_message: str, extra_patterns: dict = None) -> str | None:
    """
    Returns an auto-classification string if the error matches a known
    env/infra pattern, or None if it should be sent to Claude.

    Args:
        error_message:   The raw error string from Testray
        extra_patterns:  Additional patterns from config.yml triage.auto_classify_patterns

    Returns:
        Classification string e.g. "BUILD_FAILURE", "ENV_CHROME", or None
    """
    if not error_message or pd.isna(error_message):
        return "NO_ERROR"

    patterns = {**DEFAULT_AUTO_CLASSIFY, **(extra_patterns or {})}

    for classification, pattern_list in patterns.items():
        for pattern in pattern_list:
            if re.search(pattern, str(error_message), re.IGNORECASE):
                return classification

    return None


# ---------------------------------------------------------------------------
# Diff parser — load triage_diff_precise.md into per-file blocks
# ---------------------------------------------------------------------------

def parse_diff_blocks(diff_path: str | Path) -> dict[str, str]:
    """
    Parse a unified git diff file into a dict of:
        full_file_path → hunk text

    Args:
        diff_path: Path to triage_diff_precise.md (output of extract_relevant_hunks.py)

    Returns:
        Dict mapping file path (from b/ header) to its full diff block text
    """
    diff_path = Path(diff_path)
    if not diff_path.exists():
        raise FileNotFoundError(f"Diff file not found: {diff_path}")

    with open(diff_path, encoding="utf-8") as f:
        text = f.read()

    blocks = {}
    current_file = None
    current_lines = []

    for line in text.splitlines():
        if line.startswith("diff --git "):
            if current_file and current_lines:
                blocks[current_file] = "\n".join(current_lines)
            current_lines = [line]
            m = re.match(r"diff --git a/.+ b/(.+)", line)
            current_file = m.group(1) if m else None
        else:
            current_lines.append(line)

    if current_file and current_lines:
        blocks[current_file] = "\n".join(current_lines)

    return blocks


# ---------------------------------------------------------------------------
# Diff block lookup — match a test row to its diff blocks
# ---------------------------------------------------------------------------

def find_diff_blocks(
    test_case: str,
    component_name: str | None,
    matched_diff_files: str | None,
    diff_blocks: dict[str, str],
    max_blocks: int = 3,
    max_lines_per_block: int = 60,
) -> list[tuple[str, str]]:
    """
    Find the most relevant diff blocks for a test failure.

    Returns list of (file_path, truncated_hunk_text) tuples.
    Tries matched_diff_files first, then component name, then test name tokens.
    """
    matched = []
    seen = set()

    def add_block(fp):
        if fp not in seen and fp in diff_blocks:
            hunk_lines = diff_blocks[fp].splitlines()
            if len(hunk_lines) > max_lines_per_block:
                hunk_lines = hunk_lines[:max_lines_per_block] + [
                    f"... ({len(hunk_lines) - max_lines_per_block} more lines)"
                ]
            matched.append((fp, "\n".join(hunk_lines)))
            seen.add(fp)

    # Strategy 1: matched_diff_files column (from extract_relevant_hunks)
    if matched_diff_files and not pd.isna(matched_diff_files):
        for fragment in str(matched_diff_files).split("|"):
            fragment = fragment.strip().lower()
            if not fragment:
                continue
            for fp in diff_blocks:
                if fp.lower().endswith(fragment) or fp.lower().split("/")[-1] == fragment.split("/")[-1]:
                    add_block(fp)
                    if len(matched) >= max_blocks:
                        return matched

    # Strategy 2: component name tokens against diff file paths
    if component_name:
        comp_tokens = [
            t.lower() for t in re.split(r"[\s/\-_]", component_name)
            if len(t) > 3
        ]
        for fp in diff_blocks:
            fp_lower = fp.lower()
            if any(tok in fp_lower for tok in comp_tokens):
                add_block(fp)
                if len(matched) >= max_blocks:
                    return matched

    # Strategy 3: test case name tokens
    test_tokens = [
        t.lower() for t in re.split(r"[.\-/_ >]", test_case)
        if len(t) > 5
    ]
    for fp in diff_blocks:
        fp_lower = fp.lower()
        if any(tok in fp_lower for tok in test_tokens):
            add_block(fp)
            if len(matched) >= max_blocks:
                return matched

    return matched


# ---------------------------------------------------------------------------
# Name shortener
# ---------------------------------------------------------------------------

def shorten_test_name(name: str) -> str:
    """Shorten long Java/Playwright test names for readability in the prompt."""
    if "LocalFile." in name:
        return name.replace("LocalFile.", "")
    if "." in name and ">" not in name:
        parts = name.split(".")
        return ".".join(parts[-2:]) if len(parts) > 2 else name
    return name


# ---------------------------------------------------------------------------
# Batch dataclass
# ---------------------------------------------------------------------------

@dataclass
class TriageBatch:
    batch_number:   int
    build_id_a:     int
    build_id_b:     int
    git_hash_a:     str
    git_hash_b:     str
    failure_indices: list[int]        # 1-based failure numbers
    prompt:         str
    rows:           list[dict]        # original rows for this batch
    auto_classified: list[dict] = field(default_factory=list)  # pre-filtered rows


# ---------------------------------------------------------------------------
# Main builder
# ---------------------------------------------------------------------------

PROMPT_HEADER_TEMPLATE = """You are a release quality engineer at Liferay triaging test failures between two builds.

## Context
- Build A (baseline): {build_id_a} (git: {git_hash_a})
- Build B (new):      {build_id_b} (git: {git_hash_b})
- All cases PASSED in Build A and are FAILED/BLOCKED/UNTESTED in Build B.
- known_flaky=False for all rows (flaky cases excluded before this step).
- Each failure includes matched diff hunks from the git diff between the two builds.
- Component and team ownership is provided where resolved.

## Task
For each failure, analyze the error message against the diff hunks and:
1. Identify the specific changed file/method most likely causing the failure
2. Classify as:
   - **BUG**: error clearly caused by a specific change in the diff
   - **NEEDS_REVIEW**: plausible connection but indirect; needs human judgment
   - **FALSE_POSITIVE**: error unrelated to diff (env/infra/timing/test isolation)
3. Give a one-line reason referencing the specific change

Return a markdown table — one row per failure:
| # | Test Case | Component | Classification | Specific Change | Reason |

---
"""


def build_batches(
    test_diff_df:   pd.DataFrame,
    diff_path:      str | Path,
    build_id_a:     int,
    build_id_b:     int,
    git_hash_a:     str,
    git_hash_b:     str,
    max_chars_per_batch: int = 96_000,   # ~24k tokens
) -> list[TriageBatch]:
    """
    Main entry point. Takes the test_diff DataFrame and diff file,
    returns a list of TriageBatch objects ready for triage_claude.py.

    Args:
        test_diff_df:         Output of test_diff.sql (must have columns:
                              test_case, known_flaky, error_message,
                              linked_issues, testray_case_id,
                              testray_component_name)
        diff_path:            Path to triage_diff_precise.md
        build_id_a/b:         Build IDs
        git_hash_a/b:         Git hashes from git_hash_lookup.sql
        max_chars_per_batch:  Approx char budget per batch (~4 chars/token)

    Returns:
        List of TriageBatch — batches to send to Claude
        Auto-classified rows are attached to batch 0 metadata (not sent to Claude)
    """
    cfg = _load_triage_config()
    extra_patterns = cfg.get("auto_classify_patterns", {})

    # Step 1: exclude known_flaky
    df = test_diff_df[~test_diff_df["known_flaky"].fillna(False)].copy()
    df = df.reset_index(drop=True)

    # Step 2: enrich with component/team from module_matcher
    if "component_name" not in df.columns:
        print("Enriching with module→component map...")
        matcher = ModuleMatcher()
        df = enrich_test_diff_with_components(df, matcher)

    # Step 3: pre-classify env/infra errors
    df["pre_classification"] = df["error_message"].apply(
        lambda e: pre_classify(e, extra_patterns)
    )

    auto_classified = df[df["pre_classification"].notna()].to_dict("records")
    to_triage = df[df["pre_classification"].isna()].copy().reset_index(drop=True)

    print(f"Total failures:     {len(df)}")
    print(f"Auto-classified:    {len(auto_classified)} (excluded from Claude)")
    print(f"Sending to Claude:  {len(to_triage)}")

    # Step 4: parse diff blocks
    diff_blocks = parse_diff_blocks(diff_path)
    print(f"Diff blocks loaded: {len(diff_blocks)} files")

    # Step 5: build prompt header
    header = PROMPT_HEADER_TEMPLATE.format(
        build_id_a=build_id_a,
        build_id_b=build_id_b,
        git_hash_a=git_hash_a[:12] if git_hash_a else "unknown",
        git_hash_b=git_hash_b[:12] if git_hash_b else "unknown",
    )
    header_chars = len(header)

    # Step 6: batch failures
    batches = []
    current_batch_rows = []
    current_batch_chars = header_chars
    batch_number = 1
    global_idx = 1

    for _, row in to_triage.iterrows():
        # Build entry text for this failure
        blocks = find_diff_blocks(
            test_case=str(row.get("test_case", "")),
            component_name=row.get("component_name"),
            matched_diff_files=row.get("matched_diff_files"),
            diff_blocks=diff_blocks,
        )

        entry_lines = []
        short_name = shorten_test_name(str(row.get("test_case", "")))
        component  = row.get("component_name") or row.get("testray_component_name") or "Unknown"
        team       = row.get("team_name", "")

        entry_lines.append(f"### Failure {global_idx}: `{short_name}`")
        entry_lines.append(f"**Component:** {component}" + (f" ({team})" if team else ""))
        entry_lines.append(f"**Status B:** {row.get('status_b', 'FAILED')}")
        entry_lines.append(f"**Error:** {str(row.get('error_message', ''))[:400]}")

        if row.get("linked_issues") and not pd.isna(row.get("linked_issues")):
            entry_lines.append(f"**Jira:** {row['linked_issues']}")

        entry_lines.append("")

        if blocks:
            for fp, hunk in blocks:
                entry_lines.append(f"```diff")
                entry_lines.append(hunk)
                entry_lines.append("```")
                entry_lines.append("")
        else:
            entry_lines.append(
                "_No diff hunk matched — classify as FALSE_POSITIVE "
                "unless error clearly indicates a code regression._"
            )
            entry_lines.append("")

        entry_lines.append("---")
        entry_lines.append("")
        entry_text = "\n".join(entry_lines)
        entry_chars = len(entry_text)

        # Flush batch if over budget
        if current_batch_chars + entry_chars > max_chars_per_batch and current_batch_rows:
            batches.append(_make_batch(
                batch_number, current_batch_rows, header,
                build_id_a, build_id_b, git_hash_a, git_hash_b
            ))
            batch_number += 1
            current_batch_rows = []
            current_batch_chars = header_chars

        current_batch_rows.append({
            "global_idx": global_idx,
            "entry_text": entry_text,
            "row": row.to_dict(),
        })
        current_batch_chars += entry_chars
        global_idx += 1

    # Flush final batch
    if current_batch_rows:
        batches.append(_make_batch(
            batch_number, current_batch_rows, header,
            build_id_a, build_id_b, git_hash_a, git_hash_b
        ))

    # Attach auto-classified rows to first batch for storage
    if batches:
        batches[0].auto_classified = auto_classified

    print(f"Batches created:    {len(batches)}")
    for b in batches:
        idx_range = f"{b.failure_indices[0]}–{b.failure_indices[-1]}"
        print(f"  Batch {b.batch_number}: failures {idx_range} "
              f"({len(b.rows)} cases, ~{len(b.prompt)//4} tokens)")

    return batches


def _make_batch(
    batch_number, rows, header,
    build_id_a, build_id_b, git_hash_a, git_hash_b
) -> TriageBatch:
    prompt = header + "\n".join(r["entry_text"] for r in rows)
    return TriageBatch(
        batch_number=batch_number,
        build_id_a=build_id_a,
        build_id_b=build_id_b,
        git_hash_a=git_hash_a,
        git_hash_b=git_hash_b,
        failure_indices=[r["global_idx"] for r in rows],
        prompt=prompt,
        rows=[r["row"] for r in rows],
    )


# ---------------------------------------------------------------------------
# CLI — validate batches without calling Claude
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys
    import json

    if len(sys.argv) < 4:
        print("Usage: python prompt_builder.py <test_diff.csv> <triage_diff.md> <build_id_a> <build_id_b>")
        print("Example: python prompt_builder.py output/test_diff.csv output/triage_diff_precise.md 410851196 451312408")
        sys.exit(1)

    csv_path    = sys.argv[1]
    diff_path   = sys.argv[2]
    build_id_a  = int(sys.argv[3])
    build_id_b  = int(sys.argv[4]) if len(sys.argv) > 4 else 0

    df = pd.read_csv(csv_path)
    batches = build_batches(
        test_diff_df=df,
        diff_path=diff_path,
        build_id_a=build_id_a,
        build_id_b=build_id_b,
        git_hash_a="hash_a_unknown",
        git_hash_b="hash_b_unknown",
    )

    output_dir = Path("apps/triage/output")
    output_dir.mkdir(parents=True, exist_ok=True)

    for batch in batches:
        out = output_dir / f"batch_{batch.batch_number}.md"
        out.write_text(batch.prompt, encoding="utf-8")
        print(f"Written: {out}")

    print(f"\nAuto-classified (not sent to Claude): {len(batches[0].auto_classified)}")