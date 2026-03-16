# =============================================================================
# transform_forecast_input.R
# Rolls up LPP/LPD bug counts from raw_jira_issues.rds to component × quarter
# and upserts lpp_count / lpd_count into fact_forecast_input.
#
# Quarter assignment rules:
#   LPP: use quarter_lpp (from affectedVersion) if >= 2024.Q1
#        fall back to resolution_date → dev window if quarter_lpp is NA
#        exclude if < 2024.Q1 or no valid quarter found
#
#   LPD: always use created_date → dev window lookup
#        exclude if created_date falls before 2024.Q1 dev window start
#
# Component parsing:
#   "Category > Specific Component" → use "Specific Component"
#   "Component A|Component B"       → split on |, apply to each
#
# Only updates lpp_count and lpd_count — churn signals are untouched.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(DBI)
  library(yaml)
  library(lubridate)
})

select <- dplyr::select
filter <- dplyr::filter
mutate <- dplyr::mutate

source("config/release_analytics_db.R")
options(scipen = 999)
STAGING <- "staging"

# =============================================================================
# 1. LOAD CONFIG + DEV WINDOWS
# =============================================================================
message("\n=== TRANSFORM: Bug Counts → fact_forecast_input ===")

cfg <- read_yaml("config/config.yml")

dev_windows <- bind_rows(lapply(cfg$jira$dev_windows, as.data.frame)) %>%
  mutate(
    dev_start = as.Date(dev_start),
    dev_end   = as.Date(dev_end)
  )

message(sprintf("  Dev windows loaded: %d quarters (%s to %s)",
                nrow(dev_windows),
                min(dev_windows$quarter),
                max(dev_windows$quarter)))

# =============================================================================
# 2. LOAD RAW JIRA ISSUES
# =============================================================================
jira_path <- file.path(STAGING, "raw_jira_issues.rds")
if (!file.exists(jira_path)) stop("Missing: ", jira_path, " — run extract_jira.R first")

jira <- readRDS(jira_path)
message(sprintf("  Loaded %d issues (LPP: %d, LPD: %d)",
                nrow(jira),
                sum(jira$project == "LPP"),
                sum(jira$project == "LPD")))

# =============================================================================
# 3. DEV WINDOW LOOKUP HELPER
# =============================================================================
date_to_dev_quarter <- function(dates, windows) {
  sapply(dates, function(d) {
    if (is.na(d)) return(NA_character_)
    match_idx <- which(d >= windows$dev_start & d <= windows$dev_end)
    if (length(match_idx) == 0) return(NA_character_)
    windows$quarter[match_idx[1]]
  }, USE.NAMES = FALSE)
}

# =============================================================================
# 4. COMPONENT PARSING HELPER
# =============================================================================
parse_jira_components <- function(components_str) {
  if (is.na(components_str) || trimws(components_str) == "") return(NA_character_)
  parts <- trimws(unlist(strsplit(components_str, "\\|")))
  parts <- sub("^.*>\\s*", "", parts)
  parts <- trimws(parts)
  parts <- parts[parts != ""]
  if (length(parts) == 0) return(NA_character_)
  parts
}

# =============================================================================
# 5. ASSIGN QUARTERS
# =============================================================================
message("\n=== ASSIGNING QUARTERS ===")

# --- LPP ---
lpp <- jira %>%
  filter(project == "LPP") %>%
  mutate(
    quarter = case_when(
      !is.na(quarter_lpp) & quarter_lpp >= "2024.Q1" ~ quarter_lpp,
      is.na(quarter_lpp) ~ date_to_dev_quarter(resolution_date, dev_windows),
      TRUE ~ NA_character_
    )
  ) %>%
  filter(!is.na(quarter), quarter >= "2024.Q1")

lpp_excluded <- sum(jira$project == "LPP") - nrow(lpp)
message(sprintf("  LPP: %d issues assigned to quarters, %d excluded (pre-2024 or unresolvable)",
                nrow(lpp), lpp_excluded))
print(sort(table(lpp$quarter)))

# --- LPD ---
lpd <- jira %>%
  filter(project == "LPD") %>%
  mutate(quarter = date_to_dev_quarter(created_date, dev_windows)) %>%
  filter(!is.na(quarter), quarter >= "2024.Q1")

lpd_excluded <- sum(jira$project == "LPD") - nrow(lpd)
message(sprintf("\n  LPD: %d issues assigned to quarters, %d excluded (outside dev windows or pre-2024)",
                nrow(lpd), lpd_excluded))
print(sort(table(lpd$quarter)))

# =============================================================================
# 6. PARSE + EXPAND COMPONENTS
# =============================================================================
message("\n=== PARSING AND EXPANDING COMPONENTS ===")

expand_components <- function(df, project_label) {
  result <- df %>%
    rowwise() %>%
    mutate(component_list = list(parse_jira_components(components))) %>%
    ungroup() %>%
    unnest(component_list) %>%
    rename(component_name = component_list) %>%
    filter(!is.na(component_name), component_name != "")

  no_component <- sum(is.na(df$components) | df$components == "")
  message(sprintf("  %s: %d issues → %d component rows (%d had no component)",
                  project_label, nrow(df), nrow(result), no_component))
  result
}

