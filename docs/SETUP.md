# Setup Guide — liferay-release-analytics

This guide gets you from a fresh clone to a running environment.
Claude Code can walk you through this interactively — run `claude` in
the repo root and it will check your setup and guide you through any
missing steps.

---

## Prerequisites

Install these before starting:

| Tool | Version | Purpose |
|---|---|---|
| R | 4.2+ | Pipeline and dashboards |
| RStudio | Any recent | Recommended R IDE |
| Docker Desktop | Any recent | Local PostgreSQL database |
| Python | 3.10+ | Triage pipeline |
| Git | Any | Version control |

---

## Step 1 — Clone and open

```bash
git clone <repo-url> liferay-release-analytics
cd liferay-release-analytics
```

---

## Step 2 — Start the database

The local PostgreSQL database runs in Docker. Schema is applied
automatically on first start.

```bash
docker compose up -d
```

Verify it's healthy:

```bash
docker compose ps
# release_analytics_db should show "healthy"
```

To stop (data persists):
```bash
docker compose down
```

To reset to a clean slate:
```bash
docker compose down -v
docker compose up -d
```

---

## Step 3 — Configure credentials

Copy the example config and fill in your credentials:

```bash
cp config/config.yml.example config/config.yml
```

Open `config/config.yml` and fill in each section:

```yaml
database:
  host: localhost
  port: 5432
  dbname: release_analytics
  user: rap_user
  password: changeme_local   # matches docker-compose.yml for local dev

jira:
  base_url: https://liferay.atlassian.net
  email: your.email@liferay.com
  api_token: <your-jira-api-token>   # Settings → Security → API tokens

testray:
  base_url: https://testray.liferay.com
  username: your.username
  password: <your-testray-password>
```

**config/config.yml is gitignored — never commit it.**

---

## Step 4 — Install R packages

From RStudio or R console, run from the repo root:

```r
install.packages("renv")
renv::restore()
```

This installs all required packages from the lockfile. Takes a few
minutes on first run.

Verify the DB connection works:

```r
source("config/release_analytics_db.R")
con <- get_db_connection()
DBI::dbGetQuery(con, "SELECT 1")
# Should return a data frame with value 1
```

---

## Step 5 — Install Python dependencies (triage pipeline only)

If you're working on the triage pipeline:

```bash
cd apps/triage
python -m venv .venv
source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

---

## Step 6 — Install Claude Code (recommended)

Claude Code is the primary AI tool for working in this repo. It reads
the `CLAUDE.md` files and skill packs automatically, giving it full
context about the platform without you needing to re-explain things.

```bash
npm install -g @anthropic-ai/claude-code
```

Start a session from the repo root:

```bash
claude
```

See the [Claude Code migration guide](docs/CLAUDE_CODE_SETUP.md) for
tips on getting the most out of it.

---

## Verify your setup

Run this checklist before your first pipeline run:

```bash
# 1. Database running and healthy
docker compose ps

# 2. Schema applied
psql -h localhost -U rap_user -d release_analytics -c "\dt"
# Should list fact_* and dim_* tables

# 3. R connection works
Rscript -e "source('config/release_analytics_db.R'); con <- get_db_connection(); print(DBI::dbGetQuery(con, 'SELECT count(*) FROM dim_component'))"
```

---

## Common issues

**`docker compose up` fails — port 5432 already in use**
Another PostgreSQL instance is running locally. Either stop it or change
the port mapping in `docker-compose.yml` (`"5433:5432"`) and update
`config/config.yml` accordingly.

**`renv::restore()` fails on a package**
Try `renv::restore(prompt = FALSE)` to skip confirmation prompts. If a
specific package fails, install it manually with `install.packages("pkg")`
then re-run `renv::restore()`.

**`get_db_connection()` returns an error**
Check that Docker is running (`docker compose ps`) and that
`config/config.yml` credentials match `docker-compose.yml`.

**Jira API token rejected**
Tokens expire. Generate a new one at:
Jira → Profile → Personal Access Tokens → Create token

---

## What's next

Once setup is complete:

- Read the root `CLAUDE.md` for platform orientation
- Run `claude` and ask it to explain the pipeline or walk you through
  a specific workstream
- For triage work, open `apps/triage/` and read its `CLAUDE.md`
- For dashboard work, see `reports/` and `utils/export_looker.R`

⚠️ **Do not run `export_looker.R` until you confirm with the team
that upstream pipeline fixes are in place.** See root `CLAUDE.md`
backlog section.
