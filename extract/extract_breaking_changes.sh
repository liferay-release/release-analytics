#!/usr/bin/env bash
# =============================================================================
# extract_breaking_changes.sh
# Extracts breaking change commit counts per module per quarter from git history.
#
# Breaking changes are identified by "# breaking" in the commit message (case
# insensitive). For each quarter range, counts how many breaking commits touched
# files in each module (distinct commits per module, not files).
#
# Output: data/breaking_changes_YYYYMMDD.csv
# Columns: module_path, quarter, breaking_count
#
# Usage:
#   bash extract/extract_breaking_changes.sh
#   bash extract/extract_breaking_changes.sh --portal-path /path/to/liferay-portal
#   bash extract/extract_breaking_changes.sh --dry-run
#
# Quarter tag format in repo: 2024.q1.1 (lowercase q)
# Quarter format in platform:  2024.Q1   (uppercase Q)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/data"
OUTPUT_FILE="$OUTPUT_DIR/breaking_changes_$(date +%Y%m%d).csv"

# Default portal path — override with --portal-path
PORTAL_PATH="${LIFERAY_PORTAL_PATH:-$HOME/dev/projects/liferay-portal}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --portal-path) PORTAL_PATH="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true;     shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate
# -----------------------------------------------------------------------------
if [[ ! -d "$PORTAL_PATH/.git" ]]; then
  echo "ERROR: Not a git repository: $PORTAL_PATH"
  echo "  Set LIFERAY_PORTAL_PATH or use --portal-path"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "============================================================"
echo "  extract_breaking_changes.sh"
echo "  Portal path: $PORTAL_PATH"
echo "  Output:      $OUTPUT_FILE"
[[ "$DRY_RUN" == true ]] && echo "  Mode:        DRY RUN"
echo "============================================================"

# -----------------------------------------------------------------------------
# Quarter tag ranges — from 2024.Q1 onwards
# Tag format: YYYY.qN.P (lowercase q, patch suffix)
# Platform quarter format: YYYY.QN (uppercase Q, no patch)
# Each range is: previous_tag...current_tag (exclusive...inclusive)
# -----------------------------------------------------------------------------
declare -A QUARTER_RANGES
QUARTER_RANGES["2024.Q1"]="2023.q4.0...2024.q1.1"
QUARTER_RANGES["2024.Q2"]="2024.q1.1...2024.q2.0"
QUARTER_RANGES["2024.Q3"]="2024.q2.0...2024.q3.0"
QUARTER_RANGES["2024.Q4"]="2024.q3.0...2024.q4.0"
QUARTER_RANGES["2025.Q1"]="2024.q4.0...2025.q1.0"
QUARTER_RANGES["2025.Q2"]="2025.q1.0...2025.q2.0"
QUARTER_RANGES["2025.Q3"]="2025.q2.0...2025.q3.0"
QUARTER_RANGES["2025.Q4"]="2025.q3.0...2025.q4.0"
QUARTER_RANGES["2026.Q1"]="2025.q4.0...2026.q1.0"

# Ordered list for processing
QUARTERS=(
  "2024.Q1" "2024.Q2" "2024.Q3" "2024.Q4"
  "2025.Q1" "2025.Q2" "2025.Q3" "2025.Q4"
  "2026.Q1"
)

