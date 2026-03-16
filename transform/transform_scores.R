# =============================================================================
# transform_scores.R
# Assembles composite risk scores for each file using all available signals
#
# Signals:
#   complexity  (28%) — SonarQube cyclomatic + cognitive + violations
#   churn       (25%) — git commit frequency + author turnover
#   defect      (20%) — Jira bug history weighted by severity
#   test        (15%) — Testray failure rate + co-failure score
#   dependency  (12%) — blast radius from module dependency graph
#
# Signals with no data default to 0 (conservative — won't inflate scores)
# Re-run this script after SonarQube and dependency data are available
#
# Output: fact_file_risk_score (PostgreSQL)
#         staging/transformed_scores.rds
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_scores started ---")

source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
weights         <- cfg$scoring$weights
scoring_version <- as.character(cfg$scoring$scoring_version)
weight_source   <- cfg$scoring$weight_source

w_complexity <- weights$complexity  # 0.28
w_churn      <- weights$churn       # 0.25
w_defect     <- weights$defect      # 0.20
w_test       <- weights$test        # 0.15
w_dependency <- weights$dependency  # 0.12

log_info("Scoring version: {scoring_version}")
log_info("Weights — complexity: {w_complexity}, churn: {w_churn}, defect: {w_defect}, test: {w_test}, dependency: {w_dependency}")

# -----------------------------------------------------------------------------
# Load normalization params (.rds — used by churn, defect, test signals)
# -----------------------------------------------------------------------------
norm <- readRDS("staging/normalization_params.rds")

# -----------------------------------------------------------------------------
# Step 1 — Load all files from dim_file
# Exclude test files and auto-generated classes from risk scoring
# -----------------------------------------------------------------------------
log_info("Loading dim_file...")

