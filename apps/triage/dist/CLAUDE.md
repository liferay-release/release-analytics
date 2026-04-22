# Triage setup helper (one-time)

> **How to use this file** — open Claude Code in the folder where this
> file sits (alongside a `testray_analytical_*.dump`), then prompt with
> something like *"set up triage"* or *"walk me through the next steps"*.
> Claude loads this file automatically and drives the setup.
>
> **Strictly for first-time setup.** After the first successful triage
> run, hand off to the cloned repo's own `CLAUDE.md` and
> `.claude/skills/` — those become the source of truth for ongoing
> sessions.
>
> **Source of truth:** `apps/triage/dist/CLAUDE.md` in the
> release-analytics repo. Anyone refreshing the shared Drive package
> should upload that file verbatim alongside the new dump.

You are helping a Liferay engineer set up the Testray triage tool on their
laptop for the first time. They have two artifacts in this folder:

1. A `testray_analytical_YYYY-MM-DD.dump` file (downloaded from the
   shared Drive link)
2. This `CLAUDE.md` (what you're reading)

The goal is to get them from these two files to running their first triage
against a real build pair, and then hand off to the repo's own docs.

---

## Step 0 — Explain the plan first

**Before running any commands**, tell the dev what's about to happen so
they know what they're signing up for. Keep it brief (≤10 lines), then
wait for them to say "go" / "yes" / similar before running anything.

Template to use (adapt timings based on their disk/CPU):

> Here's what I'll walk you through, roughly 10-15 minutes total:
>
> 1. Prereq check — Docker, Python 3.10+, git (1 min)
> 2. Clone `liferay-release/release-analytics` into the parent folder (1 min)
> 3. `docker compose up -d` — start a local postgres container (30 sec)
> 4. Restore the `.dump` file into the container (5-10 min)
> 5. Create `config/config.yml` + ask for your `liferay-portal` path
> 6. Python venv + `pip install` the triage requirements (2 min)
> 7. Run your first triage (you'll pick a build pair; I'll drive prepare
>    → classify → submit)
>
> You can interrupt, ask questions, or redo any step. Ready to start?

After they confirm, proceed with Step 1. If they ask questions first,
answer them, then ask again before running commands.

---

## Step 1 — Prerequisite check

Run these and report any that fail. If all pass, continue. If any fails,
tell the user exactly what's missing and how to install it on their OS,
then stop and wait.

```bash
docker --version       # need Docker Desktop or Docker Engine running
docker compose version # need Compose v2
python3 --version      # need 3.10 or newer
git --version          # any recent version
```

Also confirm Docker daemon is actually up:

```bash
docker ps >/dev/null && echo "docker: ok" || echo "docker: NOT running"
```

## Step 2 — Locate the dump

The working folder should contain exactly one `.dump` file matching
`testray_analytical_*.dump`. Note its path — you'll need it in Step 5.

```bash
ls *.dump
```

If there's no dump, ask the user to download the latest
`testray_analytical_YYYY-MM-DD.dump` from the shared Drive and put it in
this folder. Then restart.

## Step 3 — Clone (or update) the release-analytics repo

Put it alongside this working folder (not inside it). Default parent is
the parent of the current folder:

```bash
# If the clone doesn't exist yet:
git clone git@github.com:liferay-release/release-analytics.git
# SSH not set up? Use HTTPS instead:
# git clone https://github.com/liferay-release/release-analytics.git
```

If the clone **already exists** (re-running setup, previous attempt,
etc.), pull the latest so you pick up any post-share fixes to the
compose file, restore script, or prepare.py:

```bash
cd release-analytics
git pull --ff-only origin master
```

From here on, run commands from **inside the cloned repo** unless noted.

```bash
cd release-analytics
```

## Step 4 — Start the postgres container

```bash
docker compose up -d
```

The compose file is configured for testray_analytical on `localhost:5432`.
Wait for the container to report healthy:

```bash
docker compose ps
# look for State: running (healthy)
```

## Step 5 — Restore the dump

Use the dump path from Step 2 (the `.dump` file is in the parent working
folder, so reference it with `..`):

```bash
bash db/testray_analytical_restore.sh ../testray_analytical_YYYY-MM-DD.dump
```

This takes 10-30 minutes. The script prints progress; the final
`caseresult_analytical rows:` line should show several million rows.

## Step 6 — Create config.yml

```bash
cp config/config.yml.example config/config.yml
```

Then confirm with the user:

- **`testray.password`** — default `triage_local` from docker-compose.yml.
  Leave as-is unless they changed the compose file. Make clear to the
  user: this is **not** their Testray website password — it's the local
  postgres password for the dump container running on their laptop.
- **`git.repo_path`** — default `~/dev/projects/liferay-portal`. Ask if
  that's where their checkout is; update if not.

`release_analytics` is intentionally left commented out. The dev will
use `--no-upsert` on submit, so no persistence DB is needed.

## Step 7 — Python environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r apps/triage/requirements.txt
```

## Step 8 — First triage run

Now drive the interactive flow. Ask the user for:

### 8a. Build pair

Set Postgres connection info for this shell session so `psql` works
without flags for the rest of the setup:

```bash
export PGHOST=localhost PGPORT=5432 PGUSER=release \
       PGDATABASE=testray_analytical PGPASSWORD=triage_local
```

First, tell them the cutoff for what's in the dump:

```bash
psql -c "SELECT routine_id, MAX(build_datetime)::date AS last_build_in_dump,
               COUNT(DISTINCT build_id) AS builds
           FROM dim_build GROUP BY routine_id ORDER BY routine_id;"
```

Then ask:
- **Baseline build id** (the older, known-good build — almost always in
  the dump since baselines are typically older)
- **Target build id** (the newer build whose failures you want to triage)

Check whether the target is in `dim_build`:

```bash
psql -c "SELECT build_id, build_name, git_hash FROM dim_build WHERE build_id = <id>;"
```

### 8b. Pick the input mode based on whether target is in the dump

**If target IS in dim_build** → use `from-db`:

```bash
python3 -m apps.triage.prepare from-db \
    --build-a <baseline-id> \
    --build-b <target-id>
```

**If target is NOT in dim_build** → two options:

*(a) `from-csv` — dev downloads the target build's case results CSV from
Testray and points `prepare` at it:*
- Path to the CSV (e.g. `~/Downloads/case_results.csv`)
- Target `build_id` (from the Testray UI)
- Target `git_hash` (from the Testray build page — 40-char sha from liferay-portal master)

```bash
python3 -m apps.triage.prepare from-csv \
    --baseline-build <baseline-id> \
    --target-csv <csv-path> \
    --target-build-id <id> \
    --target-hash <sha>
```

*(b) `from-api` — fetch directly from Testray REST. Requires the dev to
add `testray.client_id` and `testray.client_secret` to `config.yml`
(ask them if they have these; if not, fall back to `from-csv`).*

```bash
python3 -m apps.triage.prepare from-api \
    --baseline-build <baseline-id> \
    --target-build-id <id> \
    --target-hash <sha>
```

Either way, you'll get:

```
Run bundle ready: apps/triage/runs/r_<ts>_<A>_<B>
```

### 8c. Classify — right here, in this same Claude Code session

**Do not tell the user to open a new session in the cloned repo.** Keep
driving classification from this setup session. The bundle's `prompt.md`
is self-contained; if you need the full rubric or schema, read the skill
file by absolute path:

```bash
cat ../release-analytics/.claude/skills/triage.skill
```

Then read `apps/triage/runs/r_<ts>_<A>_<B>/prompt.md`, reason through
each failure against `hunks.txt` and `git_diff_full.diff`, and write
`apps/triage/runs/r_<ts>_<A>_<B>/results.json` matching
`results.schema.json`. All in this session — the dev came here to
classify, don't make them start over.

### 8d. Submit

```bash
python3 -m apps.triage.submit apps/triage/runs/r_<ts>_<A>_<B> --no-upsert
```

`--no-upsert` prints the validated summary but doesn't write to any DB —
right choice for this distribution, since `release_analytics` isn't
running locally. Results live in `runs/r_<ts>_<A>_<B>/results.json` as
the dev's record.

---

## Handoff

Once Step 8d (submit) completes successfully, **this setup helper's job
is done**. Tell the user:

> Setup and your first triage run are both complete. For future runs,
> just `cd ../release-analytics && python3 -m apps.triage.prepare ...`
> straight from a terminal — the repo has its own `CLAUDE.md`,
> `apps/triage/CLAUDE.md`, and `.claude/skills/triage.skill` that
> auto-load when you open Claude Code inside the repo.
>
> You can delete this `CLAUDE.md` (the setup helper) and the `.dump`
> file from your original working folder — neither is needed again
> unless you want to refresh the dump with a newer snapshot.

Do not suggest opening a new Claude Code session in the repo *during*
the first classification run. The dev is already in this session with
the bundle ready — push through here. The repo docs become relevant
for their *next* triage run, not this one.

Do not reuse this file for ongoing work. It's a one-time setup aid.
