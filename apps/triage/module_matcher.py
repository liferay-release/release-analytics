"""
apps/triage/module_matcher.py

Replaces fuzzy token matching with a proper lookup against
dim_module_component_map and dim_component from the release_analytics DB.

This is the core improvement over the v2/v3 prompt builders which matched
on raw path substrings. Now every matched file resolves to:
  - component_id
  - component_name
  - team_name

Used by:
  - prepare.py          (optional team_name enrichment via dim_component)
  - prompt_helpers.py   (resolving diff file paths to components)

Matching strategy (in order):
  1. Exact module path match against dim_module.module_path_full
  2. Partial path match — diff file path contains module_path_category
  3. Basename token match — fallback for files not in dim_module

The first match wins. Strategy is logged so you can see what fired.
"""

import re
import pandas as pd
from functools import lru_cache
from apps.triage.db import get_rap_conn, query_df


# ---------------------------------------------------------------------------
# Load lookup tables from Release Analytics DB
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def load_module_component_map() -> pd.DataFrame:
    """
    Load dim_module_component_map joined to dim_component and dim_module.
    Cached — only hits the DB once per process.

    Returns DataFrame with columns:
        module_path_full, module_path_category,
        component_id, component_name, team_name
    """
    sql = """
        SELECT
            mcm.module_path,
            dc.component_id,
            dc.component_name,
            dc.team_name
        FROM dim_module_component_map  mcm
        JOIN dim_component             dc  ON dc.component_id = mcm.component_id
        ORDER BY mcm.module_path
    """
    with get_rap_conn() as conn:
        df = query_df(conn, sql)

    # Pre-lowercase for matching
    df["module_path_lower"] = df["module_path"].str.lower()
    return df


# ---------------------------------------------------------------------------
# Core matcher
# ---------------------------------------------------------------------------

class ModuleMatcher:
    """
    Maps diff file paths → (component_id, component_name, team_name).

    Usage:
        matcher = ModuleMatcher()
        result = matcher.match("modules/apps/account/account-service/src/main/java/...")
        # {"component_id": 12, "component_name": "Account", "team_name": "User Management",
        #   "match_strategy": "exact_module_path"}
    """

    def __init__(self):
        self.map_df = load_module_component_map()
        self._build_indexes()

    def _build_indexes(self):
        """Pre-build lookup structures for fast matching."""
        df = self.map_df

        # Index: module_path → row (exact prefix match)
        self._exact_index = {
            row.module_path_lower: row
            for row in df.itertuples()
        }

    def match(self, diff_file_path: str) -> dict | None:
        """
        Match a single diff file path to a component.

        Returns dict with component info + match_strategy, or None if no match.
        """
        path_lower = diff_file_path.lower().strip()

        # Strategy 1: exact module path prefix match
        # dim_module_component_map.module_path looks like "modules/apps/account/account-service"
        # diff path looks like "modules/apps/account/account-service/src/main/java/..."
        for module_path, row in self._exact_index.items():
            if path_lower.startswith(module_path + "/") or path_lower == module_path:
                return self._result(row, "exact_module_path")

        # Strategy 3: basename token match
        # Extract meaningful tokens from the filename and match against component names
        basename = path_lower.split("/")[-1]
        basename_tokens = set(re.split(r"[.\-_]", basename)) - {
            "java", "tsx", "ts", "js", "jsx", "jsp", "test", "impl",
            "local", "service", "util", "helper", "base", "abstract"
        }

        best_score = 0
        best_row = None
        for row in self.map_df.itertuples():
            component_lower = row.component_name.lower()
            module_lower = row.module_path_full_lower.split("/")[-1]
            score = sum(
                1 for token in basename_tokens
                if len(token) > 4 and (token in component_lower or token in module_lower)
            )
            if score > best_score:
                best_score = score
                best_row = row

        if best_score >= 1 and best_row is not None:
            return self._result(best_row, f"token_match(score={best_score})")

        return None

    def match_many(self, diff_file_paths: list[str]) -> pd.DataFrame:
        """
        Match a list of diff file paths.
        Returns DataFrame with one row per path, including unmatched paths.

        Columns: diff_file_path, component_id, component_name, team_name,
                 match_strategy, matched
        """
        rows = []
        for path in diff_file_paths:
            result = self.match(path)
            if result:
                rows.append({"diff_file_path": path, **result, "matched": True})
            else:
                rows.append({
                    "diff_file_path":  path,
                    "component_id":    None,
                    "component_name":  None,
                    "team_name":       None,
                    "match_strategy":  "no_match",
                    "matched":         False,
                })
        return pd.DataFrame(rows)

    @staticmethod
    def _result(row, strategy: str) -> dict:
        return {
            "component_id":   row.component_id,
            "component_name": row.component_name,
            "team_name":      row.team_name,
            "match_strategy": strategy,
        }


# ---------------------------------------------------------------------------
# Enrich test_diff DataFrame with component info
# ---------------------------------------------------------------------------

def enrich_test_diff_with_components(
    test_diff_df: pd.DataFrame,
    matched_diff_files_col: str = "matched_diff_files",
) -> pd.DataFrame:
    """
    Takes the test_diff DataFrame (output of test_diff.sql) and adds
    component_id, component_name, team_name columns by resolving
    matched_diff_files through the module→component map.

    Args:
        test_diff_df:          DataFrame with at least matched_diff_files column
        matched_diff_files_col: Column containing ' | ' separated diff file paths

    Returns:
        Same DataFrame with component columns added.
        If multiple matched files map to different components, takes the first match.
    """
    matcher = ModuleMatcher()

    component_ids   = []
    component_names = []
    team_names      = []
    match_strategies = []

    for _, row in test_diff_df.iterrows():
        files_str = str(row.get(matched_diff_files_col, ""))
        files = [f.strip() for f in files_str.split("|") if f.strip()]

        matched = None
        for f in files:
            matched = matcher.match(f)
            if matched:
                break

        if matched:
            component_ids.append(matched["component_id"])
            component_names.append(matched["component_name"])
            team_names.append(matched["team_name"])
            match_strategies.append(matched["match_strategy"])
        else:
            component_ids.append(None)
            component_names.append(None)
            team_names.append(None)
            match_strategies.append("no_match")

    result = test_diff_df.copy()
    result["component_id"]    = component_ids
    result["component_name"]  = component_names
    result["team_name"]       = team_names
    result["match_strategy"]  = match_strategies

    return result


# ---------------------------------------------------------------------------
# CLI — run standalone to validate matching coverage
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys

    print("Loading module→component map from release_analytics DB...")
    matcher = ModuleMatcher()
    df = matcher.map_df
    print(f"Loaded {len(df)} mappings across "
          f"{df['component_name'].nunique()} components, "
          f"{df['team_name'].nunique()} teams\n")

    # If a file path is passed, match it
    if len(sys.argv) > 1:
        path = sys.argv[1]
        result = matcher.match(path)
        if result:
            print(f"Match found:")
            for k, v in result.items():
                print(f"  {k}: {v}")
        else:
            print(f"No match for: {path}")
    else:
        print("Usage: python module_matcher.py <diff_file_path>")
        print("Example: python module_matcher.py "
              "modules/apps/account/account-service/src/main/java/AccountImpl.java")