files <- dbGetQuery(con, "
  SELECT f.file_id, f.file_path, f.module_id, f.language
  FROM dim_file f
  WHERE f.is_active = TRUE
")

files <- files |>
  filter(!grepl(
    "Test\\.java$|TestCase\\.java$|TestUtil\\.java$|/test/|/testIntegration/|/generated-sources/|/generated/",
    file_path, ignore.case = FALSE
  )) |>
  filter(!grepl("^Base[A-Z].*Impl\\.java$", basename(file_path)))

log_info("Active files after excluding test/generated files: {nrow(files)}")

# -----------------------------------------------------------------------------
# Step 2 — Churn signal (file level)
# Multi-window decay: 30d: 0.50, 90d: 0.30, 365d: 0.20
# -----------------------------------------------------------------------------
log_info("Loading churn signal...")

churn_raw <- dbGetQuery(con, "
  SELECT file_id, window_days, commit_count, unique_authors
  FROM fact_file_churn
")

churn_scores <- churn_raw |>
  mutate(
    p95_commit = ifelse(window_days == 30,  norm$churn_commit_p95_30d,
                        ifelse(window_days == 90,  norm$churn_commit_p95_90d,
                               norm$churn_commit_p95_365d)),
    p95_author = norm$churn_author_p95_90d,
    
    commit_norm  = pmin(commit_count   / p95_commit, 1.0),
    author_norm  = pmin(unique_authors / p95_author, 1.0),
    
    window_score  = (commit_norm * 0.70) + (author_norm * 0.30),
    window_weight = ifelse(window_days == 30,  0.50,
                           ifelse(window_days == 90,  0.30, 0.20))
  ) |>
  group_by(file_id) |>
  summarise(
    churn_score = round(sum(window_score * window_weight) / sum(window_weight), 4),
    .groups = "drop"
  )

log_info("Churn scores calculated: {nrow(churn_scores)} files")

# -----------------------------------------------------------------------------
# Step 3 — Defect signal (module level -> file level)
# Multi-window decay: 30d: 0.50, 90d: 0.30, 365d: 0.20
# -----------------------------------------------------------------------------
log_info("Loading defect signal...")

defect_raw <- dbGetQuery(con, "
  SELECT module_id, window_days, bug_count, severity_weighted_score
  FROM fact_defect_history
")

defect_scores <- defect_raw |>
  mutate(
    p95_bug = ifelse(window_days == 30,  norm$defect_p95_30d,
                     ifelse(window_days == 90,  norm$defect_p95_90d,
                            norm$defect_p95_365d)),
    
    bug_norm     = pmin(bug_count / p95_bug, 1.0),
    window_score = (bug_norm * 0.60) + (severity_weighted_score * 0.40),
    
    window_weight = ifelse(window_days == 30,  0.50,
                           ifelse(window_days == 90,  0.30, 0.20))
  ) |>
  group_by(module_id) |>
  summarise(
    defect_score = round(sum(window_score * window_weight) / sum(window_weight), 4),
    .groups = "drop"
  )

log_info("Defect scores calculated: {nrow(defect_scores)} modules")

# -----------------------------------------------------------------------------
# Step 4 — Test signal (module level)
# -----------------------------------------------------------------------------
log_info("Loading test signal...")

test_raw <- dbGetQuery(con, "
  SELECT module_id, window_days, failure_rate, co_failure_score
  FROM fact_test_failure
")

log_info("Test data loaded: {n_distinct(test_raw$module_id)} modules")

if (nrow(test_raw) > 0) {
  test_scores <- test_raw |>
    mutate(
      failure_norm   = pmin(failure_rate    / norm$test_failure_rate_p95, 1.0),
      cofailure_norm = pmin(co_failure_score / norm$test_cofailure_p95,   1.0),
      window_score   = (failure_norm * 0.70) + (cofailure_norm * 0.30),
      window_weight  = ifelse(window_days == 30,  0.50,
                              ifelse(window_days == 90,  0.30, 0.20))
    ) |>
    group_by(module_id) |>
    summarise(
      test_score = round(sum(window_score * window_weight) / sum(window_weight), 4),
      .groups = "drop"
    )
} else {
  test_scores <- data.frame(module_id = integer(0), test_score = numeric(0))
}

log_info("Test scores calculated: {nrow(test_scores)} modules")

# -----------------------------------------------------------------------------
# Step 5 — Complexity signal (file level)
# Uses scoring_normalization table for p95 denominators (not norm .rds)
# Returns 0 if no SonarQube data yet
# -----------------------------------------------------------------------------
log_info("Loading complexity signal...")

complexity_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_file_complexity")$n
log_info("Complexity data available: {complexity_count} files")

if (complexity_count > 0) {
  complexity_norm <- dbGetQuery(con, glue("
    SELECT complexity_p95, cognitive_p95
    FROM scoring_normalization
    WHERE scoring_version = '{scoring_version}'
    ORDER BY calculated_at DESC
    LIMIT 1
  "))
  
  complexity_raw <- dbGetQuery(con, "
    SELECT file_id, cyclomatic_complexity, cognitive_complexity,
           violation_count, violation_blocker_count, violation_critical_count
    FROM fact_file_complexity
  ")
  
  complexity_scores <- complexity_raw |>
    mutate(
      cyclomatic_norm = pmin(cyclomatic_complexity / complexity_norm$complexity_p95, 1.0),
      cognitive_norm  = pmin(cognitive_complexity  / complexity_norm$cognitive_p95,  1.0),
      violation_score = pmin(
        (violation_blocker_count * 3 + violation_critical_count * 2 + violation_count) /
          (complexity_norm$complexity_p95 * 5),
        1.0
      ),
      complexity_score = round(
        (cyclomatic_norm * 0.35) + (cognitive_norm * 0.40) + (violation_score * 0.25),
        4
      )
    ) |>
    select(file_id, complexity_score)
  
  log_info("Complexity scores calculated: {nrow(complexity_scores)} files")
} else {
  complexity_scores <- data.frame(file_id = integer(0), complexity_score = numeric(0))
  log_info("Complexity signal defaulting to 0 — no SonarQube data yet")
}

# -----------------------------------------------------------------------------
# Step 6 — Dependency signal (file level)
# Returns 0 if no dependency scan data yet
# -----------------------------------------------------------------------------
log_info("Loading dependency signal...")

dependency_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_file_dependencies")$n
log_info("Dependency data available: {dependency_count} files")

if (dependency_count > 0) {
  dependency_raw <- dbGetQuery(con, "
    SELECT file_id, dependency_score
    FROM fact_file_dependencies
  ")
  log_info("Dependency scores loaded: {nrow(dependency_raw)} files")
} else {
  dependency_raw <- data.frame(file_id = integer(0), dependency_score = numeric(0))
  log_info("Dependency signal defaulting to 0 — no dependency scan data yet")
}

# -----------------------------------------------------------------------------
# Step 7 — Assemble composite scores per file
# -----------------------------------------------------------------------------
log_info("Assembling composite scores...")

scores <- files |>
  left_join(churn_scores,      by = "file_id") |>
  left_join(defect_scores,     by = "module_id") |>
  left_join(test_scores,       by = "module_id") |>
  left_join(complexity_scores, by = "file_id") |>
  left_join(dependency_raw,    by = "file_id") |>
  mutate(
    churn_score      = coalesce(churn_score,      0),
    defect_score     = coalesce(defect_score,     0),
    test_score       = coalesce(test_score,       0),
    complexity_score = coalesce(complexity_score, 0),
    dependency_score = coalesce(dependency_score, 0)
  ) |>
  mutate(
    composite_raw = (complexity_score * w_complexity) +
      (churn_score      * w_churn)      +
      (defect_score     * w_defect)      +
      (test_score       * w_test)        +
      (dependency_score * w_dependency),
    
    signals_above_50 = (complexity_score > 0.50) +
      (churn_score      > 0.50) +
      (defect_score     > 0.50) +
      (test_score       > 0.50) +
      (dependency_score > 0.50),
    
    amplifier = case_when(
      signals_above_50 >= 4 ~ 1.25,
      signals_above_50 == 3 ~ 1.15,
      signals_above_50 == 2 ~ 1.05,
      TRUE                  ~ 1.00
    ),
    
    composite_risk = round(pmin(composite_raw * amplifier, 1.0), 4),
    
    risk_tier = case_when(
      composite_risk >= 0.75 ~ "CRITICAL",
      composite_risk >= 0.50 ~ "HIGH",
      composite_risk >= 0.25 ~ "MEDIUM",
      TRUE                   ~ "LOW"
    )
  )

log_info("Composite scores assembled: {nrow(scores)} files")
log_info("Risk tier distribution:")
tier_counts <- scores |> count(risk_tier, sort = TRUE)
for (i in seq_len(nrow(tier_counts))) {
  pct <- round(tier_counts$n[i] / nrow(scores) * 100, 1)
  log_info("  {tier_counts$risk_tier[i]}: {tier_counts$n[i]} files ({pct}%)")
}

# -----------------------------------------------------------------------------
# Step 8 — Bulk upsert into fact_file_risk_score
# -----------------------------------------------------------------------------
log_info("Loading fact_file_risk_score...")

scores_to_load <- scores |>
  mutate(
    weight_source   = weight_source,
    scoring_version = scoring_version
  ) |>
  select(file_id, module_id, complexity_score, churn_score, defect_score,
         test_score, dependency_score, composite_risk, risk_tier,
         weight_source, scoring_version)

dbWriteTable(con, "temp_scores", scores_to_load,
             temporary = TRUE, overwrite = TRUE)

dbExecute(con, "
  INSERT INTO fact_file_risk_score (
    file_id, module_id, complexity_score, churn_score, defect_score,
    test_score, dependency_score, composite_risk, risk_tier,
    weight_source, scoring_version, scored_at
  )
  SELECT file_id, module_id, complexity_score, churn_score, defect_score,
         test_score, dependency_score, composite_risk, risk_tier,
         weight_source, scoring_version, NOW()
  FROM temp_scores
  ON CONFLICT (file_id, scoring_version) DO UPDATE SET
    module_id        = EXCLUDED.module_id,
    complexity_score = EXCLUDED.complexity_score,
    churn_score      = EXCLUDED.churn_score,
    defect_score     = EXCLUDED.defect_score,
    test_score       = EXCLUDED.test_score,
    dependency_score = EXCLUDED.dependency_score,
    composite_risk   = EXCLUDED.composite_risk,
    risk_tier        = EXCLUDED.risk_tier,
    scored_at        = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS temp_scores")

# -----------------------------------------------------------------------------
# Step 9 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(scores, "staging/transformed_scores.rds")
log_info("Saved to staging/transformed_scores.rds")

# -----------------------------------------------------------------------------
# Summary — top 20 highest risk files
# -----------------------------------------------------------------------------
final_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_file_risk_score")
log_info("fact_file_risk_score total rows: {final_count$n}")

log_info("Top 20 highest risk files:")
top20 <- scores |>
  arrange(desc(composite_risk)) |>
  head(20) |>
  select(file_path, composite_risk, risk_tier,
         churn_score, defect_score, test_score, dependency_score)

for (i in seq_len(nrow(top20))) {
  fname <- basename(top20$file_path[i])
  log_info("  [{top20$risk_tier[i]}] {fname} — composite: {top20$composite_risk[i]} (churn: {top20$churn_score[i]}, defect: {top20$defect_score[i]}, test: {top20$test_score[i]}, dependency: {top20$dependency_score[i]})")
}

log_info("--- transform_scores complete ---")