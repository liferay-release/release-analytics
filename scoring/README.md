# Branch Risk Scoring Engine

Evaluates the risk of a local branch against a base branch (master) using five signals drawn from the `release_analytics` database. Runs locally against a `liferay-portal` checkout. Independent of the dashboard pipeline — the only hard dependencies are a populated database and a valid `config/config.yml`.

---

## Usage

Run from within the `liferay-portal` repository root:

```bash
bash /path/to/liferay-release-analytics/scoring/evaluate_pr.sh <branch-name>
```

By default, test execution and compilation are skipped for speed. Opt in explicitly:

```bash
# Run ModulesStructureTest before scoring
bash evaluate_pr.sh <branch-name> --run-test

# Run gw clean deploy on affected modules before scoring
bash evaluate_pr.sh <branch-name> --run-compile

# Both
bash evaluate_pr.sh <branch-name> --run-test --run-compile
```

Optional positional arguments:

```bash
bash evaluate_pr.sh <branch-name> [base-branch] [author]
# base-branch defaults to master
# author defaults to git config user.name
```

---

## What It Does

### Step 1 — ModulesStructureTest *(opt-in)*
Runs `ant test-class -Dtest.class=ModulesStructureTest` in `portal-kernel`. Aborts if structural failures are found. Skipped by default; enable with `--run-test`.

### Step 2 — gw clean deploy *(opt-in)*
Resolves affected Gradle module roots from the changed file list and runs `gw clean deploy` on each. Aborts if any module fails to deploy. Skipped by default; enable with `--run-compile`.

### Step 3 — Risk scoring
Passes changed files to `evaluate_pr.R`, which queries the `release_analytics` database and prints a formatted risk report to the terminal.

---

## Output

```
═══════════════════════════════════════════════════════════════════════════════
  RISK ASSESSMENT — PR-171673
═══════════════════════════════════════════════════════════════════════════════
  Overall Risk:   CRITICAL (0.9984)
  Avg File Risk:  0.2896
  Files Changed:  369
    Scored:       184
    Test files:   135 (see below)
    New files:    185 (no history)
```

The report has six sections:

| Section | Contents |
|---|---|
| **Risk Summary** | Overall tier (CRITICAL / HIGH / MEDIUM / LOW) based on highest-scoring file, max composite score, average file risk, scored/test/new file counts, tier distribution |
| **Top Risk Files** | Up to 10 CRITICAL and HIGH files with per-signal score breakdown |
| **Dependency Risk** | Blast radius (modules that depend on changed code — direct, transitive, total) and integration depth (how deeply changed modules import critical infrastructure) |
| **Suggested Tests** | Top test cases to run, ranked by signal score, up to 3 per affected component |
| **Test Files Changed** | Test files detected in the diff, listed separately (excluded from risk scoring) |
| **New Files** | Files added in this PR with no prior history in `dim_file` — not scored |

Each eval run is written to `pr_evaluation` (branch, base, author, timestamp) and `pr_file_change` (per-file risk score, tier, change type) in the database for historical reference.

---

## Risk Signals

Composite scores are assembled by `transform/transform_scores.R` and stored in `fact_file_risk_score`. The scoring engine reads pre-computed scores — it does not recompute them at eval time.

### Signal weights

Weights are configured in `config/config.yml` under `scoring.weights` and can be adjusted without code changes. Current defaults:

| Signal | Weight | Granularity | Source |
|---|---|---|---|
| Complexity | 28% | File | SonarQube — blended cyclomatic (35%) + cognitive (40%) + violations (25%) |
| Churn | 25% | File | Git — commit frequency + author turnover, multi-window decay |
| Defect | 20% | Module → File | Jira LPD — bug count + severity-weighted score, multi-window decay |
| Test | 15% | Module → File | Testray — failure rate (70%) + co-failure score (30%) |
| Dependency | 12% | File | OSGi module graph — blast radius (60%) blended with integration depth (40%) |

Signals with no data default to 0 (conservative — missing data will not inflate a score).

### Multi-window decay

Churn, defect, and test signals use three time windows with decaying weights to balance recency against signal stability:

| Window | Weight |
|---|---|
| 30 days | 50% |
| 90 days | 30% |
| 365 days | 20% |

### Amplifier

If 2 or more signals are simultaneously above 0.50, an amplifier is applied to the composite score to reflect convergent risk:

| Signals above 0.50 | Amplifier |
|---|---|
| 4+ | 1.25× |
| 3 | 1.15× |
| 2 | 1.05× |
| 0–1 | 1.00× |

The final composite is capped at 1.0.

### Tier thresholds

Overall PR tier is based on the **highest-scoring individual file** in the PR:

| Tier | Composite score |
|---|---|
| CRITICAL | ≥ 0.75 |
| HIGH | ≥ 0.50 |
| MEDIUM | ≥ 0.25 |
| LOW | < 0.25 |

---

## Suggested Tests

Test recommendations are pulled from `fact_test_quality` (populated by `transform/transform_cofailure.R`). Each test case is scored on two metrics:

**`investigation_rate`** — proportion of failing builds where the test had a linked Jira ticket. A high rate means failures were notable enough to generate investigation work. Note: Jira links are not exclusively confirmed bugs — they include investigation tickets that may resolve to fixes, test updates, or flaky classifications. This is a directional signal, not a precise bug catch rate.

**`signal_score`** — composite of `investigation_rate` (70%) and normalized ticket volume (30%), dampened by a square-root volume penalty:

```
signal_score = (investigation_rate × 0.70 + normalized_links × 0.30)
             × (1 − √total_fail_builds / √max_fail_builds)
```

The volume penalty discounts tests that fail hundreds of times per year regardless of ticket linkage, since chronic high-volume failures are more likely to be infrastructure noise than meaningful regression signal.

Only tests with `signal_score >= 0.10` are shown. Results are capped at 3 per affected component and interleaved by score so that all touched areas get representation rather than one dominant component monopolizing the list.

---

## Scoring Version

The `scoring_version` key in `config/config.yml` controls which rows in `fact_file_risk_score` the engine reads. It must match the version used when `transform_scores.R` was last run.

```yaml
scoring:
  scoring_version: "1.0"
  weight_source: manual_v1
  weights:
    complexity: 0.28
    churn:      0.25
    defect:     0.20
    test:       0.15
    dependency: 0.12
```

If scores appear stale or signal weights have changed, re-run `transform/transform_scores.R` and bump `scoring_version`. The upsert uses `(file_id, scoring_version)` as the conflict key, so prior versions are preserved alongside the new one.

---

## Keeping Scores Current

The scoring engine reads pre-computed data — it does not pull live signals at eval time. Scores reflect the state of the database at the last pipeline run. For the most accurate results, ensure the upstream transforms have been run recently:

```r
source("transform/transform_churn.R")        # git churn → fact_file_churn
source("transform/transform_defects.R")      # Jira LPD → fact_defect_history
source("transform/transform_test_risk.R")    # Testray → fact_test_failure
source("transform/transform_cofailure.R")    # Testray → fact_test_quality
source("transform/transform_complexity.R")   # SonarQube → fact_file_complexity
source("transform/transform_dependencies.R") # OSGi graph → fact_file_dependencies
source("transform/transform_scores.R")       # Assemble → fact_file_risk_score
```

---

## Caveats

**New files** — files added in the PR have no entry in `dim_file` and receive no score. They are listed separately in the NEW FILES section.

**Unscored files** — files that exist in `dim_file` but lack a score for the current `scoring_version` (e.g. added between pipeline runs) appear as unscored. Re-running `transform_scores.R` will pick them up.

**Portal core modules** — `portal-impl`, `portal-kernel`, and `portal-web` are assigned a synthetic `dependency_score = 0.90` and excluded from the component → test recommendation lookup, since their component mappings are too broad to produce meaningful suggestions.

**Test file classification** — files matching `Test.java`, `TestCase.java`, `.spec.ts`, `.test.js`, `.test.ts`, `/test/`, or `/testIntegration/` are classified as test files and excluded from risk scoring. They are listed separately in the TEST FILES CHANGED section.

---

## Files

| File | Purpose |
|---|---|
| `evaluate_pr.sh` | Orchestrator — validates inputs, optionally runs test/compile steps, collects changed files via `git diff`, calls `evaluate_pr.R` |
| `evaluate_pr.R` | Scoring engine — queries `release_analytics`, computes PR-level summary, prints formatted report, writes to `pr_evaluation` and `pr_file_change` |

---

## Dependencies

- A populated `release_analytics` PostgreSQL database (see root README for setup)
- `config/config.yml` with valid `databases.release_analytics` credentials and `scoring.scoring_version`
- R packages: `dplyr`, `DBI`, `RPostgres`, `yaml`, `glue`
- Script must be invoked from within a `liferay-portal` git repository
- `gh` CLI (optional) — resolves a PR URL from the branch name if available; silently skipped if not installed

---

## About This Project

This risk scoring engine is a standalone component of the Release Analytics Platform, applying the same signals and data that powers the Release dashboards.

Project conception, analytical direction, methodology, data-sourcing, and domain expertise are by the Liferay Release Team. 
Code generation and implementation is supported with Claude (Anthropic).

For database access or questions about the platform reach out directly to @nikki-pru