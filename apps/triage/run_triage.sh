#!/usr/bin/env bash
# apps/triage/run_triage.sh
#
# Entry point for the triage pipeline.
# Prompts for Build A and Build B IDs, then runs:
#   1. test_diff.sql        → output/test_diff.csv
#   2. git_hash_lookup.sql  → resolves git hashes
#   3. git diff             → output/git_diff_full.diff
#   4. extract_relevant_hunks.py → output/triage_diff_precise.md
#   5. prompt_builder.py    → batches
#   6. triage_claude.py     → classifications
#   7. store.py             → fact_triage_results + triage_run_log
#
# Usage:
#   bash apps/triage/run_triage.sh
#   bash apps/triage/run_triage.sh --build-a 410851196 --build-b 451312408
#   bash apps/triage/run_triage.sh --build-a 410851196 --build-b 451312408 --skip-git
#
# Options:
#   --build-a ID     Build A ID (baseline). Prompted if not provided.
#   --build-b ID     Build B ID (target).   Prompted if not provided.
#   --skip-git       Skip git diff steps (use existing output/triage_diff_precise.md)
#   --dry-run        Build prompts but do not call Claude API

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root (two levels up from this script)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIAGE_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$TRIAGE_DIR/output"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Colours for output
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[triage]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BUILD_A=""
BUILD_B=""
SKIP_GIT=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --build-a)   BUILD_A="$2";  shift 2 ;;
        --build-b)   BUILD_B="$2";  shift 2 ;;
        --skip-git)  SKIP_GIT=true; shift   ;;
        --dry-run)   DRY_RUN=true;  shift   ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prompt for build IDs if not provided
# ---------------------------------------------------------------------------
if [[ -z "$BUILD_A" ]]; then
    echo ""
    read -rp "Enter Build A ID (baseline / older build): " BUILD_A
fi
if [[ -z "$BUILD_B" ]]; then
    read -rp "Enter Build B ID (target / newer build):   " BUILD_B
fi

if [[ -z "$BUILD_A" || -z "$BUILD_B" ]]; then
    err "Both Build A and Build B IDs are required."
    exit 1
fi

log "Build A: $BUILD_A"
log "Build B: $BUILD_B"
echo ""

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
CONFIG="$PROJECT_ROOT/config/config.yml"
if [[ ! -f "$CONFIG" ]]; then
    err "config.yml not found at $PROJECT_ROOT/config/config.yml"
    exit 1
fi

