#!/usr/bin/env bash
# apps/triage/run_triage_api.sh
#
# One-shot triage run via the Anthropic API. Chains:
#   1. apps.triage.prepare     → runs/r_<id>/ bundle
#   2. apps.triage.classify_api → writes results.json
#   3. apps.triage.submit       → upserts to fact_triage_results
#
# This is the headless / Jenkins entry point — no Claude Code session in the
# loop. For local interactive triage where a developer classifies in a
# Claude Code session, use apps.triage.prepare + apps.triage.submit directly
# (see apps/triage/CLAUDE.md).
#
# Usage:
#   # Both builds in testray_analytical (the common case)
#   ./apps/triage/run_triage_api.sh --build-a <A> --build-b <B>
#
#   # Mixed sources — pass through to prepare.py directly, no --build-a
#   ./apps/triage/run_triage_api.sh \
#       --baseline-source db  --baseline-build-id 451312408 \
#       --target-source   api --target-build-id   462975400
#
#   # Dry-run — prepare + batch plan, no API call, no upsert
#   ./apps/triage/run_triage_api.sh --build-a <A> --build-b <B> --dry-run
#
#   # Validate results.json without writing to DB
#   ./apps/triage/run_triage_api.sh --build-a <A> --build-b <B> --no-upsert
#
# Flags:
#   --build-a <id>             Baseline build id. Implies --baseline-source=db.
#   --build-b <id>             Target build id. Implies --target-source=db.
#   --baseline-source ...      Full orthogonal source flags pass through to
#   --target-source   ...      apps.triage.prepare (use for csv/api sides).
#   --classifier <label>       Classifier label to record in
#                              fact_triage_results (default: api:claude-opus-4-7).
#   --by-subtask               Subtask-aware mode: group regressions by Testray
#                              Subtask (testflow algorithm), classify once per
#                              group, fan out the verdict across member case-rows.
#                              Requires --target-source api (or --build-b alone
#                              with no --target-source override). Pass through to
#                              both prepare.py and classify_api.py.
#   --no-upsert                Validate + print summary but skip DB writes.
#   --dry-run                  Build the bundle and print the batch plan,
#                              but make no API calls and do not submit.
#   -h, --help                 Show this help.
#
# Environment:
#   ANTHROPIC_API_KEY must be set. classify_api.py errors with guidance
#   if it is not.
#
# Prerequisites:
#   pip install -r apps/triage/requirements.txt -r apps/triage/requirements-api.txt

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

BUILD_A=""
BUILD_B=""
CLASSIFIER=""
NO_UPSERT=false
DRY_RUN=false
BY_SUBTASK=false
PREPARE_EXTRA=()

show_help() {
    sed -n '/^# Usage:/,/requirements-api.txt$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-a)        BUILD_A="$2";    shift 2 ;;
        --build-b)        BUILD_B="$2";    shift 2 ;;
        --classifier)     CLASSIFIER="$2"; shift 2 ;;
        --no-upsert)      NO_UPSERT=true;  shift ;;
        --dry-run)        DRY_RUN=true;    shift ;;
        --by-subtask)     BY_SUBTASK=true; shift ;;
        -h|--help)        show_help; exit 0 ;;
        # Orthogonal prepare-side flags — pass through verbatim.
        --baseline-source|--baseline-build-id|--baseline-csv|--baseline-hash|--baseline-name|\
        --target-source|--target-build-id|--target-csv|--target-hash|--target-name)
            PREPARE_EXTRA+=("$1" "$2"); shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve build args → prepare flags
# ---------------------------------------------------------------------------

# --build-a / --build-b are sugar for "use db on that side". They're
# mutually exclusive with the orthogonal --{side}-source flag for the
# same side.
has_flag() {
    local needle="$1"
    for arg in "${PREPARE_EXTRA[@]}"; do
        [[ "$arg" == "$needle" ]] && return 0
    done
    return 1
}

if [[ -n "$BUILD_A" ]]; then
    if has_flag "--baseline-source" || has_flag "--baseline-build-id"; then
        echo "Error: --build-a conflicts with --baseline-source / --baseline-build-id. Pick one." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--baseline-source db --baseline-build-id "$BUILD_A")
fi
if [[ -n "$BUILD_B" ]]; then
    if has_flag "--target-source" || has_flag "--target-build-id"; then
        echo "Error: --build-b conflicts with --target-source / --target-build-id. Pick one." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--target-source db --target-build-id "$BUILD_B")
fi

# Interactive prompts if no build info supplied at all (mirrors old run_triage.sh).
if [[ ${#PREPARE_EXTRA[@]} -eq 0 ]]; then
    echo ""
    read -rp "Enter Build A (baseline, older build) ID: " BUILD_A
    read -rp "Enter Build B (target,  newer build)  ID: " BUILD_B
    if [[ -z "$BUILD_A" || -z "$BUILD_B" ]]; then
        echo "Error: both Build A and Build B required." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--baseline-source db --baseline-build-id "$BUILD_A")
    PREPARE_EXTRA+=(--target-source   db --target-build-id   "$BUILD_B")
fi

# ---------------------------------------------------------------------------
# Step 1 — prepare
# ---------------------------------------------------------------------------

echo ""
echo "=========================================================="
echo "Step 1/3: apps.triage.prepare"
echo "=========================================================="

[[ "$BY_SUBTASK" == true ]] && PREPARE_EXTRA+=(--by-subtask)

# `tee /dev/stderr` shows prepare's progress live; command substitution
# captures stdout so we can grep for the run_dir line.
PREPARE_OUT=$(python3 -m apps.triage.prepare "${PREPARE_EXTRA[@]}" | tee /dev/stderr)

RUN_DIR=$(printf '%s\n' "$PREPARE_OUT" | sed -n 's|^Run bundle ready: ||p' | tail -1)
if [[ -z "$RUN_DIR" ]]; then
    echo "Error: could not extract run_dir from prepare output. Did prepare fail?" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2 — classify_api
# ---------------------------------------------------------------------------

echo ""
echo "=========================================================="
echo "Step 2/3: apps.triage.classify_api"
echo "=========================================================="

# Default classifier picks up subtask mode automatically so fact_triage_results
# rows from --by-subtask runs are distinguishable in head-to-head comparisons.
if [[ -z "$CLASSIFIER" && "$BY_SUBTASK" == true ]]; then
    CLASSIFIER="api:claude-opus-4-7+testflow"
fi

CLASSIFY_ARGS=("$RUN_DIR")
[[ -n "$CLASSIFIER" ]] && CLASSIFY_ARGS+=(--classifier "$CLASSIFIER")
[[ "$DRY_RUN" == true ]] && CLASSIFY_ARGS+=(--dry-run)

python3 -m apps.triage.classify_api "${CLASSIFY_ARGS[@]}"

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "--dry-run set — stopping before submit."
    echo "Bundle: $RUN_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 3 — submit
# ---------------------------------------------------------------------------

echo ""
echo "=========================================================="
echo "Step 3/3: apps.triage.submit"
echo "=========================================================="

SUBMIT_ARGS=("$RUN_DIR")
[[ "$NO_UPSERT" == true ]] && SUBMIT_ARGS+=(--no-upsert)

python3 -m apps.triage.submit "${SUBMIT_ARGS[@]}"

echo ""
echo "Done. Bundle: $RUN_DIR"
