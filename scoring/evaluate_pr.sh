#!/bin/bash
# =============================================================================
# evaluate_pr.sh
# Evaluates risk for a given branch against base branch
#
# Usage:
#   ./evaluate_pr.sh <branch-name> [flags]
#
# Flags:
#   --run-test       Run ModulesStructureTest (ant step) — skipped by default
#   --run-compile    Run gw clean deploy on affected modules — skipped by default
#
# Examples:
#   ./evaluate_pr.sh branchName
#   ./evaluate_pr.sh branchName --run-test
#   ./evaluate_pr.sh branchName --run-test --run-compile
# =============================================================================

set -e

SKIP_TEST=true
SKIP_COMPILE=true
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    --run-test)    SKIP_TEST=false ;;
    --run-compile) SKIP_COMPILE=false ;;
    *)             POSITIONAL+=("$arg") ;;
  esac
done

BRANCH="${POSITIONAL[0]}"
BASE="${POSITIONAL[1]:-master}"
AUTHOR="${POSITIONAL[2]:-$(git config user.name)}"
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git rev-parse --show-toplevel)"

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------
if [ -z "$BRANCH" ]; then
  echo "Usage: ./evaluate_pr.sh <branch-name> [base-branch] [author] [--run-test] [--run-compile]"
  exit 1
fi

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Error: must be run from within the liferay-portal git repository"
  exit 1
fi

if ! git rev-parse --verify "$BRANCH" > /dev/null 2>&1; then
  echo "Error: branch '$BRANCH' not found"
  exit 1
fi

if ! git rev-parse --verify "$BASE" > /dev/null 2>&1; then
  echo "Error: base branch '$BASE' not found"
  exit 1
fi

# -----------------------------------------------------------------------------
# Get changed files via git diff
# -----------------------------------------------------------------------------
echo ""
echo "Comparing: $BRANCH → $BASE"
if $SKIP_TEST;    then echo "  [--skip-test]    ModulesStructureTest skipped"; fi
if $SKIP_COMPILE; then echo "  [--skip-compile] gw clean deploy skipped"; fi
echo ""

CHANGED_FILES=$(git diff --name-only "$BASE"..."$BRANCH" 2>/dev/null)

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files found between $BASE and $BRANCH"
  exit 0
fi

FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
echo "Files changed: $FILE_COUNT"

# Get PR URL if available (GitHub CLI)
PR_URL=""
if command -v gh &> /dev/null; then
  PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null || echo "")
fi

# =============================================================================
# STEP 1 — Run ModulesStructureTest
# =============================================================================
echo ""
echo "───────────────────────────────────────────────────────────────────────────────"

if $SKIP_TEST; then
  echo "  STEP 1: ModulesStructureTest [SKIPPED]"
  echo "───────────────────────────────────────────────────────────────────────────────"
else
  echo "  STEP 1: Running ModulesStructureTest"
  echo "───────────────────────────────────────────────────────────────────────────────"

  PORTAL_KERNEL_DIR="${REPO_DIR}/portal-kernel"

  if [ ! -d "$PORTAL_KERNEL_DIR" ]; then
    echo "Error: portal-kernel directory not found at $PORTAL_KERNEL_DIR"
    exit 1
  fi

  if ! command -v ant &> /dev/null; then
    echo "Error: 'ant' is not available on PATH"
    exit 1
  fi

  ANT_OUTPUT=$(
    cd "$PORTAL_KERNEL_DIR"
    ant test-class -Dtest.class=ModulesStructureTest 2>&1
  )
  ANT_EXIT=$?

  echo "$ANT_OUTPUT"

  # Ant exits 0 even when JUnit reports failures — check output explicitly
  JUNIT_FAILURES=$(echo "$ANT_OUTPUT" | grep -E '^\s+\[junit\] Tests run:.*Failures: [1-9]' | head -1)
  JUNIT_FAILED_LINE=$(echo "$ANT_OUTPUT" | grep -E 'Test .* FAILED' | head -1)

  if [ $ANT_EXIT -ne 0 ] || [ -n "$JUNIT_FAILURES" ] || [ -n "$JUNIT_FAILED_LINE" ]; then
    echo ""
    echo "✗ ModulesStructureTest FAILED"
    if [ -n "$JUNIT_FAILURES" ]; then
      echo "  $(echo "$JUNIT_FAILURES" | xargs)"
    fi
    echo "  Fix structural failures before deploying. Risk score aborted."
    exit 1
  fi

  echo ""
  echo "✓ ModulesStructureTest passed"
