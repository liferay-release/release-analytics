"""
apps/triage/prompt_helpers.py

Pure helpers used by prepare.py to assemble the classifier prompt:
  - Pre-classification of env/infra errors (skip these in reasoning)
  - Parsing the filtered git diff into per-file hunk blocks
  - Matching a failing test row to the most relevant hunk blocks
  - Shortening long Java/Playwright test names for display

Previously lived in prompt_builder.py alongside API-batch assembly. The
batch-API path is gone (see plan — classification is done by the dev's own
Claude Code session), but the matching/pre-classification logic is still
useful for the new prepare → classify → submit seam.
"""

import csv
import re
from functools import lru_cache
from pathlib import Path

import pandas as pd
import yaml


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def load_triage_config() -> dict:
    """Load the `triage:` section of config/config.yml, walking up from here."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                return (yaml.safe_load(f) or {}).get("triage", {}) or {}
    return {}


@lru_cache(maxsize=1)
def _find_project_root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "config" / "config.yml").exists() or \
           (parent / "config" / "module_component_map.csv").exists():
            return parent
    return here.parents[2]


@lru_cache(maxsize=1)
def load_component_map() -> list[dict]:
    """
    Load `config/module_component_map.csv` — authoritative module → testray
    component + team mapping. Returns a list of dicts with keys:
      module_path (may be empty for component+team-only rows),
      testray_component, team_name.

    Triage reads this CSV directly (no DB dependency) so the tool works on a
    dev laptop without a local release_analytics database.
    """
    path = _find_project_root() / "config" / "module_component_map.csv"
    if not path.exists():
        return []
    with open(path) as f:
        return [dict(r) for r in csv.DictReader(f)]


def team_for_component(component_name: str | None) -> str | None:
    """Reverse-lookup team for a Testray component name. Returns None if unknown."""
    if not component_name:
        return None
    for row in load_component_map():
        if row.get("testray_component") == component_name and row.get("team_name"):
            return row["team_name"]
    return None


def resolve_diff_path_to_component(diff_path: str) -> str | None:
    """
    Longest-prefix match of a diff path to a testray component via the CSV.
    Returns component_name or None. Used to check whether a hunk lives in the
    same component as a failing test.
    """
    candidates = sorted(
        (r for r in load_component_map() if r.get("module_path")),
        key=lambda r: -len(r["module_path"]),
    )
    for row in candidates:
        mp = row["module_path"]
        if mp in diff_path:
            return row.get("testray_component")
    return None


# ---------------------------------------------------------------------------
# Pre-classifier — env/infra errors that don't need reasoning
# ---------------------------------------------------------------------------

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
        r"data-startdate,'11/\d{2}/20\d{2}'",
    ],
    "ENV_SETUP": [
        "TEST_SETUP_ERROR",
    ],
}


def pre_classify(error_message: str, extra_patterns: dict = None) -> str | None:
    """
    Returns a pre_classification string if the error matches a known env/infra
    pattern, "NO_ERROR" if there is no error text, or None when the failure
    still needs a classifier to reason about it.
    """
    if not error_message or pd.isna(error_message):
        return "NO_ERROR"

    patterns = {**DEFAULT_AUTO_CLASSIFY, **(extra_patterns or {})}
    for label, pattern_list in patterns.items():
        for pattern in pattern_list:
            if re.search(pattern, str(error_message), re.IGNORECASE):
                return label
    return None


# ---------------------------------------------------------------------------
# Diff parsing
# ---------------------------------------------------------------------------

def parse_diff_blocks(diff_path: str | Path) -> dict[str, str]:
    """
    Parse a unified git diff into { full_file_path: block_text }.
    Block text includes the `diff --git` header through the last line
    preceding the next file block.
    """
    diff_path = Path(diff_path)
    if not diff_path.exists():
        raise FileNotFoundError(f"Diff file not found: {diff_path}")

    text = diff_path.read_text(encoding="utf-8")
    blocks: dict[str, str] = {}
    current_file = None
    current_lines: list[str] = []

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


def find_diff_blocks(
    test_case: str,
    component_name: str | None,
    matched_diff_files: str | None,
    diff_blocks: dict[str, str],
    max_blocks: int = 3,
    max_lines_per_block: int = 60,
) -> list[tuple[str, str]]:
    """
    Return up to max_blocks (file_path, truncated_hunk_text) tuples most
    relevant to this test failure, tried in order:
      1. matched_diff_files column from extract_relevant_hunks.py
      2. component name tokens against diff file paths
      3. test case name tokens against diff file paths
    """
    matched: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add_block(fp: str) -> None:
        if fp in seen or fp not in diff_blocks:
            return
        hunk_lines = diff_blocks[fp].splitlines()
        if len(hunk_lines) > max_lines_per_block:
            hunk_lines = hunk_lines[:max_lines_per_block] + [
                f"... ({len(hunk_lines) - max_lines_per_block} more lines)"
            ]
        matched.append((fp, "\n".join(hunk_lines)))
        seen.add(fp)

    if matched_diff_files and not pd.isna(matched_diff_files):
        for fragment in str(matched_diff_files).split("|"):
            fragment = fragment.strip().lower()
            if not fragment:
                continue
            for fp in diff_blocks:
                if (fp.lower().endswith(fragment)
                        or fp.lower().split("/")[-1] == fragment.split("/")[-1]):
                    add_block(fp)
                    if len(matched) >= max_blocks:
                        return matched

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


def shorten_test_name(name: str) -> str:
    """Shorten long Java/Playwright test names for prompt readability."""
    if "LocalFile." in name:
        return name.replace("LocalFile.", "")
    if "." in name and ">" not in name:
        parts = name.split(".")
        return ".".join(parts[-2:]) if len(parts) > 2 else name
    return name
