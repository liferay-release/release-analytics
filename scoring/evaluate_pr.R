#!/usr/bin/env Rscript
# =============================================================================
# evaluate_pr.R
# Called by evaluate_pr.sh — queries risk scores for changed files
# and prints a formatted branch risk report to terminal
#
# Args (passed from shell script):
#   --branch        branch name
#   --base          base branch
#   --author        PR author
#   --files         pipe-separated list of changed file paths
#   --pr-url        PR URL (optional)
#   --pipeline-dir  path to risk pipeline root directory
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(DBI)
  library(RPostgres)
  library(yaml)
  library(glue)
})

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)

get_arg <- function(flag, default = "") {
  idx <- which(args == flag)
  if (length(idx) == 0 || idx == length(args)) return(default)
  args[idx + 1]
}

branch       <- get_arg("--branch")
base         <- get_arg("--base",    "master")
files_raw    <- get_arg("--files")
pr_url       <- get_arg("--pr-url",  "")
pipeline_dir <- get_arg("--pipeline-dir", getwd())

# Parse pipe-separated file list
changed_files <- strsplit(files_raw, "\\|")[[1]]
changed_files <- changed_files[nchar(changed_files) > 0]

# Separate test files from production code files
test_files <- changed_files[grepl(
  "Test\\.java$|TestCase\\.java$|\\.spec\\.ts$|\\.test\\.js$|\\.test\\.ts$|/test/|/testIntegration/",
  changed_files
)]

code_files <- changed_files[grepl(
  "\\.java$|\\.ts$|\\.tsx$|\\.js$|\\.jsp$|\\.jsx$",
  changed_files
)]
code_files <- code_files[!code_files %in% test_files]

cat("Code files to evaluate:", length(code_files), "\n")
if (length(test_files) > 0) cat("Test files detected:    ", length(test_files), "\n")

if (length(code_files) == 0 && length(test_files) == 0) {
  cat("No changed files to evaluate.\n")
  quit(status = 0)
}

# -----------------------------------------------------------------------------
# Connect to DB
# -----------------------------------------------------------------------------
setwd(pipeline_dir)
source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

scoring_version <- as.character(cfg$scoring$scoring_version)

# -----------------------------------------------------------------------------
# Look up risk scores for changed code files
# -----------------------------------------------------------------------------
scored_files <- data.frame()