fi

# =============================================================================
# STEP 2 — Identify affected Gradle modules and run gw clean deploy
# =============================================================================
echo ""
echo "───────────────────────────────────────────────────────────────────────────────"

if $SKIP_COMPILE; then
  echo "  STEP 2: gw clean deploy [SKIPPED]"
  echo "───────────────────────────────────────────────────────────────────────────────"
else
  echo "  STEP 2: Running gw clean deploy on affected modules"
  echo "───────────────────────────────────────────────────────────────────────────────"

  if ! command -v gw &> /dev/null; then
    echo "Warning: 'gw' (Gradle wrapper) not found on PATH — skipping deploy step"
  else
    # Resolve unique module roots from changed file paths.
    # A module root is the nearest ancestor directory that contains a build.gradle.
    declare -A SEEN_MODULES

    while IFS= read -r file; do
      dir="$REPO_DIR/$(dirname "$file")"
      while [[ "$dir" != "$REPO_DIR" && "$dir" != "/" ]]; do
        if [[ -f "$dir/build.gradle" ]]; then
          if [[ -z "${SEEN_MODULES[$dir]+_}" ]]; then
            SEEN_MODULES["$dir"]=1
          fi
          break
        fi
        dir="$(dirname "$dir")"
      done
    done <<< "$CHANGED_FILES"

    if [ ${#SEEN_MODULES[@]} -eq 0 ]; then
      echo "  No Gradle modules detected in changed files — skipping deploy"
    else
      echo "  Modules to deploy:"
      for mod_dir in "${!SEEN_MODULES[@]}"; do
        rel_path="${mod_dir#$REPO_DIR/}"
        echo "    • $rel_path"
      done
      echo ""

      DEPLOY_FAILURES=0
      for mod_dir in "${!SEEN_MODULES[@]}"; do
        rel_path="${mod_dir#$REPO_DIR/}"
        echo "  → gw clean deploy: $rel_path"
        (
          cd "$mod_dir"
          gw clean deploy
        )
        GW_EXIT=$?
        if [ $GW_EXIT -ne 0 ]; then
          echo "  ✗ Deploy FAILED for $rel_path (exit $GW_EXIT)"
          DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
        else
          echo "  ✓ Deployed: $rel_path"
        fi
        echo ""
      done

      if [ $DEPLOY_FAILURES -gt 0 ]; then
        echo "✗ $DEPLOY_FAILURES module(s) failed to deploy. Risk score aborted."
        exit 1
      fi

      echo "✓ All modules deployed successfully"
    fi
  fi
fi

# =============================================================================
# STEP 3 — Pass to R for risk scoring
# =============================================================================
echo ""
echo "───────────────────────────────────────────────────────────────────────────────"
echo "  STEP 3: Computing risk score"
echo "───────────────────────────────────────────────────────────────────────────────"

CHANGED_FILES_CSV=$(echo "$CHANGED_FILES" | tr '\n' '|' | sed 's/|$//')

Rscript "${SCRIPT_DIR}/evaluate_pr.R" \
  --branch  "$BRANCH" \
  --base    "$BASE" \
  --author  "$AUTHOR" \
  --files   "$CHANGED_FILES_CSV" \
  --pr-url  "$PR_URL" \
  --pipeline-dir "$PLATFORM_DIR"