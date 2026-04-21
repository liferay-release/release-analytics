#!/bin/bash
# =============================================================================
# testray_analytical_dump.sh
# Dump testray_analytical database for sharing with teammates.
#
# Creates a custom-format pg_dump (.dump) file that can be restored with
# pg_restore. Custom format is compressed and parallelizable.
#
# Usage:
#   bash db/testray_analytical_dump.sh
#
# Output:
#   backups/testray_analytical_YYYYMMDD.dump
#
# To restore on another machine:
#   psql -U postgres -c "DROP DATABASE IF EXISTS testray_analytical;"
#   psql -U postgres -c "CREATE DATABASE testray_analytical;"
#   pg_restore -U postgres -d testray_analytical -j 4 \
#     backups/testray_analytical_YYYYMMDD.dump
#
# Notes:
#   - The -Fc format is Postgres custom format (compressed, random access)
#   - The -Z 9 flag sets maximum compression (slower dump, smaller file)
#   - Expected uncompressed size: 30-50 GB
#   - Expected compressed size:    5-10 GB
#   - Expected dump time:          15-30 minutes
# =============================================================================

set -e

TIMESTAMP=$(date +%Y%m%d)
BACKUP_DIR="backups"
OUTPUT="${BACKUP_DIR}/testray_analytical_${TIMESTAMP}.dump"

DB_HOST="${DB_HOST:-localhost}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="testray_analytical"

mkdir -p "$BACKUP_DIR"

echo "============================================================"
echo "  testray_analytical — pg_dump"
echo "  Host:     $DB_HOST"
echo "  Database: $DB_NAME"
echo "  Output:   $OUTPUT"
echo "============================================================"
echo ""

START=$(date +%s)

pg_dump \
    -U "$DB_USER" \
    -h "$DB_HOST" \
    -d "$DB_NAME" \
    -Fc \
    -Z 9 \
    --no-owner \
    --no-privileges \
    -f "$OUTPUT"

END=$(date +%s)
DURATION=$((END - START))

echo ""
echo "============================================================"
echo "  Dump complete"
echo "  Duration: $((DURATION / 60)) min $((DURATION % 60)) sec"
echo "  Size:     $(du -h "$OUTPUT" | cut -f1)"
echo "  Path:     $OUTPUT"
echo "============================================================"
echo ""
echo "To share with a teammate:"
echo "  1. Send the .dump file (via shared drive, scp, etc)"
echo "  2. They restore with:"
echo ""
echo "     psql -U postgres -c \"DROP DATABASE IF EXISTS testray_analytical;\""
echo "     psql -U postgres -c \"CREATE DATABASE testray_analytical;\""
echo "     pg_restore -U postgres -d testray_analytical -j 4 $(basename "$OUTPUT")"
echo ""
