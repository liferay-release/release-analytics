# ops/ — Release Operations Scripts

Day-to-day operational scripts the Release Team runs during a release
cycle. These are **not** part of the scheduled analytics pipeline
(`run_pipeline.sh`) or the dashboard exports — they are one-shot,
interactive, or scheduled-by-humans tools used to drive builds, QA
tasks, bundle validation, and database upgrades.

Most of these scripts were vendored in from the `release-team-scripts`
repo (authored by external contributors) and live under `ops/` so the
Release Team has a single place to run everything. Preserve their
original conventions when editing — they each have their own
dependencies, credential flows, and runtime expectations.

## Layout

| Folder | What's in it |
|---|---|
| [`analyze_build/`](analyze_build/) | Placeholder for future build-analysis tooling. |
| [`bundle_validation/`](bundle_validation/README.md) | Post-release bundle QA — copyright, git hash, OSGi state, startup log checks. |
| [`release_jira/`](release_jira/README.md) | Python automation for the "QA Analysis" and "Build" release parent tasks in Jira. |
| [`tickets_in_release/`](tickets_in_release/README.md) | Extract unique Jira ticket IDs between two git refs and emit ready-to-paste JQL. |
| [`upgrades/`](upgrades/README.md) | Interactive Docker-based MySQL/PostgreSQL/Oracle/SQL Server upgrade harness for customer dump validation. |
| [`utils/`](utils/README.md) | Shared Python package (`liferay_utils`) — Jira + Google Sheets helpers, encrypted credential storage. |

## Conventions

- **Python scripts** in `release_jira/` depend on `ops/utils/liferay_utils/`.
  Install with `pip install -r ops/release_jira/requirements.txt` — this
  pulls in `ops/utils/requirements.txt` transitively via `-r`.
- **Credentials** for Jira live in `~/.jira_user/`, encrypted via
  `pycryptodome` (`manageCredentialsCrypto.py`). First run prompts for
  email + API token; subsequent runs read from disk.
- **Bash scripts** in `upgrades/` and `bundle_validation/` expect to be
  run from a specific working directory — usually the unzipped bundle
  root or the directory containing the DB dump file. Read each
  folder's README before running.
- **Shared ownership:** scripts with external authors (e.g. Brian
  Wulbern on `upgrades/`, David Gutierrez Mesa on `utils/`) carry their
  original headers. Do not strip attribution.

## Relationship to the analytics pipeline

`ops/` is operational; the rest of the repo is analytical. These two
worlds touch only at the config layer — both read `config/config.yml`
when they need Jira or git paths — and are otherwise independent. Run
order, scheduling, and failure recovery for `ops/` scripts is
human-driven; the pipeline in contrast is automated via
`run_pipeline.sh`.
