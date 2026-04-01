# apps/triage

Triage app for the Liferay Release Analytics Platform.

Answers the question: **"Which test failures in Build B are real bugs introduced since Build A?"**

Part of the RAP three-app structure:
- `apps/scoring/`   — "How risky is this component?"
- `apps/triage/`    — "Which failures are real bugs?" ← this app
- `apps/dashboard/` — "How do we surface it?"

**Status: Live.** First successful end-to-end run completed April 2026.
8 BUGs + 38 NEEDS_REVIEW identified across 590 PASSED→FAILED/BLOCKED failures.

---

## How it works

```
Build A ID + Build B ID (user input via run_triage.sh prompt or --build-a/--build-b flags)
        ↓
test_diff.sql              → PASSED→FAILED/BLOCKED/UNTESTED from testray_working_db
        ↓
git_hash_lookup.sql        → githash_ for both builds from o_22235989312226_build
        ↓
run_triage.sh (git diff)   → full unified diff, source files only, releng noise excluded
        ↓
extract_relevant_hunks.py  → filtered diff — only hunks matching failing test modules
        ↓
module_matcher.py          → diff file paths → component/team via dim_module_component_map
        ↓
prompt_builder.py          → auto-classify env/infra errors + build batched Claude prompts
        ↓
triage_claude.py           → Claude API → BUG / NEEDS_REVIEW / FALSE_POSITIVE per failure
        ↓
store.py                   → upsert into fact_triage_results + log to triage_run_log
```

---

## Files

| File | Purpose |
|---|---|
| `run_triage.sh` | **Entry point** — orchestrates all 5 steps |
| `db.py` | DB connections — release_analytics + testray_working_db |
| `module_matcher.py` | Maps diff file paths → component/team via dim_module_component_map |
| `extract_relevant_hunks.py` | Filters full git diff to only triage-relevant hunks |
| `prompt_builder.py` | Pre-classifies env/infra errors + builds batched Claude prompts |
| `triage_claude.py` | Anthropic API calls, response parsing, batch merging |
| `store.py` | fact_triage_results schema + upsert + triage_run_log |
| `test_diff.sql` | PASSED→FAILED/BLOCKED/UNTESTED query against testray_working_db |
| `git_hash_lookup.sql` | Fetches githash_ for both builds |
| `config_additions.yml` | Reference for what to add to config/config.yml |

---

## Setup

### 1. Virtual environment

```bash
cd ~/dev/projects/liferay-release-analytics
python3 -m venv .venv
source .venv/bin/activate
pip install pandas psycopg2-binary pyyaml anthropic
```

Always activate before running:
```bash
source .venv/bin/activate
```

### 2. Config — add to `config/config.yml`

```yaml
triage:
  anthropic_api_key: sk-ant-...     # or set ANTHROPIC_API_KEY env var
  model: claude-sonnet-4-20250514
  max_tokens_per_batch: 24000
  output_dir: apps/triage/output

git:
  repo_path: ~/dev/projects/liferay-portal
  base_branch: master

databases:
  release_analytics:
    host: localhost
    port: 5432
    dbname: release_analytics
    user: release
    password: ...
  testray:
    host: localhost
    port: 5432
    dbname: testray_working_db
    user: release
    password: ...
```

### 3. Testray DB permissions

```bash
psql -U postgres -h localhost -d testray_working_db -c \
  "GRANT SELECT ON ALL TABLES IN SCHEMA public TO release;"
```

### 4. RAP pipeline must have run first

`dim_module_component_map` and `dim_component` must be populated:
```bash
bash run_pipeline.sh
# or just the load step:
Rscript utils/load_module_component_map.R
```

---

## Usage

```bash
# Full run — prompts for build IDs
bash apps/triage/run_triage.sh

# Pass build IDs directly
bash apps/triage/run_triage.sh --build-a 451312408 --build-b 462975400

# Skip git diff regeneration (use existing output/git_diff_full.diff)
bash apps/triage/run_triage.sh --build-a 451312408 --build-b 462975400 --skip-git

# Dry run — build prompts only, do not call Claude API
bash apps/triage/run_triage.sh --build-a 451312408 --build-b 462975400 --dry-run
```

---

## Output

All outputs written to `apps/triage/output/`:

| File | Contents |
|---|---|
| `test_diff.csv` | Raw PASSED→FAILED/BLOCKED/UNTESTED rows from Testray |
| `test_fragments.txt` | Module/class tokens derived from test names for hunk extraction |
| `git_diff_full.diff` | Full filtered unified diff between the two builds |
| `triage_diff_precise.md` | Filtered diff — only hunks relevant to failing tests |
| `batch_N.md` | Claude prompt for each batch (dry-run mode) |
| `triage_results.csv` | Final classifications — one row per failure |

Persisted in `release_analytics`:

| Table | Contents |
|---|---|
| `fact_triage_results` | One row per (build_id_b, testray_case_id) — upserted on re-run |
| `triage_run_log` | One row per run — token counts, classification totals, duration |

---

## Classifications

| Classification | Meaning |
|---|---|
| `BUG` | Error clearly caused by a specific change in the diff |
| `NEEDS_REVIEW` | Plausible connection but indirect — needs human judgment |
| `FALSE_POSITIVE` | Failure unrelated to diff — env/infra/timing/test isolation |
| `AUTO_CLASSIFIED` | Pre-filtered before Claude — BUILD_FAILURE, ENV_CHROME, ENV_DATE, etc. |

---

## Cost

~$1.00 per run (590 failures, 8 batches, ~250k tokens in / 18k out at Sonnet 4 pricing).
Weekly cadence ≈ $4/month.

---

## Git diff exclusions

The following are excluded from the diff to reduce noise and token cost:

```
artifact.properties, .releng/**, liferay-releng.changelog, app.changelog,
app.properties, bnd.bnd, packageinfo, *.xml, *.properties, *.yml, *.yaml,
*.tf, *.sh, *.scss, *.css, *.gradle, package.json, *.json, cloud/**
```

---

## Backlog

- **Jira ticket auto-creation** (`create_jira_tickets.py`): Read `fact_triage_results`
  for a build, filter to BUG + NEEDS_REVIEW where `linked_issues` is null, create LPD
  tickets via Jira REST API, write ticket keys back to `linked_issues`.
  Decisions pending: priority mapping, assignee strategy, dry-run mode.
  Run as separate manual step — not auto-triggered from `run_triage.sh`.

- **RAP pipeline logging**: Improve `load_testray` step logging in `run_pipeline.sh`
  so it emits progress milestones instead of appearing to hang.

- **Looker Studio Build Triage page**: Surface `fact_triage_results` as a new page
  in the Situation Deck — BUG/NEEDS_REVIEW summary bar, root cause cluster table,
  full filterable triage table. Feeds from new S08 export CSV.

- **`fact_triage_results` → composite score**: BUG count per component per build
  as a 6th signal in `fact_forecast_input` (pre-release confirmed defects).

- **`fact_triage_results` → `pr_outcomes`**: Each confirmed BUG row has
  testray_case_id + githash + likely_cause = labeled outcome for NN training.