# Liferay Release Analytics

Release analytics for Liferay DXP built around two goals:

- **Before release:** Determine where testing effort should be focused.
- **After release:** Learn from what escaped to get better for the next cycle.

---

## Overview

The platform ingests data from four systems — Jira, Testray, SonarQube, and git history — transforms it into a PostgreSQL database, and exports analysis-ready CSVs that power two Looker Studio dashboards. A separate branch risk scoring engine runs locally against a developer's portal checkout.

```
Jira (LPP/LPD)   ──┐
Testray          ──┤
SonarQube        ──┤──► PostgreSQL ──► export_looker.R ──► Google Sheets ──► Looker Studio
git churn CSVs   ──┘                       │
                                           └──► lda_analysis.R ──► topic PNGs + CSVs

liferay-portal checkout ──► evaluate_pr.sh ──► branch risk score
```

---

## Dashboards

### Release Situation Deck
**Question:** *Where should we focus testing for this release?*

| Page | Contents |
|---|---|
| Bug Forecast | Predicted internal defects (LPD) per component. Random Forest model, R²=0.56, validated on most recent mature quarter. LPP shown as historical risk ranking — forecasting not viable at current data volume. |
| Risk Heat Map | Heatmap of risk indicators per component: historical customer bug exposure, historical internal defects, backend churn, frontend churn, Java insertions, TSX insertions. |
| Churn Trends | Code churn by quarter and team — backend vs frontend split. Covers all U and Q releases. |
| Team Scorecard | Per-team: LPP count, LPD count, release blocker count, acceptance test catch rate, release test catch rate. Designed for quadrant analysis: high LPD + low LPP = catching bugs before customers. High LPP + high pass rate = testing the wrong things. |
| Model Notes | LPD model R², MAE, validation quarter, calibration factor. LPP data maturity note. |

### Release Landscape Report
**Question:** *What did we miss and what should we do next?*

| Page | Contents |
|---|---|
| Severity Distribution | LPP vs LPD severity breakdown by quarter. Are we catching high-priority bugs internally before they reach customers? |
| Bug Discovery Timing | How many days before/after customer reports did internal testing find the same issue? Positive = customer found first (bad). |
| Topic Analysis | LDA topic modeling on bug summaries. Which themes dominate customer bugs vs internal bugs? Runs for three periods: all time, 2024 (pre-process change), 2025 (post-process change). |
| Blind Spot Analysis | Terms appearing disproportionately in customer bugs vs internal bugs — signals where internal testing coverage may be misaligned. |
| Complexity & Tech Debt | SonarQube-derived complexity, violation counts, and tech debt hours by component and team. Note: Commerce sub-components share a codebase — metrics are distributed equally across them. |

---

## Data Sources

| Source | What We Pull | How |
|---|---|---|
| **Jira LPP** | Customer-reported bugs (`project = LPP`) from 2024.Q1 onwards. Assigned to quarters via `affectedVersion`. | Jira REST API v3 `/search/jql` |
| **Jira LPD** | Internal bugs (`project = LPD`) from 2023-11-05 onwards. Assigned to quarters via `created_date` → dev window lookup. Release blockers flagged via `labels = "release-blocker"`. | Jira REST API v3 `/search/jql` |
| **Testray** | Test case pass/fail history, bug linkage, catch rates. 150GB backup loaded into local `testray_analysis` PostgreSQL DB. | PostgreSQL → `extract_testray.R` |
| **SonarQube** | Cyclomatic complexity, cognitive complexity, violation counts, tech debt by file. | Local SonarQube analysis → SonarQube API → `extract_sonarqube.R` |
| **Git churn** | Java, TypeScript, JSX, SCSS insertions/deletions per module per quarter and U release. | Pre-computed CSVs in `data/` → `ingest_churn_csv.R` |

---

## Repository Structure

