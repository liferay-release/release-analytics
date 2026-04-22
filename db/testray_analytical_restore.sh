#!/bin/bash
# =============================================================================
# testray_analytical_restore.sh
# Restore a testray_analytical dump into the local `testray_analytical_db`
# Docker container (defined in the repo's docker-compose.yml).
#
# Usage:
#   bash db/testray_analytical_restore.sh <path-to-dump>
#
# Expected input:
#   <path-to-dump>   a custom-format dump (.dump) produced by
#                    db/testray_analytical_dump.sh (`pg_dump -Fc`)
#
# Preconditions:
#   - Docker Desktop / Engine running
#   - `docker compose up -d` already started testray_analytical_db
#   - The container exposes port 5432 and has default creds (see compose file)
#
# What this does:
#   1. Drop + recreate the target database inside the container.
#   2. Copy the dump into the container so pg_restore can read it locally
#      (avoids streaming a multi-GB file over docker stdin).
#   3. pg_restore --no-owner --no-privileges — strips the dumper's
#      ownership + ACL so everything is owned by the container's `release`
#      user. No extra GRANTs needed.
#   4. Clean up the dump file inside the container.
#
# Expected duration: 10-30 minutes depending on dump size.
# =============================================================================

set -euo pipefail

CONTAINER="${CONTAINER:-testray_analytical_db}"
DB_NAME="${DB_NAME:-testray_analytical}"
DB_USER="${DB_USER:-release}"

DUMP_PATH="${1:-}"
if [ -z "$DUMP_PATH" ]; then
    echo "Usage: $0 <path-to-dump>" >&2
    exit 1
fi
if [ ! -f "$DUMP_PATH" ]; then
    echo "ERROR: dump file not found: $DUMP_PATH" >&2
    exit 1
fi

# Confirm container is running and healthy
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: container '$CONTAINER' is not running." >&2
    echo "       Start it with: docker compose up -d" >&2
    exit 1
fi

echo "================================================================"
echo "  testray_analytical restore"
echo "  Container: $CONTAINER"
echo "  Database:  $DB_NAME   user: $DB_USER"
echo "  Dump:      $DUMP_PATH"
echo "================================================================"
echo ""

START=$(date +%s)

# Wait for postgres to accept connections (compose healthcheck should make
# this instant, but be defensive on slow laptops).
echo "→ waiting for postgres to accept connections…"
for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo "→ dropping + recreating $DB_NAME…"
docker exec -e PGPASSWORD=triage_local "$CONTAINER" \
    psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" \
    -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

echo "→ copying dump into container…"
docker cp "$DUMP_PATH" "$CONTAINER":/tmp/restore.dump

echo "→ restoring (this is the long step) …"
docker exec -e PGPASSWORD=triage_local "$CONTAINER" \
    pg_restore -U "$DB_USER" -d "$DB_NAME" \
    --no-owner --no-privileges \
    -j 4 /tmp/restore.dump || {
        echo "WARNING: pg_restore reported errors (often harmless — missing extensions/roles)." >&2
    }

echo "→ cleaning up dump from container…"
docker exec "$CONTAINER" rm -f /tmp/restore.dump

# Basic sanity check
ROWS=$(docker exec -e PGPASSWORD=triage_local "$CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM caseresult_analytical;" || echo 0)

END=$(date +%s)
MIN=$(( (END - START) / 60 ))
SEC=$(( (END - START) % 60 ))

echo ""
echo "================================================================"
echo "  restore complete in ${MIN}m ${SEC}s"
echo "  caseresult_analytical rows: ${ROWS}"
echo ""
echo "  Next: run triage — see apps/triage/README.md"
echo "================================================================"
