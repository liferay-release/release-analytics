# =============================================================================
# transform_churn.R
# Transforms raw git log into fact_file_churn rows
# Aggregates commit frequency and author turnover at 30/90/365 day windows
#
# Input:  staging/raw_git_log.rds
#         staging/git_file_module_map.rds
# Output: fact_file_churn (PostgreSQL)
#         staging/transformed_churn.rds
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_churn started ---")

source("config/release_analytics_db.R")
cfg     <- read_yaml("config/config.yml")
windows <- cfg$scoring$windows  # c(30, 90, 365)
con     <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load staged data
# -----------------------------------------------------------------------------
if (!file.exists("staging/raw_git_log.rds")) {
  log_error("staging/raw_git_log.rds not found — run extract_git.R first")
  stop("raw_git_log.rds not found")
}

git_log        <- readRDS("staging/raw_git_log.rds")
file_module_map <- readRDS("staging/git_file_module_map.rds")

log_info("Git log loaded: {nrow(git_log)} records")
log_info("File module map loaded: {nrow(file_module_map)} records")

# -----------------------------------------------------------------------------
# Step 1 — Ensure all file paths exist in dim_file
# Insert new files, link to module via crosswalk
# -----------------------------------------------------------------------------
log_info("Syncing dim_file...")

# Get module IDs from DB
mod_ids <- dbGetQuery(con, "SELECT module_id, module_name FROM dim_module")

# Join file paths to module names
files_with_modules <- git_log |>
  distinct(file_path) |>
  left_join(file_module_map |> distinct(file_path, module_name), 
            by = "file_path") |>
  left_join(mod_ids, by = "module_name") |>
  mutate(
    language = case_when(
      grepl("\\.java$", file_path)       ~ "java",
      grepl("\\.tsx?$", file_path)       ~ "typescript",
      grepl("\\.jsx?$", file_path)       ~ "javascript",
      TRUE                               ~ "other"
    )
  )

log_info("Unique files to sync: {nrow(files_with_modules)}")

# Upsert into dim_file
# Prepare data frame for bulk insert
files_to_insert <- files_with_modules |>
  mutate(module_id = as.integer(module_id)) |>
  select(file_path, module_id, language) |>
  mutate(language = ifelse(is.na(language), "other", language))

# Write to temp table
dbWriteTable(con, "temp_dim_file", files_to_insert, temporary = TRUE, overwrite = TRUE)

# Upsert from temp table
dbExecute(con, "
  INSERT INTO dim_file (file_path, module_id, language, is_active)
  SELECT file_path, module_id, language, TRUE
  FROM temp_dim_file
  ON CONFLICT (file_path) DO UPDATE SET
    module_id  = EXCLUDED.module_id,
    language   = EXCLUDED.language,
    updated_at = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS temp_dim_file")
log_info("dim_file sync complete")

# Fetch file IDs
file_ids <- dbGetQuery(con, "SELECT file_id, file_path FROM dim_file")
log_info("Files in dim_file: {nrow(file_ids)}")

# -----------------------------------------------------------------------------
# Step 2 — Calculate churn metrics per file per window
# -----------------------------------------------------------------------------
log_info("Calculating churn windows: {paste(windows, collapse=', ')} days")

today <- Sys.Date()

churn_all <- lapply(windows, function(w) {
  cutoff <- today - w

  window_churn <- git_log |>
    filter(commit_date >= cutoff) |>
    group_by(file_path) |>
    summarise(
      commit_count   = n_distinct(commit_hash),
      unique_authors = n_distinct(author_email),
      last_commit_date = max(commit_date),
      .groups = "drop"
    ) |>
    mutate(window_days = w)

  log_info("  {w}d window: {nrow(window_churn)} files with activity")
  window_churn
})

churn_combined <- bind_rows(churn_all) |>
  left_join(file_ids, by = "file_path") |>
  filter(!is.na(file_id))

log_info("Total churn rows to load: {nrow(churn_combined)}")

# -----------------------------------------------------------------------------
# Step 3 — Upsert into fact_file_churn
# -----------------------------------------------------------------------------
log_info("Loading fact_file_churn...")

loaded <- 0
for (i in seq_len(nrow(churn_combined))) {
  row <- churn_combined[i, ]

  dbExecute(con, "
    INSERT INTO fact_file_churn (
      file_id, window_days, commit_count, unique_authors,
      last_commit_date, calculated_at
    )
    VALUES ($1, $2, $3, $4, $5, NOW())
    ON CONFLICT (file_id, window_days) DO UPDATE SET
      commit_count     = EXCLUDED.commit_count,
      unique_authors   = EXCLUDED.unique_authors,
      last_commit_date = EXCLUDED.last_commit_date,
      calculated_at    = NOW()
  ", params = list(
    row$file_id,
    row$window_days,
    row$commit_count,
    row$unique_authors,
    as.character(row$last_commit_date)
  ))

  loaded <- loaded + 1
  if (loaded %% 5000 == 0) log_info("  fact_file_churn: {loaded} rows loaded")
}

log_info("fact_file_churn load complete: {loaded} rows")

# -----------------------------------------------------------------------------
# Step 4 — Save transformed data to staging
# -----------------------------------------------------------------------------
saveRDS(churn_combined, "staging/transformed_churn.rds")
log_info("Saved to staging/transformed_churn.rds")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
summary_counts <- dbGetQuery(con, "
  SELECT window_days, COUNT(*) as file_count,
         ROUND(AVG(commit_count), 2) as avg_commits,
         MAX(commit_count) as max_commits
  FROM fact_file_churn
  GROUP BY window_days
  ORDER BY window_days
")

log_info("fact_file_churn summary:")
for (i in seq_len(nrow(summary_counts))) {
  log_info("  {summary_counts$window_days[i]}d: {summary_counts$file_count[i]} files, avg {summary_counts$avg_commits[i]} commits, max {summary_counts$max_commits[i]}")
}

log_info("--- transform_churn complete ---")