# testray_analytical — Setup & Sharing Guide

A lightweight, denormalized PostgreSQL database containing Testray case results
across 4 projects, ready for sharing and analytical queries.

## Why this exists

- Raw `testray_working_db` is 150GB — too big to share easily
- Raw tables use the `o_22235989312226_*` object schema — not intuitive
- We need multi-project support (135537960, 3020904, 456316917, 35392)
- We want inline names — no joins needed to get component/team/case names

## What's inside

| Table                    | Description                                                   |
|--------------------------|---------------------------------------------------------------|
| `caseresult_analytical`  | Denormalized case results with all names resolved inline      |
| `dim_project`            | 4 projects in scope                                           |
| `dim_routine`            | All routines across the 4 projects                            |
| `dim_case_type`          | Lookup for case_type_id → name                                |
| `dim_team`               | Lookup for team_id → name                                     |
| `dim_component`          | Lookup for component_id → name                                |

## Scope filter

- **Projects 135537960, 3020904, 456316917** — all history
- **Project 35392** — only builds with `duedate_ >= 2026-01-01`
- All routines within each project

## First-time setup (creating the analytical DB from a working_db restore)

### Step 1 — Restore the raw Testray backup into `testray_working_db`

```bash
psql -U postgres -h localhost -c "DROP DATABASE IF EXISTS testray_working_db;"
psql -U postgres -h localhost -c "CREATE DATABASE testray_working_db;"

zcat backup-db-testray2-prd2-YYYYMMDD0050.gz | \
  psql -U postgres -d testray_working_db -h localhost
```

### Step 2 — Create and populate `testray_analytical`

The bootstrap script creates `testray_analytical` and streams data in from
`testray_working_db` via `postgres_fdw` over the Unix socket. No intermediate
`pg_dump`/`pg_restore` step — single copy of the denormalized data on disk.

```bash
bash db/testray_analytical_bootstrap.sh
```

Expected runtime: 45–90 minutes (the `caseresult_analytical` CREATE TABLE
dominates). Indexes and `ANALYZE` run at the end. Produces row counts per
project as the final output.

The script runs `psql` under `sudo -u postgres` and relies on peer auth via
the default socket — no `.pgpass` or `PGPASSWORD` needed. You'll be prompted
for your sudo password once.

### Step 3 — Grant read access to the analytics user

```bash
sudo -u postgres psql -d testray_analytical \
  -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO release;"
```

### Step 4 — Validate before dropping `testray_working_db`

Before reclaiming the ~150GB, confirm the pipeline runs cleanly against the
new DB:

1. Point `config.yml` at `testray_analytical` (see below)
2. `bash run_pipeline.sh --step load_testray`
3. `bash run_pipeline.sh --step export`
4. Spot-check Looker (composite_risk_score, pass rates, test_focus)
5. Run the triage tool against the 4 in-scope projects

Then, optionally:

```bash
psql -U postgres -h localhost -c "DROP DATABASE testray_working_db;"
```

## Updating config.yml

Point the `testray` connection at the new analytical database:

```yaml
databases:
  testray:
    host:     localhost
    port:     5432
    dbname:   testray_analytical   # was: testray_working_db
    user:     release
    password: ""
```

`load_testray.R` has been updated to query `caseresult_analytical` directly
instead of the raw `o_22235989312226_*` tables — simpler and faster.

## Sharing the database

Use the dump script to create a shareable `.dump` file:

```bash
bash db/testray_analytical_dump.sh
```

This produces `backups/testray_analytical_YYYYMMDD.dump` — expected size
5–10 GB compressed.

## Restoring on another machine

```bash
psql -U postgres -c "DROP DATABASE IF EXISTS testray_analytical;"
psql -U postgres -c "CREATE DATABASE testray_analytical;"
pg_restore -U postgres -d testray_analytical -j 4 \
  testray_analytical_YYYYMMDD.dump
```

## Refreshing from a new backup

When a new Testray backup drops, rerun the full flow:

```bash
# 1. Restore the new raw backup
psql -U postgres -c "DROP DATABASE IF EXISTS testray_working_db;"
psql -U postgres -c "CREATE DATABASE testray_working_db;"
zcat backup-db-testray2-prd2-NEWDATE.gz | psql -U postgres -d testray_working_db

# 2. Rebuild testray_analytical via FDW (drops and recreates the DB)
bash db/testray_analytical_bootstrap.sh

# 3. Drop working_db to reclaim space (optional, after validation)
psql -U postgres -c "DROP DATABASE testray_working_db;"

# 4. Create a shareable dump for the team
bash db/testray_analytical_dump.sh
```

## Typical disk footprint

| What                            | Size         |
|---------------------------------|--------------|
| Raw backup (.gz)                | 25 GB        |
| testray_working_db restored     | 150 GB       |
| testray_analytical (live DB)    | 30–50 GB     |
| testray_analytical (.dump gz)   | 5–10 GB      |
