"""
apps/triage/triage_claude.py

Sends batched prompts to the Anthropic API and parses the triage table
responses into a unified DataFrame.

Pipeline position:
    prompt_builder.py → [this file] → fact_triage_results (via run_triage.sh)

Responsibilities:
  - Send each TriageBatch to Claude
  - Parse the markdown table response
  - Merge all batch results into one DataFrame
  - Attach auto-classified rows (BUILD_FAILURE, ENV_*, etc.)
  - Log token usage per batch for cost tracking
  - Retry on transient API errors

Output DataFrame columns:
    failure_idx, test_case, testray_case_id, component_name, team_name,
    status_a, status_b, known_flaky, linked_issues, error_message,
    pre_classification, classification, specific_change, reason,
    tokens_in, tokens_out, batch_number
"""

import re
import time
import yaml
import anthropic
import pandas as pd
from pathlib import Path
from dataclasses import dataclass

from apps.triage.prompt_builder import TriageBatch


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_triage_config() -> dict:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                return yaml.safe_load(f).get("triage", {})
    return {}


# ---------------------------------------------------------------------------
# Anthropic client
# ---------------------------------------------------------------------------

def _get_client(cfg: dict) -> anthropic.Anthropic:
    """
    Build Anthropic client. API key priority:
      1. config.yml triage.anthropic_api_key
      2. ANTHROPIC_API_KEY environment variable (standard SDK behaviour)
    """
    api_key = cfg.get("anthropic_api_key")
    if api_key and api_key != "your_anthropic_api_key":
        return anthropic.Anthropic(api_key=api_key)
    return anthropic.Anthropic()   # falls back to ANTHROPIC_API_KEY env var


# ---------------------------------------------------------------------------
# Response parser
# ---------------------------------------------------------------------------

# Matches a markdown table row with 6 pipe-separated cells
# | # | Test Case | Component | Classification | Specific Change | Reason |
_TABLE_ROW_RE = re.compile(
    r"^\|\s*(\d+)\s*\|"          # col 1: failure number
    r"\s*`?(.+?)`?\s*\|"         # col 2: test case
    r"\s*(.+?)\s*\|"             # col 3: component
    r"\s*\*{0,2}(\w+)\*{0,2}\s*\|"  # col 4: classification (may be **BUG**)
    r"\s*`?(.+?)`?\s*\|"         # col 5: specific change
    r"\s*(.+?)\s*\|$"            # col 6: reason
)

# Separator row pattern  |---|---|...|
_SEPARATOR_RE = re.compile(r"^\|[-| :]+\|$")

VALID_CLASSIFICATIONS = {"BUG", "NEEDS_REVIEW", "FALSE_POSITIVE"}


def parse_triage_table(response_text: str) -> list[dict]:
    """
    Extract triage rows from a Claude markdown table response.

    Handles:
      - **BUG** / BUG / `BUG` formatting variants
      - Rows that wrap across lines (skipped — Claude rarely does this)
      - Missing table (returns empty list with a warning)

    Returns list of dicts with keys:
        failure_idx, test_case, component, classification,
        specific_change, reason, parse_ok
    """
    rows = []

    for line in response_text.splitlines():
        line = line.strip()

        # Skip header and separator rows
        if not line.startswith("|") or _SEPARATOR_RE.match(line):
            continue

        m = _TABLE_ROW_RE.match(line)
        if not m:
            continue

        failure_idx    = int(m.group(1))
        test_case      = m.group(2).strip().strip("`")
        component      = m.group(3).strip()
        classification = m.group(4).strip().upper()
        specific_change = m.group(5).strip().strip("`")
        reason         = m.group(6).strip()

        # Normalise classification
        if classification not in VALID_CLASSIFICATIONS:
            # Try partial match e.g. "NEEDS" → "NEEDS_REVIEW"
            for valid in VALID_CLASSIFICATIONS:
                if classification in valid or valid.startswith(classification):
                    classification = valid
                    break
            else:
                classification = "NEEDS_REVIEW"   # safe fallback

        rows.append({
            "failure_idx":     failure_idx,
            "test_case":       test_case,
            "component":       component,
            "classification":  classification,
            "specific_change": specific_change,
            "reason":          reason,
            "parse_ok":        True,
        })

    if not rows:
        print("  ⚠  No table rows parsed from response — check raw output")

    return rows


# ---------------------------------------------------------------------------
# Single batch call
# ---------------------------------------------------------------------------

