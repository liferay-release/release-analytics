#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh
# Orchestrates the full Liferay Release Analytics Platform pipeline.
#
# Usage:
#   bash run_pipeline.sh [options]
#
# Options:
#   --skip-jira         Skip Jira extraction (use cached staging/raw_jira_issues.rds)
#   --skip-export       Skip Looker CSV export
#   --run-lda           Also run LDA topic analysis (slow, ~5 min)
#   --step STEP         Run a single step only (see STEPS below)
#   --dry-run           Print steps without executing
#   --help              Show this message
#
# Steps (for --step):
#   sync_releases
#   load_map
#   ingest_churn
#   extract_jira
#   transform
#   export
#   lda
#
# Examples:
#   bash run_pipeline.sh                        # Full pipeline
#   bash run_pipeline.sh --skip-jira            # Skip re-extracting Jira
#   bash run_pipeline.sh --step extract_jira    # Re-extract Jira only
#   bash run_pipeline.sh --run-lda              # Full pipeline + LDA
#   bash run_pipeline.sh --dry-run              # Preview steps
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/pipeline_$(date +%Y%m%d_%H%M%S).log"
RSCRIPT="Rscript --vanilla"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
SKIP_JIRA=false
SKIP_EXPORT=false
RUN_LDA=false
DRY_RUN=false
SINGLE_STEP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-jira)    SKIP_JIRA=true;    shift ;;
    --skip-export)  SKIP_EXPORT=true;  shift ;;
    --run-lda)      RUN_LDA=true;      shift ;;
    --dry-run)      DRY_RUN=true;      shift ;;
    --step)         SINGLE_STEP="$2";  shift 2 ;;
    --help)
      sed -n '/^# Usage/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1. Run with --help for usage."
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

info()    { log "INFO " "$@"; }
success() { log "OK   " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@"; }

run_r() {
  local label="$1"
  local script="$2"

  if [[ "$DRY_RUN" == true ]]; then
    info "DRY RUN — would run: Rscript $script"
    return 0
  fi

  info "Starting: $label"
  local start_ts
  start_ts=$(date +%s)

  if $RSCRIPT "$PROJECT_ROOT/$script" >> "$LOG_FILE" 2>&1; then
    local elapsed=$(( $(date +%s) - start_ts ))
    success "$label complete (${elapsed}s)"
  else
    error "$label FAILED — check $LOG_FILE"
    exit 1
  fi
}

# Guard: must run from project root
if [[ ! -f "$PROJECT_ROOT/config/config.yml" ]]; then
  echo "ERROR: config/config.yml not found."
  echo "  Copy config/config.yml.example to config/config.yml and fill in credentials."
  exit 1
fi

# -----------------------------------------------------------------------------
# Pipeline steps
# -----------------------------------------------------------------------------
info "============================================================"
info "Liferay Release Analytics Platform — Pipeline Run"
info "Project root: $PROJECT_ROOT"
info "Log: $LOG_FILE"
[[ "$DRY_RUN"    == true ]] && info "Mode: DRY RUN"
[[ "$SKIP_JIRA"  == true ]] && info "Skipping Jira extraction"
[[ "$SKIP_EXPORT" == true ]] && info "Skipping Looker export"
[[ "$RUN_LDA"    == true ]] && info "LDA topic analysis enabled"
[[ -n "$SINGLE_STEP" ]]    && info "Single step mode: $SINGLE_STEP"
info "============================================================"

step_sync_releases() {
  run_r "sync_releases" "utils/sync_releases.R"
}

step_load_map() {
  run_r "load_module_component_map" "utils/load_module_component_map.R"
}

step_ingest_churn() {
  run_r "ingest_churn_csv" "utils/ingest_churn_csv.R"
}

step_extract_jira() {
  if [[ "$SKIP_JIRA" == true ]]; then
    warn "Skipping Jira extraction (--skip-jira)"
    if [[ ! -f "$PROJECT_ROOT/staging/raw_jira_issues.rds" ]]; then
      error "staging/raw_jira_issues.rds not found — cannot skip Jira on first run"
      exit 1
    fi
    return 0
  fi
  run_r "extract_jira" "extract/extract_jira.R"
}

step_transform() {
  run_r "transform_forecast_input" "transform/transform_forecast_input.R"
}

step_export() {
  if [[ "$SKIP_EXPORT" == true ]]; then
    warn "Skipping Looker export (--skip-export)"
    return 0
  fi
  run_r "export_looker" "utils/export_looker.R"
}

step_lda() {
  if [[ "$RUN_LDA" == true ]]; then
    run_r "lda_analysis" "reports/release_landscape/lda_analysis.R"
  else
    info "Skipping LDA (use --run-lda to include)"
  fi
}

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------
if [[ -n "$SINGLE_STEP" ]]; then
  # Single step mode
  case "$SINGLE_STEP" in
    sync_releases)  step_sync_releases ;;
    load_map)       step_load_map ;;
    ingest_churn)   step_ingest_churn ;;
    extract_jira)   step_extract_jira ;;
    transform)      step_transform ;;
    export)         step_export ;;
    lda)            RUN_LDA=true; step_lda ;;
    *)
      error "Unknown step: $SINGLE_STEP"
      error "Valid steps: sync_releases, load_map, ingest_churn, extract_jira, transform, export, lda"
      exit 1
      ;;
  esac
else
  # Full pipeline
  PIPELINE_START=$(date +%s)

  step_sync_releases
  step_load_map
  step_ingest_churn
  step_extract_jira
  step_transform
  step_export
  step_lda

  PIPELINE_ELAPSED=$(( $(date +%s) - PIPELINE_START ))
  info "============================================================"
  success "Pipeline complete in ${PIPELINE_ELAPSED}s"
  info "Exports: $PROJECT_ROOT/reports/situation_deck/exports/"
  info "         $PROJECT_ROOT/reports/release_landscape/exports/"
  info "Log:     $LOG_FILE"
  info "============================================================"
fi