# =============================================================================
# transform_complexity.R
# RETIRED — replaced by utils/load_lizard.R (March 2026)
#
# SonarQube has been replaced with lizard for complexity scoring.
# fact_file_complexity is now populated by load_lizard.R which:
#   - Reads lizard_output_*.csv (function-level CCN + NLOC)
#   - Aggregates to file level (avg_ccn, avg_nloc, max_ccn)
#   - Splits by language (avg_ccn_java, avg_ccn_frontend)
#   - Upserts into fact_file_complexity via dim_file.file_id
#   - Recalibrates scoring_normalization p95 denominators
#
# Column mapping (SonarQube → lizard):
#   cyclomatic_complexity → avg_ccn   (lizard CCN, file-level average)
#   cognitive_complexity  → avg_nloc  (lizard NLOC, proxy for cognitive load)
#   violation_*           → zeroed    (not available from lizard)
#   tech_debt_minutes     → zeroed    (not available from lizard)
#
# This file is kept for reference only. Do not run.
# To re-run complexity: Rscript utils/load_lizard.R
# =============================================================================

log_warn <- function(...) message("[WARN] ", ...)
log_warn("transform_complexity.R is RETIRED. Run utils/load_lizard.R instead.")
log_warn("Exiting without making changes to fact_file_complexity.")
stop("transform_complexity.R retired — use load_lizard.R", call. = FALSE)