@dataclass
class BatchResult:
    batch_number:  int
    parsed_rows:   list[dict]
    tokens_in:     int
    tokens_out:    int
    raw_response:  str
    error:         str | None = None


def call_claude(
    batch: TriageBatch,
    client: anthropic.Anthropic,
    cfg: dict,
    retries: int = 2,
    retry_delay: float = 5.0,
) -> BatchResult:
    """
    Send one batch prompt to Claude and return a BatchResult.

    Retries on transient errors (rate limit, overload).
    On persistent failure, returns a BatchResult with error set and
    empty parsed_rows so the pipeline can continue.
    """
    model      = cfg.get("model", "claude-sonnet-4-20250514")
    max_tokens = 4096   # output only — triage tables are compact

    print(f"  Batch {batch.batch_number}: sending "
          f"{len(batch.rows)} failures (~{len(batch.prompt)//4} tokens in)...")

    last_error = None
    for attempt in range(retries + 1):
        try:
            response = client.messages.create(
                model=model,
                max_tokens=max_tokens,
                messages=[{"role": "user", "content": batch.prompt}],
            )

            raw = response.content[0].text
            tokens_in  = response.usage.input_tokens
            tokens_out = response.usage.output_tokens

            parsed = parse_triage_table(raw)
            print(f"  Batch {batch.batch_number}: "
                  f"{len(parsed)} rows parsed, "
                  f"{tokens_in} in / {tokens_out} out tokens")

            return BatchResult(
                batch_number=batch.batch_number,
                parsed_rows=parsed,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                raw_response=raw,
            )

        except anthropic.RateLimitError as e:
            wait = retry_delay * (attempt + 1) * 2
            print(f"  Rate limit hit — waiting {wait}s before retry {attempt+1}/{retries}")
            time.sleep(wait)
            last_error = str(e)

        except anthropic.APIStatusError as e:
            if e.status_code in (529, 503):   # overloaded
                wait = retry_delay * (attempt + 1)
                print(f"  API overloaded ({e.status_code}) — waiting {wait}s")
                time.sleep(wait)
                last_error = str(e)
            else:
                last_error = str(e)
                break

        except Exception as e:
            last_error = str(e)
            break

    print(f"  ⚠  Batch {batch.batch_number} failed after {retries+1} attempts: {last_error}")
    return BatchResult(
        batch_number=batch.batch_number,
        parsed_rows=[],
        tokens_in=0,
        tokens_out=0,
        raw_response="",
        error=last_error,
    )


# ---------------------------------------------------------------------------
# Merge helper — join Claude output back to source rows
# ---------------------------------------------------------------------------

