# =============================================================================
# transform_defects.R
# Transforms raw Jira issues into fact_defect_history rows
# Aggregates bug counts and severity at module level for 30/90/365 day windows
#
# Input:  staging/raw_jira_issues.rds
# Output: fact_defect_history (PostgreSQL)
#         staging/transformed_defects.rds
#
# Notes:
#   - LPP priority: Fire=5, Critical=4, High=3, Medium=2, Low=1
#   - LPD fix priority: already 1-5 (NA defaults to 3)
#   - Component normalization: strip sub-component after >
#   - Component matching: Jira → dim_component via crosswalk
# =============================================================================

library(dplyr)
library(tidyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_defects started ---")

source("config/release_analytics_db.R")
cfg     <- read_yaml("config/config.yml")
windows <- cfg$scoring$windows  # c(30, 90, 365)
con     <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load staged data
# -----------------------------------------------------------------------------
if (!file.exists("staging/raw_jira_issues.rds")) {
  log_error("staging/raw_jira_issues.rds not found — run extract_jira.R first")
  stop("raw_jira_issues.rds not found")
}

issues <- readRDS("staging/raw_jira_issues.rds")
log_info("Jira issues loaded: {nrow(issues)} records")
log_info("LPP: {sum(issues$project == 'LPP')}, LPD: {sum(issues$project == 'LPD')}")

# -----------------------------------------------------------------------------
# Load dim_component and crosswalk from DB
# -----------------------------------------------------------------------------
comp_ids  <- dbGetQuery(con, "SELECT component_id, component_name FROM dim_component")
mod_ids   <- dbGetQuery(con, "SELECT module_id, module_name FROM dim_module")
crosswalk <- dbGetQuery(con, "
  SELECT mc.module_id, mc.component_id, m.module_name, c.component_name
  FROM module_component_map mc
  JOIN dim_module m    ON mc.module_id    = m.module_id
  JOIN dim_component c ON mc.component_id = c.component_id
")

log_info("dim_component: {nrow(comp_ids)} components")
log_info("Crosswalk entries: {nrow(crosswalk)}")

# -----------------------------------------------------------------------------
# Known component name aliases — Jira name → dim_component name
# For cases where Jira uses different naming than Testray/crosswalk
# -----------------------------------------------------------------------------
COMPONENT_ALIASES <- c(
  "CMS"                    = "Content Management System",
  "CMP"                    = "Content Marketing Platform",
  "Objects"                = "Object",
  "Pages"                  = "Content Pages",
  "DXP UI Components"      = "Frontend Data Set",
  "DXP Editors"            = "Frontend Editor",
  "User Management"        = "Users and Organizations",
  "Application Security"   = "Security",
  "Data Integration"       = "Data Migration Center",
  "Site Management"        = "Sites Administration",
  "Dev Tools"              = "Portal Services",
  "Release"                = "Portal Services",
  "Documents & Media"      = "Documents and Media",
  "Marketplace"            = "Marketplace"
)

# -----------------------------------------------------------------------------
# Step 1 — Normalize and expand components
# Each issue can have multiple pipe-separated components
# -----------------------------------------------------------------------------
log_info("Normalizing and expanding components...")

issues_expanded <- issues |>
  mutate(
    # Default NA severity to 3 (middle) for LPD
    severity_score = case_when(
      project == "LPD" & is.na(severity_score) ~ 3,
      TRUE ~ severity_score
    )
  ) |>
  mutate(comp_raw = strsplit(components, "\\|")) |>
  unnest(comp_raw) |>
  mutate(
    # Try full name first, fall back to stripped if no exact match
    comp_normalized = case_when(
      trimws(comp_raw) %in% comp_ids$component_name ~ trimws(comp_raw),
      TRUE ~ trimws(gsub(">.*", "", comp_raw))
    ),
    # Apply aliases on result
    comp_normalized = case_when(
      comp_normalized %in% names(COMPONENT_ALIASES) ~
        COMPONENT_ALIASES[comp_normalized],
      TRUE ~ comp_normalized
    )
  ) |>
  # Join to dim_component
  left_join(comp_ids |> rename(jira_component_id = component_id), 
            by = c("comp_normalized" = "component_name")) |>
  left_join(
    crosswalk |> select(component_name, module_id) |> distinct(),
    by = c("comp_normalized" = "component_name")
  )

log_info("Expanded issue-component rows: {nrow(issues_expanded)}")
log_info("Rows matched to dim_component: {sum(!is.na(issues_expanded$component_id))}")
log_info("Rows matched to module: {sum(!is.na(issues_expanded$module_id))}")

# Check unmatched components
unmatched_comps <- issues_expanded |>
  filter(!is.na(jira_component_id)) |>
  count(comp_normalized, sort = TRUE) |>
  head(10)

log_info("Top unmatched Jira components:")
for (i in seq_len(nrow(unmatched_comps))) {
  log_info("  {unmatched_comps$comp_normalized[i]}: {unmatched_comps$n[i]} issues")
}

# -----------------------------------------------------------------------------
# Step 2 — Calculate defect metrics per module per window
# -----------------------------------------------------------------------------
log_info("Calculating defect windows: {paste(windows, collapse=', ')} days")

today <- Sys.Date()

defects_all <- lapply(windows, function(w) {
  cutoff <- today - w

  window_defects <- issues_expanded |>
    filter(!is.na(module_id)) |>
    filter(created_date >= cutoff) |>
    group_by(module_id) |>
    summarise(
      bug_count               = n(),
      customer_reported_count = sum(project == "LPP"),
      internal_count          = sum(project == "LPD"),
      # Severity weighted: sum of severity scores normalized by max possible (5)
      severity_weighted_score = round(
        sum(severity_score, na.rm = TRUE) / (n() * 5),
        4
      ),
      .groups = "drop"
    ) |>
    mutate(window_days = w)

  log_info("  {w}d window: {nrow(window_defects)} modules with defects")
  window_defects
})

defects_combined <- bind_rows(defects_all)
log_info("Total defect rows to load: {nrow(defects_combined)}")

# -----------------------------------------------------------------------------
# Step 3 — Bulk upsert into fact_defect_history
# -----------------------------------------------------------------------------
log_info("Loading fact_defect_history...")

dbWriteTable(con, "temp_defects", defects_combined,
             temporary = TRUE, overwrite = TRUE)

dbExecute(con, "
  INSERT INTO fact_defect_history (
    module_id, window_days, bug_count,
    customer_reported_count, internal_count,
    severity_weighted_score, calculated_at
  )
  SELECT module_id, window_days, bug_count,
         customer_reported_count, internal_count,
         severity_weighted_score, NOW()
  FROM temp_defects
  ON CONFLICT (module_id, window_days) DO UPDATE SET
    bug_count               = EXCLUDED.bug_count,
    customer_reported_count = EXCLUDED.customer_reported_count,
    internal_count          = EXCLUDED.internal_count,
    severity_weighted_score = EXCLUDED.severity_weighted_score,
    calculated_at           = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS temp_defects")

# -----------------------------------------------------------------------------
# Step 4 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(defects_combined, "staging/transformed_defects.rds")
log_info("Saved to staging/transformed_defects.rds")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
final_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_defect_history")
log_info("fact_defect_history total rows: {final_count$n}")

summary <- dbGetQuery(con, "
  SELECT window_days,
         COUNT(*) as module_count,
         SUM(bug_count) as total_bugs,
         SUM(customer_reported_count) as total_lpp,
         SUM(internal_count) as total_lpd,
         ROUND(AVG(severity_weighted_score)::numeric, 4) as avg_severity
  FROM fact_defect_history
  GROUP BY window_days
  ORDER BY window_days
")

log_info("fact_defect_history summary:")
for (i in seq_len(nrow(summary))) {
  log_info("  {summary$window_days[i]}d: {summary$module_count[i]} modules, {summary$total_bugs[i]} bugs ({summary$total_lpp[i]} LPP / {summary$total_lpd[i]} LPD), avg severity {summary$avg_severity[i]}")
}

# Top 10 modules by bug count at 365d
log_info("Top 10 modules by bug count (365d):")
top10 <- defects_combined |>
  filter(window_days == 365) |>
  left_join(mod_ids, by = "module_id") |>
  arrange(desc(bug_count)) |>
  head(10)

for (i in seq_len(nrow(top10))) {
  log_info("  {top10$module_name[i]}: {top10$bug_count[i]} bugs ({top10$customer_reported_count[i]} LPP / {top10$internal_count[i]} LPD)")
}

log_info("--- transform_defects complete ---")