lpp_expanded <- expand_components(lpp, "LPP")
lpd_expanded <- expand_components(lpd, "LPD")

# =============================================================================
# 7. JOIN TO dim_component
# =============================================================================
message("\n=== JOINING TO dim_component ===")

con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

dim_comp <- dbGetQuery(con, "SELECT component_id, component_name FROM dim_component")

join_components <- function(df, project_label) {
  joined <- df %>% left_join(dim_comp, by = "component_name")

  unmatched <- joined %>%
    filter(is.na(component_id)) %>%
    distinct(component_name) %>%
    arrange(component_name)

  message(sprintf("  %s: %d unmatched component names (excluded):",
                  project_label, nrow(unmatched)))
  if (nrow(unmatched) > 0 && nrow(unmatched) <= 20)
    message(paste("   ", unmatched$component_name, collapse = "\n"))
  else if (nrow(unmatched) > 20) {
    message(paste("   ", head(unmatched$component_name, 20), collapse = "\n"))
    message(sprintf("   ... and %d more", nrow(unmatched) - 20))
  }

  out_path <- file.path(STAGING, sprintf("jira_unmatched_%s.csv", tolower(project_label)))
  write_csv(unmatched, out_path)

  joined %>% filter(!is.na(component_id))
}

lpp_matched <- join_components(lpp_expanded, "LPP")
lpd_matched <- join_components(lpd_expanded, "LPD")

# =============================================================================
# 8. ROLL UP TO component × quarter
# =============================================================================
message("\n=== ROLLING UP TO COMPONENT × QUARTER ===")

lpp_counts <- lpp_matched %>%
  group_by(component_id, quarter) %>%
  summarise(lpp_count = n(), .groups = "drop")

lpd_counts <- lpd_matched %>%
  group_by(component_id, quarter) %>%
  summarise(lpd_count = n(), .groups = "drop")

# Blocker counts — subset of LPD tickets flagged as release blockers
blocker_counts <- lpd_matched %>%
  filter(coalesce(is_release_blocker, FALSE) == TRUE) %>%
  group_by(component_id, quarter) %>%
  summarise(blocker_count = n(), .groups = "drop")

message(sprintf("  LPP rollup: %d component × quarter rows", nrow(lpp_counts)))
message(sprintf("  LPD rollup: %d component × quarter rows", nrow(lpd_counts)))
message(sprintf("  Blocker rollup: %d component × quarter rows", nrow(blocker_counts)))

# =============================================================================
# 9. UPSERT INTO fact_forecast_input
# Only touches lpp_count / lpd_count — churn untouched
# =============================================================================
message("\n=== UPSERTING BUG COUNTS ===")

upsert_bug_counts <- function(counts_df, count_col, con) {
  tmp <- paste0("_tmp_", count_col)
  dbExecute(con, sprintf("
    CREATE TEMP TABLE %s (
      component_id INT,
      quarter      VARCHAR(20),
      %s           INT
    ) ON COMMIT DROP", tmp, count_col))

  dbWriteTable(con, tmp, counts_df, overwrite = TRUE, row.names = FALSE)

  rows <- dbExecute(con, sprintf("
    INSERT INTO fact_forecast_input (component_id, quarter, %s)
    SELECT component_id, quarter, %s FROM %s
    ON CONFLICT (component_id, quarter)
      DO UPDATE SET %s = EXCLUDED.%s",
    count_col, count_col, tmp, count_col, count_col))

  message(sprintf("  ✓ %s: upserted %d rows", count_col, rows))
}

upsert_bug_counts(lpp_counts, "lpp_count", con)
upsert_bug_counts(lpd_counts, "lpd_count", con)
upsert_bug_counts(blocker_counts, "blocker_count", con)

# =============================================================================
# 10. VALIDATION
# =============================================================================
message("\n=== VALIDATION ===")

summary_q <- dbGetQuery(con, "
  SELECT
    fi.quarter,
    dr.is_major_release,
    dr.is_lts,
    COUNT(*)          AS n_components,
    SUM(fi.lpp_count) AS total_lpp,
    SUM(fi.lpd_count) AS total_lpd,
    ROUND(AVG(fi.total_churn)::NUMERIC) AS avg_churn
  FROM fact_forecast_input fi
  JOIN dim_release dr ON dr.release_label = fi.quarter
  WHERE fi.quarter LIKE '%.Q%'
  GROUP BY fi.quarter, dr.is_major_release, dr.is_lts, dr.release_date
  ORDER BY COALESCE(dr.release_date, '9999-12-31')
")

print(summary_q)

zero_bugs <- summary_q %>% filter(total_lpp == 0 & total_lpd == 0)
if (nrow(zero_bugs) > 0) {
  message(sprintf("\n  ⚠️  %d quarters have zero bugs — check component matching:", nrow(zero_bugs)))
  print(zero_bugs$quarter)
}

message("\n✅ transform_forecast_input.R complete")
message("   fact_forecast_input now has churn + bug counts for Q releases")
message("   Next: render release_situation_deck.Rmd")