```
liferay-release-analytics/
├── config/
│   ├── config.yml.example          # Copy to config.yml and fill in credentials
│   ├── exclusion-list.txt          # Custom stopwords for LDA topic analysis
│   ├── jira_component_aliases.csv  # Jira component name → dim_component mapping
│   ├── module_component_map.csv    # Legacy module → component fallback
│   ├── module_component_team_map.csv  # Primary module → component → team map
│   ├── release_analytics_db.R      # DB connection helper
│   └── releases.yml                # Release registry (edit to add new releases)
├── data/
│   ├── churn_by_module_Q.csv       # Cumulative churn per Q release
│   └── churn_by_module_U.csv       # Incremental churn per U release
├── db/
│   └── migrations/                 # Schema version history
├── extract/                        # Pull raw data from source systems
│   ├── extract_jira.R
│   ├── extract_testray.R
│   ├── extract_sonarqube.R
│   ├── extract_churn.sh
│   └── extract_git.R               # Automated churn extraction (in development)
├── transform/                      # Clean and shape raw data
│   └── transform_forecast_input.R  # Rolls up LPP/LPD/blockers to component × quarter
├── utils/                          # Pipeline utilities
│   ├── sync_releases.R             # Syncs releases.yml → dim_release
│   ├── load_module_component_map.R # Seeds dim_component and dim_module_component_map
│   ├── ingest_churn_csv.R          # Seeds churn into fact_forecast_input
│   └── export_looker.R             # Exports all CSVs for Looker Studio
├── reports/
│   ├── situation_deck/
│   │   ├── release_situation_deck.Rmd   # R flexdashboard (local prototype)
│   │   └── exports/                     # S01–S07 CSVs → Google Sheets
│   └── release_landscape/
│       ├── lda_analysis.R               # Topic modeling — run separately
│       └── exports/                     # L01–L05 CSVs + topic PNGs → Google Sheets
├── scoring/                        # Branch risk scoring engine (standalone)
│   ├── evaluate_pr.sh
│   └── evaluate_pr.R
└── staging/                        # Intermediate pipeline files (gitignored)
```

---

## Setup

### Prerequisites

- R 4.x with the following packages: `dplyr`, `tidyr`, `readr`, `DBI`, `RPostgres`, `yaml`, `httr`, `jsonlite`, `logger`, `glue`, `MASS`, `randomForest`, `tidytext`, `topicmodels`, `ggplot2`, `flexdashboard`, `DT`, `crosstalk`, `htmltools`
- PostgreSQL 14+
- Access to Jira, SonarQube, and Testray (or a copy of the database — see below)

### Database

The platform uses a PostgreSQL database (`release_analytics`). To set up from scratch:

```bash
psql -U postgres -c "CREATE DATABASE release_analytics;"
psql -U postgres -d release_analytics -f db/schema.sql
psql -U postgres -d release_analytics -f db/migrations/migration_1.3.sql
psql -U postgres -d release_analytics -f db/migrations/migration_1.4.sql
```

**Don't want to run the full pipeline?** You can request a database snapshot from [@nikki-pru]. This gives you a pre-populated database you can query directly or use to render the dashboards without re-running all extracts.


### Database snapshot (recommended for contributors)

Rather than running the full pipeline, you can request a database snapshot from [@nikki-pru] and restore it locally. This gives you a fully populated database in minutes.

**Request:** Reach out to get the latest `release_analytics_YYYYMMDD.dump` file.

**Restore:**

```bash
# 1. Create the database
psql -U postgres -c "CREATE DATABASE release_analytics;"

# 2. Restore from snapshot (custom format)
pg_restore -U postgres -d release_analytics -F c release_analytics_YYYYMMDD.dump

# 3. Verify
psql -U postgres -d release_analytics -c "\dt"
```

If you get a `role does not exist` error during restore:
```bash
pg_restore -U postgres -d release_analytics -F c --no-owner --no-privileges release_analytics_YYYYMMDD.dump
```

**What's included in the snapshot:**
- `dim_release` — 44 releases (U110–U148, 2024.Q1–2026.Q1)
- `dim_component` — 240 components across 15 teams
- `dim_module_component_map` — 779 module → component mappings
- `fact_forecast_input` — churn + bug counts per component × quarter
- `fact_file_complexity` — SonarQube metrics per file
- `fact_test_quality` — Testray bug catch rates per test case
- `dim_file` — 39,413 file registry entries

**What's NOT included:**
- Raw Testray case results (150GB source — available separately on request)
- Your local credentials (`config/config.yml`)

### Config

```bash
cp config/config.yml.example config/config.yml
```

Fill in your credentials:

```yaml
databases:
  release_analytics:
    host: localhost
    port: 5432
    dbname: release_analytics
    user: your_user
    password: your_password

jira:
  base_url: https://liferay.atlassian.net
  email: your_email@liferay.com
  api_token: your_token
  fix_priority_field: customfield_10211
  queries:
    lpp: "project = LPP and ..."
    lpd: "project = LPD AND ..."
    lpd_blockers: "project in (LPD,LPS) AND labels = \"release-blocker\" AND ..."
  dev_windows:
    - quarter: "2024.Q1"
      dev_start: "2023-11-05"
      dev_end: "2024-02-07"
    # ... add quarters as needed
```

---

## Running the Pipeline

Run all scripts from the **project root** (`~/dev/projects/liferay-release-analytics`).

### Full pipeline

```bash
bash run_pipeline.sh
```

Or run steps individually in R from the project root:

```r
source("utils/sync_releases.R")
source("utils/load_module_component_map.R")
source("utils/ingest_churn_csv.R")
source("extract/extract_jira.R")
source("transform/transform_forecast_input.R")
source("utils/export_looker.R")
```

> `run_pipeline.sh` executes all steps in order with logging. See the script for options.

### Topic analysis (run separately, takes ~5 minutes)

```r
source("reports/release_landscape/lda_analysis.R")
```

Outputs land in `reports/release_landscape/exports/topics_2024/`, `topics_2025/`, and `topics_all_time/`.

### Local R dashboard (without Looker)

```r
rmarkdown::render(
  "reports/situation_deck/release_situation_deck.Rmd",
  params = list(forecast_label = "2026.Q1", top_n = 20, exclude_2024 = FALSE)
)
```

Change `forecast_label` to any release in `dim_release` (e.g. `"U147"`, `"2025.Q4"`).

### Looker Studio dashboards

| Dashboard | Link |
|---|---|
| Release Situation Deck | *(link to be added)* |
| Release Landscape Report | *(link to be added)* |

---

## Branch Risk Scoring Engine

A standalone scoring engine that evaluates risk for a specific pull request against a local `liferay-portal` checkout. Independent of the dashboard pipeline.

### What it scores

Five signals with composite weights:

| Signal | Weight | Source |
|---|---|---|
| Code complexity | 28% | SonarQube |
| Churn | 25% | Git diff |
| Defects | 20% | Jira LPD history |
| Test coverage | 15% | Testray |
| Dependencies | 12% | OSGi module graph |

The dependency signal combines blast radius (incoming) and integration depth (outgoing critical connections), blended 60/40.

### Running it

```bash
cd /path/to/liferay-portal
bash /path/to/liferay-release-analytics/scoring/evaluate_pr.sh --branch your-branch-name
```

By default, test execution and compilation are skipped for speed. Opt in explicitly:

Flags:
- `--run-test` — run `ant test-class` on affected modules
- `--run-compile` — run `gw clean deploy` on affected modules

Output: a risk score (0–100) per affected module with signal breakdown.

---

## Key Design Decisions

### Tech Stack

**Why R?** The analytics core — LDA topic modeling, count regression, text mining — maps naturally to R's statistical ecosystem (`topicmodels`, `MASS`, `tidytext`). Outputs go to Looker Studio via CSV so the language is invisible to end users. A Python rewrite would be the right call if the scoring engine needs to be exposed as a microservice or if the automation team needs to maintain the pipeline.

### Bug Forecasting

**Why historical ranking instead of LPP forecasting?** 62% of component×quarter rows have zero LPP bugs. With only 5 mature training quarters available, count models produce unreliable predictions. LPP is shown as a percentile ranking based on historical exposure + current churn. This improves as more mature quarters accumulate.

**Why a maturity filter on LPD training?** Quarters with fewer than 9 months in field have incomplete bug counts — customers haven't had enough time to report issues. Training on immature quarters inverts the churn→bug signal. Only quarters with `months_in_field >= 9` are used for model training.

### LDA / Topic Modeling

**Why separate 2024 and 2025 LDA runs?** A process change in early 2024 makes the two years' bug populations not directly comparable as a training corpus. The 2024 vs 2025 topic divergence is itself a finding worth showing — it documents how the process change shifted what kinds of bugs were being reported and caught.

---

## About This Project

Project conception, analytical direction, methodology, data-sourcing, and domain expertise are by the Liferay Release Team. 
Code generation and implementation is supported with Claude (Anthropic).

For database access or questions about the platform reach out directly to @nikki-pru