def merge_results(
    batches: list[TriageBatch],
    results: list[BatchResult],
) -> pd.DataFrame:
    """
    Join parsed Claude table rows back to the original source rows
    from the TriageBatch, producing one unified DataFrame.

    Matching is done by failure_idx (global sequential number assigned
    in prompt_builder.py). If a row wasn't parsed (Claude missed it),
    it gets classification=NEEDS_REVIEW with a note.
    """
    # Build a lookup: failure_idx → source row
    idx_to_row = {}
    global_idx = 1
    for batch in batches:
        for row in batch.rows:
            idx_to_row[global_idx] = {"batch_number": batch.batch_number, **row}
            global_idx += 1

    # Build a lookup: failure_idx → Claude output
    idx_to_claude = {}
    for result in results:
        for parsed in result.parsed_rows:
            idx_to_claude[parsed["failure_idx"]] = {
                **parsed,
                "tokens_in":  result.tokens_in,
                "tokens_out": result.tokens_out,
                "api_error":  result.error,
            }

    # Merge
    merged = []
    for idx, source in idx_to_row.items():
        claude = idx_to_claude.get(idx, {})
        merged.append({
            "failure_idx":       idx,
            "batch_number":      source.get("batch_number"),
            "testray_case_id":   source.get("testray_case_id"),
            "test_case":         source.get("test_case"),
            "component_name":    source.get("component_name") or claude.get("component"),
            "team_name":         source.get("team_name"),
            "status_a":          source.get("status_a"),
            "status_b":          source.get("status_b"),
            "known_flaky":       source.get("known_flaky", False),
            "linked_issues":     source.get("linked_issues"),
            "error_message":     source.get("error_message"),
            "match_strategy":    source.get("match_strategy"),
            "pre_classification": source.get("pre_classification"),
            "classification":    claude.get("classification", "NEEDS_REVIEW"),
            "specific_change":   claude.get("specific_change"),
            "reason":            claude.get("reason",
                                            "Not parsed from Claude response" if not claude else None),
            "tokens_in":         claude.get("tokens_in", 0),
            "tokens_out":        claude.get("tokens_out", 0),
            "api_error":         claude.get("api_error"),
        })

    # Append auto-classified rows from batch 0
    if batches and batches[0].auto_classified:
        for row in batches[0].auto_classified:
            merged.append({
                "failure_idx":       None,
                "batch_number":      None,
                "testray_case_id":   row.get("testray_case_id"),
                "test_case":         row.get("test_case"),
                "component_name":    row.get("component_name"),
                "team_name":         row.get("team_name"),
                "status_a":          row.get("status_a"),
                "status_b":          row.get("status_b"),
                "known_flaky":       row.get("known_flaky", False),
                "linked_issues":     row.get("linked_issues"),
                "error_message":     row.get("error_message"),
                "match_strategy":    row.get("match_strategy"),
                "pre_classification": row.get("pre_classification"),
                "classification":    "AUTO_CLASSIFIED",
                "specific_change":   None,
                "reason":            f"Auto-classified: {row.get('pre_classification')}",
                "tokens_in":         0,
                "tokens_out":        0,
                "api_error":         None,
            })

    return pd.DataFrame(merged)


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def run_triage(
    batches: list[TriageBatch],
    delay_between_batches: float = 2.0,
) -> pd.DataFrame:
    """
    Run the full triage pipeline: send all batches to Claude,
    merge results, return unified DataFrame.

    Args:
        batches:                   Output of prompt_builder.build_batches()
        delay_between_batches:     Seconds to wait between API calls

    Returns:
        DataFrame ready to upsert into fact_triage_results
    """
    cfg    = _load_triage_config()
    client = _get_client(cfg)

    total_failures = sum(len(b.rows) for b in batches)
    total_auto     = len(batches[0].auto_classified) if batches else 0
    print(f"\n{'='*50}")
    print(f"Starting triage run")
    print(f"  Batches:          {len(batches)}")
    print(f"  Failures to send: {total_failures}")
    print(f"  Auto-classified:  {total_auto}")
    print(f"  Model:            {cfg.get('model', 'claude-sonnet-4-20250514')}")
    print(f"{'='*50}\n")

    results = []
    for i, batch in enumerate(batches):
        result = call_claude(batch, client, cfg)
        results.append(result)

        # Delay between batches to respect rate limits
        if i < len(batches) - 1:
            time.sleep(delay_between_batches)

    # Summary
    total_in  = sum(r.tokens_in  for r in results)
    total_out = sum(r.tokens_out for r in results)
    failed    = sum(1 for r in results if r.error)
    print(f"\n{'='*50}")
    print(f"Triage complete")
    print(f"  Total tokens in:  {total_in:,}")
    print(f"  Total tokens out: {total_out:,}")
    print(f"  Failed batches:   {failed}")
    print(f"{'='*50}\n")

    df = merge_results(batches, results)

    # Classification summary
    print("Classification summary:")
    for cls, cnt in df["classification"].value_counts().items():
        print(f"  {cls:<20} {cnt}")

    return df


# ---------------------------------------------------------------------------
# CLI — run against saved batch files
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys
    import json
    from apps.triage.prompt_builder import build_batches

    print("triage_claude.py — use run_triage.sh to invoke the full pipeline")
    print("For direct testing, pass a saved batch .md file:")
    print("  python triage_claude.py apps/triage/output/batch_1.md")

    if len(sys.argv) > 1:
        batch_path = Path(sys.argv[1])
        if not batch_path.exists():
            print(f"File not found: {batch_path}")
            sys.exit(1)

        # Build a minimal mock batch from the file
        mock_batch = TriageBatch(
            batch_number=1,
            build_id_a=0,
            build_id_b=0,
            git_hash_a="",
            git_hash_b="",
            failure_indices=[],
            prompt=batch_path.read_text(encoding="utf-8"),
            rows=[],
        )

        cfg    = _load_triage_config()
        client = _get_client(cfg)
        result = call_claude(mock_batch, client, cfg)

        print(f"\nParsed {len(result.parsed_rows)} rows:")
        for row in result.parsed_rows[:5]:
            print(f"  #{row['failure_idx']} {row['classification']}: {row['reason'][:80]}")

        # Save raw response
        out = batch_path.with_suffix(".response.md")
        out.write_text(result.raw_response, encoding="utf-8")
        print(f"\nRaw response saved to: {out}")