# -----------------------------------------------------------------------------
# Module path extraction — matches pipeline REGEXP pattern
# modules/dxp/apps/{cat}/{artifact}  → 5 segments
# modules/{group}/{artifact}         → 3 segments
# portal-impl, portal-kernel         → root level
# Excludes: third-party, antlr, osb
# -----------------------------------------------------------------------------
extract_module_path() {
  local file_path="$1"

  # Exclusions
  [[ "$file_path" == modules/third-party/* ]] && return
  [[ "$file_path" == */antlr/* ]]              && return
  [[ "$file_path" == modules/dxp/apps/osb/* ]] && return

  if [[ "$file_path" == modules/dxp/* ]]; then
    # 5-segment: modules/dxp/apps/{category}/{artifact}
    echo "$file_path" | grep -oP '^modules/[^/]+/[^/]+/[^/]+/[^/]+'
  elif [[ "$file_path" == modules/* ]]; then
    # 3-segment: modules/{group}/{artifact}
    echo "$file_path" | grep -oP '^modules/[^/]+/[^/]+'
  elif [[ "$file_path" == portal-impl/* ]]; then
    echo "portal-impl"
  elif [[ "$file_path" == portal-kernel/* ]]; then
    echo "portal-kernel"
  elif [[ "$file_path" == portal-web/* ]]; then
    echo "portal-web"
  fi
  # All other paths (build files, root scripts etc.) are silently ignored
}

# -----------------------------------------------------------------------------
# Write CSV header
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == false ]]; then
  echo "module_path,quarter,breaking_count" > "$OUTPUT_FILE"
fi

# -----------------------------------------------------------------------------
# Process each quarter
# -----------------------------------------------------------------------------
cd "$PORTAL_PATH"

TOTAL_COMMITS=0
TOTAL_ROWS=0

for QUARTER in "${QUARTERS[@]}"; do
  RANGE="${QUARTER_RANGES[$QUARTER]}"
  START_TAG="${RANGE%%...*}"
  END_TAG="${RANGE##*...}"

  # Verify tags exist
  if ! git rev-parse "$START_TAG" &>/dev/null; then
    echo "  [$QUARTER] SKIP — tag not found: $START_TAG"
    continue
  fi
  if ! git rev-parse "$END_TAG" &>/dev/null; then
    echo "  [$QUARTER] SKIP — tag not found: $END_TAG"
    continue
  fi

  echo ""
  echo "  [$QUARTER] Range: $RANGE"

  if [[ "$DRY_RUN" == true ]]; then
    COUNT=$(git log --oneline --grep="# breaking" -i "$RANGE" 2>/dev/null | wc -l | tr -d ' ')
    echo "  [$QUARTER] DRY RUN — would process $COUNT breaking commits"
    continue
  fi

  # Get all breaking commit hashes in this range
  mapfile -t COMMIT_LIST < <(git log --format="%H" --grep="# breaking" -i "$RANGE" 2>/dev/null || true)
  COMMIT_COUNT="${#COMMIT_LIST[@]}"
  echo "  [$QUARTER] Breaking commits: $COMMIT_COUNT"

  if [[ "$COMMIT_COUNT" -eq 0 ]]; then
    echo "  [$QUARTER] No breaking commits found"
    continue
  fi

  TOTAL_COMMITS=$((TOTAL_COMMITS + COMMIT_COUNT))

  # For each commit, get changed files → extract module paths
  # Accumulate in temp file to avoid nested associative array issues
  QUARTER_TMP=$(mktemp)

  for COMMIT_HASH in "${COMMIT_LIST[@]}"; do
    [[ -z "$COMMIT_HASH" ]] && continue

    # Collect unique modules touched by this commit
    declare -A COMMIT_MODULES=()
    while IFS= read -r FILE_PATH; do
      [[ -z "$FILE_PATH" ]] && continue
      MODULE=$(extract_module_path "$FILE_PATH" || true)
      [[ -z "$MODULE" ]] && continue
      COMMIT_MODULES["$MODULE"]=1
    done < <(git diff-tree --no-commit-id -r --name-only "$COMMIT_HASH" 2>/dev/null || true)

    # Write one line per module touched by this commit
    for MODULE in "${!COMMIT_MODULES[@]}"; do
      echo "$MODULE" >> "$QUARTER_TMP"
    done
    unset COMMIT_MODULES
  done

  # Count commits per module by sorting and counting duplicates
  QUARTER_ROWS=0
  if [[ -s "$QUARTER_TMP" ]]; then
    sort "$QUARTER_TMP" | uniq -c | while read -r COUNT MODULE; do
      printf '"%s","%s",%s\n' "$MODULE" "$QUARTER" "$COUNT"
    done >> "$OUTPUT_FILE"
    QUARTER_ROWS=$(sort "$QUARTER_TMP" | uniq | wc -l | tr -d ' ')
  fi
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
if [[ "$DRY_RUN" == true ]]; then
  echo "  DRY RUN complete — no file written"
else
  echo "  Done."
  echo "  Total breaking commits processed: $TOTAL_COMMITS"
  echo "  Total module × quarter rows:      $TOTAL_ROWS"
  echo "  Output: $OUTPUT_FILE"
fi
echo "============================================================"