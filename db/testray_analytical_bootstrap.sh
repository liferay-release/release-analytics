#!/bin/bash
# =============================================================================
# testray_analytical_bootstrap.sh
# Creates testray_analytical from testray_working_db via postgres_fdw.
#
# Replaces the old "build inside working_db → pg_dump → pg_restore" flow that
# temporarily needed double the disk. This streams data directly over FDW,
# so only one copy of the denormalized data is ever on disk.
#
# Flow:
#   1. Drop/create testray_analytical (as postgres via sudo, peer auth)
#   2. Run testray_analytical_schema.sql inside it (the long step)
#      - Schema file sets up FDW via Unix socket (peer auth, no password)
#      - Pulls data, builds indexes, validates
#
# Auth:
#   This script runs psql under `sudo -u postgres` and relies on peer auth
#   via the default Unix socket. No .pgpass or PGPASSWORD needed.
#   You'll be prompted for your sudo password once.
#
# Prerequisites:
#   - testray_working_db exists and is populated (~444 GB)
#   - postgres_fdw extension available (from postgresql-contrib)
#   - Running on a system where `sudo -u postgres` works
#
# Usage:
#   bash db/testray_analytical_bootstrap.sh
#
# Expected duration: 45-90 minutes (step 3 of the schema script dominates)
# =============================================================================

set -e

SCHEMA_FILE="${SCHEMA_FILE:-db/testray_analytical_schema.sql}"

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "ERROR: schema file not found at $SCHEMA_FILE" >&2
    echo "Set SCHEMA_FILE env var or run from the project root." >&2
    exit 1
fi

# Verify we can sudo to postgres before the long work starts
if ! sudo -u postgres true; then
    echo "ERROR: cannot sudo to the postgres user. Check sudoers config." >&2
    exit 1
fi

START=$(date +%s)

echo "============================================================"
echo "  testray_analytical — bootstrap via postgres_fdw"
echo "  Schema file: $SCHEMA_FILE"
echo "  Auth:        sudo -u postgres (peer auth via socket)"
echo "============================================================"
echo ""

echo "Step 1: (re)creating testray_analytical..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS testray_analytical;"
sudo -u postgres psql -c "CREATE DATABASE testray_analytical;"

echo ""
echo "Step 2: running schema.sql (FDW pull — 45-90 min)..."
echo "        Progress markers print between steps inside the SQL."
echo ""

# Feed schema via stdin so postgres OS user doesn't need to read it from
# the project directory (avoids any /home/nikki perm issues).
sudo -u postgres psql -d testray_analytical -v ON_ERROR_STOP=1 < "$SCHEMA_FILE"

# -----------------------------------------------------------------------------
# Step 3: Grant SELECT on all tables to the analytics role.
# The schema.sql runs as `postgres`, so everything it creates is owned by
# postgres. The pipeline (load_testray.R, triage, cofailure) connects as
# `release`, which needs explicit SELECT privileges.
#
# Override the role with ANALYTICS_USER=myrole if your setup uses a
# different user.
# -----------------------------------------------------------------------------
ANALYTICS_USER="${ANALYTICS_USER:-release}"

echo ""
echo "Step 3: granting SELECT to '$ANALYTICS_USER' role..."

if ! sudo -u postgres psql -d testray_analytical -v ON_ERROR_STOP=1 \
     -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO $ANALYTICS_USER;"; then
    echo ""
    echo "  WARNING: GRANT failed. The '$ANALYTICS_USER' role may not exist."
    echo "  Tables are built and usable by postgres. To grant access manually:"
    echo ""
    echo "    sudo -u postgres psql -d testray_analytical \\"
    echo "      -c \"GRANT SELECT ON ALL TABLES IN SCHEMA public TO <role>;\""
    echo ""
fi

END=$(date +%s)
DURATION=$((END - START))

echo ""
echo "============================================================"
echo "  bootstrap complete"
echo "  Duration: $((DURATION / 60)) min $((DURATION % 60)) sec"
echo "  Free disk: $(df -h / | awk 'NR==2 {print $4}')"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Update config.yml: databases.testray.dbname = testray_analytical"
echo "  2. Run pipeline: bash run_pipeline.sh --step load_testray"
echo "  3. Run pipeline: bash run_pipeline.sh --step export"
echo "  4. Validate in Looker (composite_risk_score, pass rates, test_focus)"
echo "  5. Validate triage tool against the 4 projects"
echo "  6. Drop testray_working_db to reclaim ~444 GB"
echo "  7. Run: bash db/testray_analytical_dump.sh (shareable dump)"