# Original code preserved below for reference
# library(dplyr)
# library(DBI)
# library(RPostgres)
# library(logger)
# library(yaml)
# 
# log_appender(appender_file("logs/pipeline.log", append = TRUE))
# log_info("--- transform_complexity started ---")
# 
# source("config/release_analytics_db.R")
# cfg <- read_yaml("config/config.yml")
# con <- get_db_connection()
# on.exit(dbDisconnect(con), add = TRUE)
# 
# # -----------------------------------------------------------------------------
# # Load staged data
# # -----------------------------------------------------------------------------
# if (!file.exists("staging/raw_sonarqube_combined.rds")) {
#   log_error("staging/raw_sonarqube_combined.rds not found — run extract_sonarqube.R first")
#   stop("raw_sonarqube_combined.rds not found")
# }
# 
# sonar <- readRDS("staging/raw_sonarqube_combined.rds")
# log_info("SonarQube rows loaded: {nrow(sonar)}")
# log_info("Files with complexity data: {sum(sonar$cyclomatic_complexity > 0, na.rm = TRUE)}")
# log_info("Files with violations only: {sum(sonar$cyclomatic_complexity == 0, na.rm = TRUE)}")
# 
# # -----------------------------------------------------------------------------
# # Exclude test and generated files
# # -----------------------------------------------------------------------------
# sonar <- sonar |>
#   filter(!grepl(
#     "Test\\.java$|TestCase\\.java$|TestUtil\\.java$|/test/|/testIntegration/|/testFunctional/|/generated-sources/|/generated/",
#     file_path, ignore.case = FALSE
#   )) |>
#   filter(!grepl("^Base[A-Z].*Impl\\.java$", basename(file_path)))
# 
# log_info("After excluding test/generated files: {nrow(sonar)} files")
# 
# # -----------------------------------------------------------------------------
# # Join to dim_file to get file_id
# # -----------------------------------------------------------------------------
# file_ids <- dbGetQuery(con, "SELECT file_id, file_path FROM dim_file WHERE is_active = TRUE")
# 
# sonar_with_ids <- sonar |>
#   inner_join(file_ids, by = "file_path")
# 
# log_info("Files matched to dim_file: {nrow(sonar_with_ids)}")
# log_info("Files not in dim_file (not in git): {nrow(sonar) - nrow(sonar_with_ids)}")
# 
# # -----------------------------------------------------------------------------
# # Prepare for loading
# # -----------------------------------------------------------------------------
# complexity_to_load <- sonar_with_ids |>
#   mutate(
#     cyclomatic_complexity    = coalesce(as.numeric(cyclomatic_complexity), 0),
#     cognitive_complexity     = coalesce(as.numeric(cognitive_complexity),  0),
#     violation_count          = coalesce(as.integer(violation_count),          0L),
#     violation_blocker_count  = coalesce(as.integer(violation_blocker_count),  0L),
#     violation_critical_count = coalesce(as.integer(violation_critical_count), 0L),
#     lines_of_code            = coalesce(as.integer(lines_of_code),            0L),
#     tech_debt_minutes        = coalesce(as.integer(tech_debt_minutes),        0L),
#     snapshot_date            = Sys.Date()
#   ) |>
#   select(file_id, cyclomatic_complexity, cognitive_complexity,
#          violation_count, violation_blocker_count, violation_critical_count,
#          lines_of_code, tech_debt_minutes, snapshot_date)
# 
# log_info("Rows to load into fact_file_complexity: {nrow(complexity_to_load)}")
# 
# # -----------------------------------------------------------------------------
# # Bulk upsert into fact_file_complexity
# # -----------------------------------------------------------------------------
# log_info("Loading fact_file_complexity...")
# 
# dbWriteTable(con, "temp_complexity", complexity_to_load,
#              temporary = TRUE, overwrite = TRUE)
# 
# dbExecute(con, "
#   INSERT INTO fact_file_complexity (
#     file_id, cyclomatic_complexity, cognitive_complexity,
#     violation_count, violation_blocker_count, violation_critical_count,
#     lines_of_code, tech_debt_minutes, snapshot_date, calculated_at
#   )
#   SELECT file_id, cyclomatic_complexity, cognitive_complexity,
#          violation_count, violation_blocker_count, violation_critical_count,
#          lines_of_code, tech_debt_minutes, snapshot_date, NOW()
#   FROM temp_complexity
#   ON CONFLICT (file_id) DO UPDATE SET
#     cyclomatic_complexity    = EXCLUDED.cyclomatic_complexity,
#     cognitive_complexity     = EXCLUDED.cognitive_complexity,
#     violation_count          = EXCLUDED.violation_count,
#     violation_blocker_count  = EXCLUDED.violation_blocker_count,
#     violation_critical_count = EXCLUDED.violation_critical_count,
#     lines_of_code            = EXCLUDED.lines_of_code,
#     tech_debt_minutes        = EXCLUDED.tech_debt_minutes,
#     snapshot_date            = EXCLUDED.snapshot_date,
#     calculated_at            = NOW()
# ")
# 
# dbExecute(con, "DROP TABLE IF EXISTS temp_complexity")
# 
# # -----------------------------------------------------------------------------
# # Save to staging
# # -----------------------------------------------------------------------------
# saveRDS(complexity_to_load, "staging/transformed_complexity.rds")
# log_info("Saved to staging/transformed_complexity.rds")
# 
# # -----------------------------------------------------------------------------
# # Summary
# # -----------------------------------------------------------------------------
# final_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_file_complexity")
# log_info("fact_file_complexity total rows: {final_count$n}")
# 
# summary <- dbGetQuery(con, "
#   SELECT
#     COUNT(*) as total_files,
#     ROUND(AVG(cyclomatic_complexity)::numeric, 2) as avg_cyclomatic,
#     MAX(cyclomatic_complexity) as max_cyclomatic,
#     ROUND(AVG(cognitive_complexity)::numeric, 2) as avg_cognitive,
#     MAX(cognitive_complexity) as max_cognitive,
#     SUM(violation_count) as total_violations,
#     SUM(violation_blocker_count) as total_blockers,
#     SUM(violation_critical_count) as total_criticals,
#     SUM(tech_debt_minutes) as total_debt_minutes
#   FROM fact_file_complexity
# ")
# 
# log_info("fact_file_complexity summary:")
# log_info("  Files:              {summary$total_files}")
# log_info("  Avg cyclomatic:     {summary$avg_cyclomatic}")
# log_info("  Max cyclomatic:     {summary$max_cyclomatic}")
# log_info("  Avg cognitive:      {summary$avg_cognitive}")
# log_info("  Max cognitive:      {summary$max_cognitive}")
# log_info("  Total violations:   {summary$total_violations}")
# log_info("  Total blockers:     {summary$total_blockers}")
# log_info("  Total criticals:    {summary$total_criticals}")
# log_info("  Total debt minutes: {summary$total_debt_minutes}")
# 
# # Top 10 by cyclomatic complexity
# log_info("Top 10 files by cyclomatic complexity:")
# top10 <- dbGetQuery(con, "
#   SELECT f.file_path, c.cyclomatic_complexity, c.cognitive_complexity,
#          c.violation_count, c.tech_debt_minutes
#   FROM fact_file_complexity c
#   JOIN dim_file f ON c.file_id = f.file_id
#   ORDER BY c.cyclomatic_complexity DESC
#   LIMIT 10
# ")
# 
# for (i in seq_len(nrow(top10))) {
#   log_info("  {basename(top10$file_path[i])}: cyclomatic={top10$cyclomatic_complexity[i]}, cognitive={top10$cognitive_complexity[i]}, violations={top10$violation_count[i]}")
# }
# 
# log_info("--- transform_complexity complete ---")