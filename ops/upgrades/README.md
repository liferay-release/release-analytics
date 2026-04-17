# Database Upgrade Harness

Interactive Docker-based scripts for standing up customer database
dumps (MySQL, PostgreSQL, Oracle, SQL Server) and running the Liferay
Portal database upgrade against them. Used to reproduce customer
upgrade issues locally and smoke-test the upgrade path before a GA
release.

**Original author:** Brian Joyner Wulbern &lt;brian.wulbern@liferay.com&gt;.
Script version headers (`VERSION: 1.23.0` etc.) are maintained in-file
— bump them when you change behavior.

## Scripts

| Script | Purpose | Interactivity |
|---|---|---|
| [`parallel_upgrades.sh`](parallel_upgrades.sh) | **Primary driver** (v2.1.0). Menu-driven "Upgrade Factory" — setup + import for all four DBs, standalone upgrade of an already-imported DB, container teardown, `docker system prune`. Includes disk-space and tab-title niceties. | Menu loop |
| [`upgrade_databases.sh`](upgrade_databases.sh) | Earlier single-shot variant (v1.23.0). Same coverage as `parallel_upgrades.sh` minus the menu loop. Supports Antel + Lee Health (PostgreSQL). | One prompt |
| [`upgrade_databases_all.sh`](upgrade_databases_all.sh) | Older cumulative variant. Predates `parallel_upgrades.sh`. Keep for reference; prefer `parallel_upgrades.sh`. | One prompt |
| [`upgrade_databases_e5a2.sh`](upgrade_databases_e5a2.sh) | e5a2-specific variant (v1.11.0). Adds `create_alter_tables` helper for re-aliasing to `utf8mb4_unicode_ci` — useful when a dump's collation mismatches `lportal`. | One prompt |
| [`mysql_database_upgrade.sh`](mysql_database_upgrade.sh) | **Non-interactive** MySQL helper — takes explicit args, callable from other scripts or CI. Actions: `export`, `import`, `stop`. | CLI args |

## Usage

### Interactive (most common)

```bash
cd ~/work/liferay-upgrade-sandbox     # any folder with your dump files
bash /path/to/liferay-release-analytics/ops/upgrades/parallel_upgrades.sh
```

Then follow the menu:

```
--- Liferay Upgrade Factory ---
1. Setup & Import: SQL Server
2. Setup & Import: MySQL
3. Setup & Import: PostgreSQL
4. Setup & Import: Oracle
5. Upgrade Existing Imported Database...
6. Stop/Drop Database Containers...
Q. Quit
```

### Non-interactive MySQL

```bash
bash mysql_database_upgrade.sh export mysql lportal /tmp/lportal_dump.sql
bash mysql_database_upgrade.sh import mysql lportal /tmp/lportal_dump.sql
bash mysql_database_upgrade.sh stop
```

## What each run does

1. Starts a Docker container for the chosen DB engine
   (`mysql_db`, `postgresql_db`, `oracle_db`, `sqlserver_db`).
2. Imports the provided dump (various formats — `.sql`, `.gz`, `.dmp`,
   `.bak`).
3. Points a local Liferay Tomcat checkout at the container and runs
   `db_upgrade_client.sh` with `-Xmx4096m -Duser.timezone=GMT`.
4. Tails the upgrade for success / failure and leaves the container
   running so you can connect with a SQL client afterwards.

## Known customer dumps wired in

The menus reference specific customer dumps by filename / MODL code —
if they do not exist on disk the relevant option will fail:

| Customer | Dump file | MODL |
|---|---|---|
| Cuscal | `25Q1_cuscal_dump_upgraded_with_kt_changes.dmp` | — |
| Tokio Marine | `25Q3_tokio_marine_old.dmp` | — |
| APCOA | `24Q2_APCOA_database_dump.sql` | `apcoa` |
| e5a2 | `lxce5a2-e5a2prd.gz` | `e5a2` |
| TU Delft | `24Q1_TUDelft_database_dump.sql` | `tudelft` |

Add a new customer dump by editing the relevant case branch in
`parallel_upgrades.sh` (or the variant you are using). Pattern: add
entry to the `dump_names` / `dump_files` associative arrays or to the
top-level `case $CHOICE`.

## Caveats

- **Hardcoded passwords.** SQL Server uses `R00t@1234`; Oracle uses
  `LportalPassword123`. These are local-sandbox only — do not reuse.
- **`docker system prune -a --volumes -f`** is available from the
  "Stop/Drop" menu and is destructive. Reads every Docker volume on
  the machine, not just this script's. Double-check before picking it.
- **Disk space:** `parallel_upgrades.sh` warns at &lt; 10 GB free. Customer
  dumps routinely consume 15–40 GB once imported.
- **`upgrade_databases_all.sh` is older.** Left in place for parity
  with the upstream `release-team-scripts` repo; new changes should go
  into `parallel_upgrades.sh`.
- **`portal-upgrade-ext.properties` must exist in the upgrade-tool
  directory** — the scripts `cd` into it before running
  `db_upgrade_client.sh` so that JDBC config is picked up from the
  local folder.

## Dependencies

- Docker (+ Docker Desktop on macOS / Docker Engine on Linux)
- `pv` — optional, enables progress bars during `mysqldump`
- `bc` — used for the disk-space warning in `parallel_upgrades.sh`
- A local `db_upgrade_client.sh` from the portal upgrade tool
  distribution, reachable on `PATH` or in a known location referenced
  by the script
