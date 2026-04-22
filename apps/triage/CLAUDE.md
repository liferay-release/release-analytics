# Triage — Claude Code Workflow

Classifies Testray PASSED→FAILED/BLOCKED/UNTESTED regressions as
BUG / NEEDS_REVIEW / FALSE_POSITIVE and writes results to
`fact_triage_results`. This is the **only** classification path — there
is no Anthropic-API batch pipeline any more; classification always runs
inside a developer's Claude Code session.

Load `.claude/skills/triage.skill` at the start of any session for the
full rubric, schema, and file contracts.

## Session shape — prepare → classify → submit

```
python3 -m apps.triage.prepare from-db --build-a <A> --build-b <B>
      ↓
runs/r_<ts>_<A>_<B>/
   ├── run.yml              (metadata: builds, hashes, routine, classifier)
   ├── diff_list.csv        (one row per non-duplicate case, with
   │                         component/team + pre_classification)
   ├── hunks.txt            (git diff filtered to files matching failing tests)
   ├── git_diff_full.diff   (unfiltered diff — fallback when hunks.txt is too narrow)
   ├── test_fragments.txt   (fragments fed to extract_relevant_hunks)
   ├── prompt.md            (instructions for THIS session)
   └── results.schema.json  (JSON schema for results.json)
      ↓
[YOU read prompt.md, classify, write results.json]
      ↓
python3 -m apps.triage.submit apps/triage/runs/r_<ts>_<A>_<B>
```

Add `--no-upsert` to `submit.py` to validate + print the summary without
writing to `fact_triage_results` / `triage_run_log`. Useful on dev
laptops where the DB is an ephemeral local copy.

## Before starting

1. Confirm the routine ID and build pair (ask if not given). For the
   release PoC pair, baseline is **451312408** (pre-April 17, 2026 5pm
   Pacific — in the dump), target is typically a newer build supplied
   via CSV/API (future input modes) or also in the DB.
2. Check `fact_triage_results` for existing rows on this build pair AND
   the classifier you intend to use. The unique key is
   `(build_id_b, testray_case_id, classifier)` — re-running the same
   classifier on the same pair **overwrites** prior rows, which is fine
   for iteration but not what you want if you're trying to compare runs.
3. Confirm `config/config.yml` has valid DB credentials + a working
   `git.repo_path` pointing at a local liferay-portal checkout.

## The classification loop

`prepare.py` has already done the heavy lifting: pulled the failure set
from `caseresult_analytical`, looked up git hashes from `dim_build`, run
`git diff` with release-noise exclusions, extracted hunks matching test
fragments, and pre-classified obvious env/infra failures.

For each **non-flaky, non-pre-classified** row in `diff_list.csv`:

1. Read `error_message`. Check for classic flake patterns:
   `TEST_SETUP_ERROR`, Selenium/Poshi element-not-found timeouts,
   Playwright visibility timeouts, concurrent-thread assertion errors,
   performance tolerance-exceeded-by-a-few-ms. These are almost always
   FALSE_POSITIVE.
2. Look at `hunks.txt` for files with paths containing tokens from
   `component_name` or `test_case`. The prompt.md already embeds the
   heuristically-matched hunks per failure — start there.
3. Evidence evaluation:
   - Hunk plausibly causes the error → **BUG**, name `culprit_file` =
     the specific path from the diff.
   - Thematically related but indirect → **NEEDS_REVIEW**.
   - No relevant hunk + classic flake pattern → **FALSE_POSITIVE**.
4. If a linked Jira ticket is present in `linked_issues`, read the
   summary — it often confirms BUG vs flake.
5. When the filtered `hunks.txt` looks too narrow (most of the diff was
   thrown away but the error names a module you can't find),
   `grep` through `git_diff_full.diff` before giving up.

Write one object per classified case to `results.json`:

```json
{
  "run_id":     "r_…",
  "classifier": "agent:claude-opus-4-7",
  "results": [
    {
      "testray_case_id": 12345,
      "classification":  "BUG",
      "confidence":      "high",
      "culprit_file":    "modules/apps/.../Foo.java",
      "specific_change": "Foo.java:42 removed null check in bar()",
      "reason":          "…"
    }
  ]
}
```

Pre-classified rows (`BUILD_FAILURE`, `ENV_*`, `NO_ERROR`) and flaky
rows (`known_flaky=True`) **must not** appear in `results.json` —
`submit.py` handles them automatically (auto → `AUTO_CLASSIFIED`; flaky
→ dropped).

## When to stop and ask the user

Do not guess — escalate when:

- Two pieces of evidence contradict each other (hunk suggests BUG, Jira
  says closed-as-env).
- The diff for a single case exceeds ~500 relevant lines (hunk
  extraction may be misconfigured).
- Confidence is low AND the component is outside the top 15 by LPD
  volume AND no Jira is linked.
- Reaching a confident classification would require more than 5
  additional tool calls.

## What not to do

- Do not classify `BUG` without naming a `culprit_file`. `submit.py`
  will reject the row. Downstream `pr_outcomes` training needs the
  labels.
- Do not re-classify a case already in `fact_triage_results` for this
  `(build_id_b, classifier)` without explicit user confirmation — the
  upsert will overwrite prior rows.
- Do not invoke the Anthropic SDK from this repo. Classification lives
  in this session, not in API calls.
- Do not write rows for pre-classified / flaky cases into
  `results.json`.
- Do not assume schema — see the root `CLAUDE.md` and
  `.claude/skills/triage.skill` for authoritative column names and
  join keys.
- Do not reference SonarQube — retired; lizard is the complexity source.

## End of session summary

Report:

- N classified: X BUG / Y NEEDS_REVIEW / Z FALSE_POSITIVE / W AUTO_CLASSIFIED
- N escalated to user
- BUG culprit_file coverage (target ≥85% while in PoC; 100% is the
  long-term rule)
- Disagreement rate vs the `batch:v1` rows on the same build pair, if
  any exist — a quality signal, not an error
- Any surprises about the hunk-extraction coverage (e.g. diff is huge
  and the filter barely narrowed it)

## Classifier values

- `batch:v1` — legacy Anthropic-API pipeline (retired). Historical
  `fact_triage_results` rows from the April 2026 first run carry this
  label.
- `agent:claude-opus-4-7` — current default for in-session Claude Code
  classification. Override via `prepare.py --classifier …` if a different
  model/label is needed (e.g. `agent:claude-sonnet-4-6`).
- `human` — reserved for manual labels / corrections.
- `smoke:*` — throwaway labels for smoke tests; delete rows after.

Disagreement between classifiers is signal, not error — flag systematic
divergence in the session summary.