# Extract git_repo_path from config.yml
GIT_REPO=$(python3 -c "
import yaml, os
with open('$CONFIG') as f:
    cfg = yaml.safe_load(f)
path = cfg.get('git', {}).get('repo_path', '')
print(os.path.expanduser(path))
")

if [[ -z "$GIT_REPO" ]]; then
    err "git.repo_path not set in config/config.yml"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: test_diff — query Testray
# ---------------------------------------------------------------------------
log "Step 1/5: Running test_diff.sql against testray_working_db..."

python3 - <<PYEOF
import pandas as pd
import psycopg2, psycopg2.extras, yaml, sys
from pathlib import Path

with open("$CONFIG") as f:
    cfg = yaml.safe_load(f).get("databases", {}).get("testray", {})

conn = psycopg2.connect(
    host=cfg["host"], port=int(cfg.get("port", 5432)),
    dbname=cfg["dbname"], user=cfg["user"], password=cfg["password"]
)

sql_raw = Path("$TRIAGE_DIR/test_diff.sql").read_text()
# Strip comment lines — psycopg2 chokes on % inside SQL comments
sql = "\n".join(l for l in sql_raw.splitlines() if not l.strip().startswith("--"))
# Inline integer build IDs — safe since they are integers from shell
sql = sql.replace("%(build_id_a)s", str($BUILD_A)).replace("%(build_id_b)s", str($BUILD_B))

with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
    cur.execute(sql)
    rows = cur.fetchall()

conn.close()

df = pd.DataFrame(rows)
print(f"  Rows returned: {len(df)}")
if not df.empty:
    print(f"  Status B breakdown:")
    print(df["status_b"].value_counts().to_string())

df.to_csv("$OUTPUT_DIR/test_diff.csv", index=False)
print(f"  Saved: $OUTPUT_DIR/test_diff.csv")
PYEOF

# ---------------------------------------------------------------------------
# Step 2: git_hash_lookup — get hashes from Testray build table
# ---------------------------------------------------------------------------
log "Step 2/5: Fetching git hashes..."

HASH_JSON=$(python3 - <<PYEOF
import psycopg2, yaml, json
from pathlib import Path

with open("$CONFIG") as f:
    cfg = yaml.safe_load(f).get("databases", {}).get("testray", {})

conn = psycopg2.connect(
    host=cfg["host"], port=int(cfg.get("port", 5432)),
    dbname=cfg["dbname"], user=cfg["user"], password=cfg["password"]
)

sql_raw = Path("$TRIAGE_DIR/git_hash_lookup.sql").read_text()
sql = "\n".join(l for l in sql_raw.splitlines() if not l.strip().startswith("--"))
sql = sql.replace("%(build_id_a)s", str($BUILD_A)).replace("%(build_id_b)s", str($BUILD_B))

import psycopg2.extras
cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
cur.execute(sql)
rows = {str(r["build_id"]): r["git_hash"] for r in cur.fetchall()}
conn.close()
print(json.dumps(rows))
PYEOF
)

HASH_A=$(python3 -c "import json,sys; d=json.loads('$HASH_JSON'); print(d.get('$BUILD_A',''))")
HASH_B=$(python3 -c "import json,sys; d=json.loads('$HASH_JSON'); print(d.get('$BUILD_B',''))")

if [[ -z "$HASH_A" || -z "$HASH_B" ]]; then
    warn "Could not resolve git hashes for one or both builds."
    warn "Hash A: '$HASH_A'  Hash B: '$HASH_B'"
    warn "Continuing — git diff will be skipped if hashes are missing."
    SKIP_GIT=true
else
    log "  Hash A: ${HASH_A:0:12}..."
    log "  Hash B: ${HASH_B:0:12}..."
fi

# ---------------------------------------------------------------------------
# Step 3: git diff
# ---------------------------------------------------------------------------
if [[ "$SKIP_GIT" == false ]]; then
    log "Step 3/5: Running git diff $HASH_A..$HASH_B..."

    if [[ ! -d "$GIT_REPO/.git" ]]; then
        err "Git repo not found at $GIT_REPO"
        err "Update git.repo_path in config/config.yml"
        exit 1
    fi

    # Fetch if hash_b isn't local yet
    if ! git -C "$GIT_REPO" cat-file -e "${HASH_B}^{commit}" 2>/dev/null; then
        log "  Hash B not found locally — fetching..."
        git -C "$GIT_REPO" fetch --quiet origin
    fi

    git -C "$GIT_REPO" diff "$HASH_A" "$HASH_B" \
        -- \
        ':!**/artifact.properties' \
        ':!**/.releng/**' \
        ':!**/liferay-releng.changelog' \
        ':!**/app.changelog' \
        ':!**/app.properties' \
        ':!**/bnd.bnd' \
        ':!**/packageinfo' \
        ':!**/*.xml' \
        ':!**/*.properties' \
        ':!**/*.yml' \
        ':!**/*.yaml' \
        ':!**/*.tf' \
        ':!**/*.sh' \
        ':!**/*.scss' \
        ':!**/*.css' \
        ':!**/*.gradle' \
        ':!**/package.json' \
        ':!**/*.json' \
        ':!cloud/**' \
        > "$OUTPUT_DIR/git_diff_full.diff"

    DIFF_LINES=$(wc -l < "$OUTPUT_DIR/git_diff_full.diff")
    log "  Diff written: $DIFF_LINES lines → $OUTPUT_DIR/git_diff_full.diff"
else
    log "Step 3/5: Skipping git diff (--skip-git or missing hashes)"
fi

# ---------------------------------------------------------------------------
# Step 4: extract_relevant_hunks.py
# ---------------------------------------------------------------------------
if [[ "$SKIP_GIT" == false ]]; then
    log "Step 4/5: Extracting relevant hunks..."

    # Generate a plain fragment list from test case names in test_diff.csv
    # extract_relevant_hunks.py needs a plain list (one fragment per line)
    # or a CSV with a "Likely Cause" column — test_diff.csv has neither.
    # So we derive fragments from test_case names: Java class names and
    # spec file basenames are reliable diff path tokens.
    python3 - <<INNEREOF
import pandas as pd, re
from pathlib import Path

df = pd.read_csv("$OUTPUT_DIR/test_diff.csv")
fragments = set()

for name in df["test_case"].dropna():
    name = str(name)
    # Playwright spec files: "calendar-web/main/calendarEvent.spec.ts > ..."
    # → extract "calendarEvent.spec.ts"
    if ".spec.ts" in name or ".spec.js" in name:
        spec = re.split(r"[/\s>]", name)[0].split("/")[-1]
        if spec:
            fragments.add(spec)
        # Also add the module folder e.g. "calendar-web"
        parts = name.split("/")
        if len(parts) > 1:
            fragments.add(parts[0])
    # Java test classes: "com.liferay.account.internal...AccountEntriesAdminPortletDataHandlerTest"
    # → extract "AccountEntriesAdminPortletDataHandlerTest.java"
    elif "." in name and ">" not in name:
        classname = name.split(".")[-1].split("#")[0].strip()
        if classname:
            fragments.add(classname + ".java")
        # Also add the module segment e.g. "account" from com.liferay.account...
        parts = name.split(".")
        for part in parts:
            if part not in ("com", "liferay", "internal", "test", "impl") and len(part) > 4:
                fragments.add(part)
                break
    # LocalFile tests: "LocalFile.CalendarComment#AddToEvent"
    elif name.startswith("LocalFile."):
        module = name.replace("LocalFile.", "").split("#")[0]
        # Convert CamelCase to lowercase fragment
        fragments.add(module.lower())

# Write plain list
out = Path("$OUTPUT_DIR/test_fragments.txt")
out.write_text("\n".join(sorted(fragments)))
print(f"  Generated {len(fragments)} fragments → {out}")
INNEREOF

    python3 "$TRIAGE_DIR/extract_relevant_hunks.py" \
        "$OUTPUT_DIR/git_diff_full.diff" \
        "$OUTPUT_DIR/test_fragments.txt" \
        --auto \
        --stats \
        --unmatched \
        -o "$OUTPUT_DIR/triage_diff_precise.md"
else
    log "Step 4/5: Skipping hunk extraction (--skip-git)"
    if [[ ! -f "$OUTPUT_DIR/triage_diff_precise.md" ]]; then
        warn "No triage_diff_precise.md found in output/ — prompts will have no diff context"
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: triage_claude.py — build prompts + call API
# ---------------------------------------------------------------------------
log "Step 5/5: Running triage..."

if [[ "$DRY_RUN" == true ]]; then
    warn "--dry-run: building prompts only, not calling Claude API"
fi

python3 - <<PYEOF
import sys, time, pandas as pd
from pathlib import Path

sys.path.insert(0, "$PROJECT_ROOT")

from apps.triage.prompt_builder import build_batches
from apps.triage.triage_claude  import run_triage
from apps.triage.store          import ensure_schema, ensure_run_log, \
                                        upsert_triage_results, log_run

dry_run    = $([[ "$DRY_RUN" == true ]] && echo True || echo False)
build_id_a = $BUILD_A
build_id_b = $BUILD_B
git_hash_a = "$HASH_A"
git_hash_b = "$HASH_B"

# Load test_diff
df = pd.read_csv("$OUTPUT_DIR/test_diff.csv")
flaky_count = int(df["known_flaky"].fillna(False).sum())

diff_path = Path("$OUTPUT_DIR/triage_diff_precise.md")
if not diff_path.exists():
    diff_path = None

# Build batches
batches = build_batches(
    test_diff_df=df,
    diff_path=diff_path or Path("/dev/null"),
    build_id_a=build_id_a,
    build_id_b=build_id_b,
    git_hash_a=git_hash_a,
    git_hash_b=git_hash_b,
)

if dry_run:
    print("Dry run — saving batch prompts only")
    for b in batches:
        out = Path("$OUTPUT_DIR") / f"batch_{b.batch_number}.md"
        out.write_text(b.prompt)
        print(f"  Written: {out}")
    sys.exit(0)

# Run triage
start = time.time()
result_df = run_triage(batches)
duration  = time.time() - start

# Save CSV for inspection
result_df.to_csv("$OUTPUT_DIR/triage_results.csv", index=False)
print(f"Results saved: $OUTPUT_DIR/triage_results.csv")

# Store in DB
ensure_schema()
ensure_run_log()
upsert_triage_results(result_df, build_id_a, build_id_b, git_hash_a, git_hash_b)
log_run(build_id_a, build_id_b, git_hash_a, git_hash_b,
        result_df, flaky_count, duration)

print(f"\nDone in {duration:.1f}s")
PYEOF

log "Triage complete. Results in: $OUTPUT_DIR/triage_results.csv"
log "Stored in:                   release_analytics.fact_triage_results"