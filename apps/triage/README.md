# apps/triage

Triage app for the Liferay Release Analytics Platform.

Answers the question: **"Which test failures in Build B are real bugs
introduced since Build A?"**

Part of the three-app structure:

- `apps/scoring/`   — "How risky is this component?"
- `apps/triage/`    — "Which failures are real bugs?" ← this app
- `apps/dashboard/` — "How do we surface it?"

**Status: PoC.** First successful end-to-end run completed April 2026
against Routine 82964 (Release signal). Classification now happens inside
the developer's own Claude Code session — the `anthropic` SDK and the
old batch pipeline are retired.

---

## How it works

```
prepare.py from-db  →  runs/r_<id>/prompt.md + diff_list.csv + hunks.txt
                                 + git_diff_full.diff + results.schema.json
                                 + run.yml
                          ↓
            [Dev's Claude Code session reads prompt.md, classifies,
             writes results.json — no API call from this repo]
                          ↓
submit.py           →  validates results.json against the schema,
                          upserts into fact_triage_results + triage_run_log
                          (or --no-upsert for inspection / laptop-only devs)
```

Inside `prepare.py`:

```
test_diff.sql              → PASSED→FAILED/BLOCKED/UNTESTED from testray_analytical
        ↓
dim_build lookup           → git_hash + routine_id per build
        ↓
git diff (liferay-portal)  → full unified diff, releng/XML/json/etc excluded
        ↓
extract_relevant_hunks.py  → filtered diff — only hunks matching failing test modules
        ↓
prompt_helpers.pre_classify→ env/infra errors flagged as pre_classification
        ↓
prompt_helpers.find_diff_blocks + prompt body assembly → prompt.md per failure
```

`submit.py` validates `results.json`, merges classifier output with
auto-classified + flaky rows, and upserts under the classifier label from
`run.yml` / `results.json`.

---

## Files

| File | Purpose |
|---|---|
| `prepare.py` | **Entry point 1** — build the run bundle (`from-db` mode; `from-csv`/`from-api` are step 2) |
| `submit.py` | **Entry point 2** — validate `results.json`, upsert into DB, or `--no-upsert` |
| `prompt_helpers.py` | Pre-classification patterns, diff parsing, test→hunk matching, name shortening |
| `db.py` | DB connections — release_analytics + testray_analytical |
| `module_matcher.py` | Maps diff file paths → component/team via `dim_module_component_map` |
| `extract_relevant_hunks.py` | Filters full git diff to only triage-relevant hunks |
| `store.py` | `fact_triage_results` + `triage_run_log` schema + classifier-aware upsert |
| `test_diff.sql` | PASSED→FAILED/BLOCKED/UNTESTED query against `testray_analytical` |
| `git_hash_lookup.sql` | Fetches git_hash + routine_id for both builds from `dim_build` |
| `config_additions.yml` | Reference for what to add to `config/config.yml` |

---

## Setup

### 1. Virtual environment

```bash
cd ~/dev/projects/liferay-release-analytics
python3 -m venv .venv
source .venv/bin/activate
pip install -r apps/triage/requirements.txt
```

Always activate before running:

```bash
source .venv/bin/activate
```

### 2. Config — add to `config/config.yml`

```yaml
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
    dbname: testray_analytical
    user: release
    password: ...

# Optional — pattern extensions for prepare.py pre-classification
triage:
  auto_classify_patterns:
    ENV_DEPENDENCY:
      - "your-extra-pattern-here"
```

No Anthropic API key is needed or used. Classification happens in the
developer's own Claude Code session.

### 3. Testray DB permissions (if your local DB was bootstrapped fresh)

```bash
psql -U postgres -h localhost -d testray_analytical -c \
  "GRANT SELECT ON ALL TABLES IN SCHEMA public TO release;"
```

### 4. Release Analytics migrations applied

`fact_triage_results` must be at schema version ≥ 1.9 (adds the
`classifier` column). Applied automatically if you run all migrations in
`db/migrations/` against a fresh `release_analytics` DB.

---

## Usage

```bash
# 1. Prepare the run bundle
python3 -m apps.triage.prepare from-db \
    --build-a 451312408 \
    --build-b 462975400

# → apps/triage/runs/r_<ts>_451312408_462975400/  (bundle written)

# 2. Classify inside your own Claude Code session
#    Open the bundle's prompt.md, read the failures, write results.json
#    in the same directory against results.schema.json.

# 3. Submit
python3 -m apps.triage.submit apps/triage/runs/r_<ts>_451312408_462975400

# Or inspect without writing to DB
python3 -m apps.triage.submit apps/triage/runs/r_<ts>_451312408_462975400 --no-upsert
```

