# =============================================================================
# transform_normalize.R
# Calculates p95 denominators for each scoring signal
# These are used to normalize raw scores to 0-1 range
#
# Signals with data:
#   - Churn (commit count + unique authors at 30/90/365d)
#   - Defects (bug count at 30/90/365d)
#   - Test failure rate
#   - Test co-failure score
#
# Signals pending:
#   - Complexity (SonarQube — cyclomatic, cognitive, violations)
#   - Dependencies (import scan)
#
# Output: scoring_normalization (PostgreSQL)
#         staging/normalization_params.rds
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_normalize started ---")

source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

scoring_version <- cfg$scoring$scoring_version

# Helper: safe p95 from a numeric vector
p95 <- function(x) {
  x <- x[!is.na(x) & x > 0]
  if (length(x) == 0) return(NA_real_)
  round(quantile(x, 0.95), 4)
}

# -----------------------------------------------------------------------------
# Step 1 — Churn p95 denominators
# -----------------------------------------------------------------------------
log_info("Calculating churn p95 denominators...")

churn <- dbGetQuery(con, "
  SELECT window_days, commit_count, unique_authors
  FROM fact_file_churn
")

churn_commit_p95_30d  <- p95(churn$commit_count[churn$window_days == 30])
churn_commit_p95_90d  <- p95(churn$commit_count[churn$window_days == 90])
churn_commit_p95_365d <- p95(churn$commit_count[churn$window_days == 365])
churn_author_p95_90d  <- p95(churn$unique_authors[churn$window_days == 90])

log_info("  Churn commit p95 — 30d: {churn_commit_p95_30d}, 90d: {churn_commit_p95_90d}, 365d: {churn_commit_p95_365d}")
log_info("  Churn author p95 — 90d: {churn_author_p95_90d}")

# -----------------------------------------------------------------------------
# Step 2 — Defect p95 denominators
# -----------------------------------------------------------------------------
log_info("Calculating defect p95 denominators...")

defects <- dbGetQuery(con, "
  SELECT window_days, bug_count, severity_weighted_score
  FROM fact_defect_history
")

defect_p95_30d  <- p95(defects$bug_count[defects$window_days == 30])
defect_p95_90d  <- p95(defects$bug_count[defects$window_days == 90])
defect_p95_365d <- p95(defects$bug_count[defects$window_days == 365])

log_info("  Defect bug count p95 — 30d: {defect_p95_30d}, 90d: {defect_p95_90d}, 365d: {defect_p95_365d}")

# -----------------------------------------------------------------------------
# Step 3 — Test failure p95 denominators
# failure_rate and co_failure_score are already 0-1, no p95 needed
# But we store the p95 of failure_rate for reference
# -----------------------------------------------------------------------------
log_info("Calculating test failure p95 denominators...")

test_fail <- dbGetQuery(con, "
  SELECT failure_rate, co_failure_score
  FROM fact_test_failure
")

test_failure_rate_p95   <- p95(test_fail$failure_rate)
test_cofailure_p95      <- p95(test_fail$co_failure_score)

log_info("  Test failure rate p95: {test_failure_rate_p95}")
log_info("  Test co-failure score p95: {test_cofailure_p95}")

# -----------------------------------------------------------------------------
# Step 4 — Complexity p95 from SonarQube data
# -----------------------------------------------------------------------------
log_info("Calculating complexity p95 denominators...")

complexity_data <- dbGetQuery(con, "
  SELECT cyclomatic_complexity, cognitive_complexity
  FROM fact_file_complexity
  WHERE cyclomatic_complexity > 0
")

if (nrow(complexity_data) > 0) {
  complexity_p95 <- p95(complexity_data$cyclomatic_complexity)
  cognitive_p95  <- p95(complexity_data$cognitive_complexity)
  log_info("  Complexity p95 — cyclomatic: {complexity_p95}, cognitive: {cognitive_p95}")
} else {
  complexity_p95 <- NA_real_
  cognitive_p95  <- NA_real_
  log_info("  Complexity p95: no data found")
}

# -----------------------------------------------------------------------------
# Step 5 — Dependency p95 (placeholder — import scan pending)
# -----------------------------------------------------------------------------
log_info("Dependency p95: pending import scan data")
dependency_p95 <- NA_real_

# -----------------------------------------------------------------------------
# Step 6 — Assemble normalization params
# -----------------------------------------------------------------------------
norm_params <- data.frame(
  scoring_version       = scoring_version,
  complexity_p95        = complexity_p95,
  cognitive_p95         = cognitive_p95,
  churn_commit_p95_30d  = churn_commit_p95_30d,
  churn_commit_p95_90d  = churn_commit_p95_90d,
  churn_commit_p95_365d = churn_commit_p95_365d,
  churn_author_p95_90d  = churn_author_p95_90d,
  defect_p95_30d        = defect_p95_30d,
  defect_p95_90d        = defect_p95_90d,
  defect_p95_365d       = defect_p95_365d,
  test_failure_rate_p95 = test_failure_rate_p95,
  test_cofailure_p95    = test_cofailure_p95,
  dependency_p95        = dependency_p95,
  stringsAsFactors      = FALSE
)

log_info("Normalization params assembled:")
for (col in names(norm_params)[names(norm_params) != "scoring_version"]) {
  log_info("  {col}: {norm_params[[col]]}")
}

# -----------------------------------------------------------------------------
# Step 7 — Upsert into scoring_normalization
# -----------------------------------------------------------------------------
dbExecute(con, "
  INSERT INTO scoring_normalization (
    scoring_version,
    complexity_p95, cognitive_p95,
    churn_commit_p95_30d, churn_commit_p95_90d, churn_commit_p95_365d,
    churn_author_p95_90d,
    defect_p95_30d, defect_p95_90d, defect_p95_365d,
    dependency_p95,
    calculated_at
  )
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, NOW())
", params = list(
  scoring_version,
  complexity_p95, cognitive_p95,
  churn_commit_p95_30d, churn_commit_p95_90d, churn_commit_p95_365d,
  churn_author_p95_90d,
  defect_p95_30d, defect_p95_90d, defect_p95_365d,
  dependency_p95
))

# -----------------------------------------------------------------------------
# Step 8 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(norm_params, "staging/normalization_params.rds")
log_info("Saved to staging/normalization_params.rds")
log_info("--- transform_normalize complete ---")