if (length(code_files) > 0) {
  files_df <- data.frame(file_path = code_files, stringsAsFactors = FALSE)
  dbWriteTable(con, "temp_pr_files", files_df, temporary = TRUE, overwrite = TRUE)
  
  scored_files <- dbGetQuery(con, glue("
    SELECT
      f.file_path,
      f.language,
      m.module_name,
      s.composite_risk,
      s.risk_tier,
      s.churn_score,
      s.defect_score,
      s.test_score,
      s.complexity_score,
      s.dependency_score
    FROM temp_pr_files t
    JOIN dim_file f ON t.file_path = f.file_path
    LEFT JOIN fact_file_risk_score s ON f.file_id = s.file_id
      AND s.scoring_version = '{scoring_version}'
    LEFT JOIN dim_module m ON s.module_id = m.module_id
    ORDER BY s.composite_risk DESC NULLS LAST
  "))
  
  dbExecute(con, "DROP TABLE IF EXISTS temp_pr_files")
}

# Files not in dim_file (new files added in this PR)
new_files <- code_files[!code_files %in% scored_files$file_path]

# Files in dim_file but not scored (no risk score yet)
unscored <- scored_files |> filter(is.na(composite_risk))
scored   <- scored_files |> filter(!is.na(composite_risk))

# -----------------------------------------------------------------------------
# Compute PR-level summary
# -----------------------------------------------------------------------------
tier_order <- c("CRITICAL", "HIGH", "MEDIUM", "LOW")

if (nrow(scored) > 0) {
  avg_risk <- round(mean(scored$composite_risk), 4)
  max_risk <- round(max(scored$composite_risk), 4)
  
  pr_tier <- case_when(
    max_risk >= 0.75 ~ "CRITICAL",
    max_risk >= 0.50 ~ "HIGH",
    max_risk >= 0.25 ~ "MEDIUM",
    TRUE             ~ "LOW"
  )
  
  tier_counts <- scored |>
    count(risk_tier) |>
    right_join(data.frame(risk_tier = tier_order), by = "risk_tier") |>
    mutate(n = coalesce(n, 0L))
} else {
  avg_risk    <- 0
  max_risk    <- 0
  pr_tier     <- "LOW"
  tier_counts <- data.frame(risk_tier = tier_order, n = 0L)
}

# -----------------------------------------------------------------------------
# Blast radius — which modules are impacted by the changed modules
# -----------------------------------------------------------------------------
affected_modules <- scored |>
  filter(!is.na(module_name)) |>
  distinct(module_name) |>
  pull(module_name)

blast_radius <- data.frame()

if (length(affected_modules) > 0) {
  modules_sql <- paste(glue("'{affected_modules}'"), collapse = ",")
  
  blast_radius <- dbGetQuery(con, glue("
    SELECT
      md.module_name              AS changed_module,
      md.dependent_count          AS direct_dependents,
      md.transitive_count         AS transitive_dependents,
      md.total_blast,
      md.is_shared_util,
      md.blast_score,
      md.integration_score,
      md.outgoing_count,
      md.outgoing_critical_count,
      md.dependency_score
    FROM fact_module_dependencies md
    WHERE md.module_name IN ({modules_sql})
    ORDER BY md.dependency_score DESC
  "))
}

# -----------------------------------------------------------------------------
# Test recommendations — top signal tests from affected components
# Uses fact_test_quality (signal = jira-linked failure correlation)
# Note: signal is a weak proxy — jira links are mostly investigation tickets.
# Kept for directional value until better linkage is available.
# -----------------------------------------------------------------------------
test_recommendations <- character(0)
suggested_tests      <- data.frame()

if (length(affected_modules) > 0) {
  modules_sql <- paste(glue("'{affected_modules}'"), collapse = ",")

  # Component names for affected modules
  affected_components <- dbGetQuery(con, glue("
    SELECT DISTINCT c.component_name
    FROM dim_module m
    JOIN module_component_map mc ON m.module_id = mc.module_id
    JOIN dim_component c         ON mc.component_id = c.component_id
    WHERE m.module_name IN ({modules_sql})
    AND m.module_name NOT IN ('portal-impl', 'portal-kernel', 'portal-web')
  ")) |> pull(component_name)

  # Top signal test cases within those components
  if (length(affected_components) > 0) {
    components_sql <- paste(glue("'{affected_components}'"), collapse = ",")
    suggested_tests <- dbGetQuery(con, glue("
      SELECT
        case_name,
        component_name,
        signal_score,
        bug_catch_rate,
        total_fail_builds
      FROM fact_test_quality
      WHERE component_name IN ({components_sql})
      AND signal_score > 0
      ORDER BY signal_score DESC
      LIMIT 10
    "))
  }
}

# -----------------------------------------------------------------------------
# Write to pr_evaluation and pr_file_change
# -----------------------------------------------------------------------------
eval_id <- tryCatch({
  invisible(dbExecute(con, "
    INSERT INTO pr_evaluation (branch_name, base_branch, author, pr_url, triggered_by)
    VALUES ($1, $2, $3, $4, 'manual')
  ", params = list(branch, base, author, if (nchar(pr_url) > 0) pr_url else NA)))
  invisible(dbGetQuery(con, "SELECT MAX(eval_id) as id FROM pr_evaluation")$id)
}, error = function(e) NA)

if (!is.na(eval_id) && nrow(scored) > 0) {
  changes_to_insert <- scored |>
    select(file_path, composite_risk, risk_tier) |>
    mutate(
      eval_id     = eval_id,
      change_type = "MODIFIED",
      is_new_file = FALSE
    )
  dbWriteTable(con, "temp_pr_changes", changes_to_insert,
               temporary = TRUE, overwrite = TRUE)
  dbExecute(con, "
    INSERT INTO pr_file_change (eval_id, file_path, file_risk_score, risk_tier, change_type, is_new_file)
    SELECT eval_id, file_path, composite_risk, risk_tier, change_type, is_new_file
    FROM temp_pr_changes
  ")
  dbExecute(con, "DROP TABLE IF EXISTS temp_pr_changes")
}

# -----------------------------------------------------------------------------
# Print report
# -----------------------------------------------------------------------------
tier_colors <- c(
  CRITICAL = "\033[1;31m",  # bold red
  HIGH     = "\033[0;31m",  # red
  MEDIUM   = "\033[0;33m",  # yellow
  LOW      = "\033[0;32m",  # green
  RESET    = "\033[0m"
)

color <- function(text, tier) {
  glue("{tier_colors[tier]}{text}{tier_colors['RESET']}")
}

cat("\n")
cat("═══════════════════════════════════════════════════════════════════════════════\n")
cat(glue("  RISK ASSESSMENT — {branch}"), "\n")
cat("═══════════════════════════════════════════════════════════════════════════════\n")
if (nchar(pr_url) > 0) cat(glue("  {pr_url}"), "\n")
cat(glue("  Base (compared against): {base}"), "\n")
cat("───────────────────────────────────────────────────────────────────────────────\n")

# Overall risk
cat(glue("  Overall Risk:   {color(pr_tier, pr_tier)} ({max_risk})"), "\n")
cat(glue("  Avg File Risk:  {avg_risk}"), "\n")
cat(glue("  Files Changed:  {length(code_files)}"), "\n")
cat(glue("    Scored:       {nrow(scored)}"), "\n")
if (length(test_files) > 0) cat(glue("    Test files:   {length(test_files)} (see below)"), "\n")
if (length(new_files)  > 0) cat(glue("    New files:    {length(new_files)} (no history)"), "\n")
if (nrow(unscored)     > 0) cat(glue("    Unscored:     {nrow(unscored)} (not in risk DB)"), "\n")
cat("\n")

# Tier breakdown
cat("  Risk Distribution:\n")
for (tier in tier_order) {
  n <- tier_counts$n[tier_counts$risk_tier == tier]
  if (n > 0) cat(glue("    {color(tier, tier)}: {n} files"), "\n")
}
cat("\n")

# Top risk files
cat("───────────────────────────────────────────────────────────────────────────────\n")
cat("  TOP RISK FILES\n")
cat("───────────────────────────────────────────────────────────────────────────────\n")

top_files <- scored |>
  filter(risk_tier %in% c("CRITICAL", "HIGH")) |>
  head(10)

if (nrow(top_files) == 0) {
  top_files <- scored |> head(5)
}

for (i in seq_len(nrow(top_files))) {
  f <- top_files[i, ]
  fname <- basename(f$file_path)
  cat(glue("  {color(f$risk_tier, f$risk_tier)} {fname}  ({f$composite_risk})"), "\n")
  cat(glue("    module:     {coalesce(f$module_name, 'unknown')}"), "\n")
  cat(glue("    churn: {f$churn_score}  defect: {f$defect_score}  test: {f$test_score}  complexity: {f$complexity_score}  dependency: {f$dependency_score}"), "\n")
  cat("\n")
}

# Dependency risk — blast radius and integration depth
if (nrow(blast_radius) > 0) {
  has_blast       <- any(blast_radius$total_blast > 0)
  has_integration <- any(blast_radius$outgoing_critical_count > 0)

  if (has_blast || has_integration) {
    cat("───────────────────────────────────────────────────────────────────────────────\n")
    cat("  DEPENDENCY RISK\n")
    cat("───────────────────────────────────────────────────────────────────────────────\n")

    if (has_blast) {
      cat("  Blast Radius (modules that depend on changed code):\n")
      for (i in seq_len(nrow(blast_radius))) {
        b <- blast_radius[i, ]
        if (b$total_blast == 0) next
        shared_flag <- if (isTRUE(b$is_shared_util)) "  ⚠ shared utility" else ""
        cat(glue("    {b$changed_module}{shared_flag}"), "\n")
        cat(glue("      direct: {b$direct_dependents}  transitive: {b$transitive_dependents}  total: {b$total_blast}"), "\n")
      }
      cat("\n")
    }

    if (has_integration) {
      cat("  Integration Depth (critical infrastructure this code imports):\n")
      integration_modules <- blast_radius |>
        filter(outgoing_critical_count > 0) |>
        arrange(desc(integration_score)) |>
        head(7)
      n_integration_total <- sum(blast_radius$outgoing_critical_count > 0)
      for (i in seq_len(nrow(integration_modules))) {
        b <- integration_modules[i, ]
        cat(glue("    {b$changed_module}"), "\n")
        cat(glue("      {b$outgoing_critical_count} of {b$outgoing_count} imports are critical infrastructure  (integration: {b$integration_score})"), "\n")
      }
      if (n_integration_total > 7) cat(glue("  ... and {n_integration_total - 7} more modules"), "\n")
      cat("\n")
    }
  }
}

# Suggested tests from fact_test_quality
if (nrow(suggested_tests) > 0) {
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  cat("  SUGGESTED TESTS\n")
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  for (i in seq_len(nrow(suggested_tests))) {
    t <- suggested_tests[i, ]
    cat(glue("  [{t$component_name}] {t$case_name}"), "\n")
    cat(glue("    signal: {t$signal_score}  bug_catch_rate: {t$bug_catch_rate}  fail_builds: {t$total_fail_builds}"), "\n")
  }
  cat("\n")
}

# Test files section
if (length(test_files) > 0) {
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  cat("  TEST FILES CHANGED\n")
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  for (f in head(test_files, 10)) {
    cat(glue("  [TEST] {basename(f)}"), "\n")
  }
  if (length(test_files) > 10) cat(glue("  ... and {length(test_files) - 10} more"), "\n")
  cat("\n")
}

# New files warning
if (length(new_files) > 0) {
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  cat("  NEW FILES (no risk history / history not captured in latest scan)\n")
  cat("───────────────────────────────────────────────────────────────────────────────\n")
  for (f in head(new_files, 10)) {
    cat(glue("  + {basename(f)}"), "\n")
  }
  if (length(new_files) > 10) cat(glue("  ... and {length(new_files) - 10} more"), "\n")
  cat("\n")
}

cat("═══════════════════════════════════════════════════════════════════════════════\n")
cat(glue("  Eval END"), "\n")
cat("═══════════════════════════════════════════════════════════════════════════════\n")
cat("\n")