`prepare.py` also takes `--classifier <label>` to override the default
(`agent:claude-opus-4-7`). The label is written to `run.yml` and then
into `fact_triage_results.classifier`.

---

## Output

In `apps/triage/runs/r_<id>/` (gitignored):

| File | Contents |
|---|---|
| `run.yml` | Build IDs + hashes + routine + classifier + counts |
| `diff_list.csv` | One row per non-duplicate case with component/team + `pre_classification` |
| `git_diff_full.diff` | Unfiltered git diff between the two hashes |
| `hunks.txt` | Diff filtered to hunks matching failing test modules |
| `test_fragments.txt` | Fragments fed into `extract_relevant_hunks.py` |
| `prompt.md` | Instructions for the classification session |
| `results.schema.json` | JSON schema for `results.json` |
| `results.json` | **Written by the dev's Claude Code session** |

Persisted in `release_analytics`:

| Table | Contents |
|---|---|
| `fact_triage_results` | One row per `(build_id_b, testray_case_id, classifier)` — upserted on re-run |
| `triage_run_log` | One row per `submit.py` invocation — classification totals, duration, notes |

---

## Classifications

| Classification | Meaning |
|---|---|
| `BUG`             | Error plausibly caused by a specific change in the diff. MUST name a `culprit_file`. |
| `NEEDS_REVIEW`    | Plausible connection but indirect — needs human judgment. Not a default. |
| `FALSE_POSITIVE`  | Failure unrelated to diff — env/infra/timing/test isolation. |
| `AUTO_CLASSIFIED` | Pre-filtered by `prepare.py` — BUILD_FAILURE, ENV_CHROME, ENV_DATE, ENV_DEPENDENCY, ENV_SETUP, NO_ERROR. |

---

## Classifier column — head-to-head comparison

`fact_triage_results` is keyed on `(build_id_b, testray_case_id,
classifier)`. Independent runs can be compared on the same build pair:

```sql
SELECT classifier, classification, COUNT(*)
FROM fact_triage_results
WHERE build_id_b = 462975400
GROUP BY classifier, classification
ORDER BY classifier, classification;
```

Existing labels:

- `batch:v1` — legacy Anthropic-API pipeline, 365 rows on the Routine
  82964 historical pair (8 BUG / 38 NEEDS_REVIEW / 276 FALSE_POSITIVE /
  43 AUTO_CLASSIFIED).
- `agent:claude-opus-4-7` — current default for in-session Claude Code
  classification.
- `human` — reserved for manual overrides.
- `smoke:*` — use for one-off round-trip tests, then delete.

---

## Git diff exclusions

The following are excluded from the diff to reduce noise:

```
artifact.properties, .releng/**, liferay-releng.changelog, app.changelog,
app.properties, bnd.bnd, packageinfo, *.xml, *.properties, *.yml, *.yaml,
*.tf, *.sh, *.scss, *.css, *.gradle, package.json, *.json, cloud/**
```

---

## Backlog

- **CSV and API input modes** (`prepare.py from-csv`, `from-api`). Notable
  CSV gotcha: the Testray CSV export has `Case Name`, `Component`, `Team`,
  and a `Case Result URL` containing a `case_result_id`, but no
  `case_id`, `build_id`, `git_hash`, or `module_path`. Matching rule
  between target-CSV rows and baseline-DB rows needs to be formalized
  (likely `(Case Name, Component)` when `case_result_id` lookup is not
  possible).
- **Jira ticket auto-creation** (`create_jira_tickets.py`): Read
  `fact_triage_results` for a build, filter to BUG + NEEDS_REVIEW where
  `linked_issues` is null, create LPD tickets via Jira REST, write
  ticket keys back. Run as a separate manual step.
- **Pipeline logging**: Improve `load_testray` step logging in
  `run_pipeline.sh` so it emits progress milestones.
- **Looker Studio Build Triage page**: Surface `fact_triage_results` as
  a new page in the Situation Deck.
- **`fact_triage_results` → composite score**: BUG count per component
  per build as a 6th signal in `fact_forecast_input`.
- **`fact_triage_results` → `pr_outcomes`**: Each confirmed BUG row
  has `testray_case_id` + `git_hash_b` + `culprit_file` = labeled outcome
  for future NN training.
