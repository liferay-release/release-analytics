# =============================================================================
# transform_test_risk.R
# Transforms raw Testray case results into fact_test_failure rows
# Aggregates failure rates and co-failure scores at component level
#
# Input:  staging/raw_testray_caseresults.rds
# Output: fact_test_failure (PostgreSQL)
#         staging/transformed_test_risk.rds
#
# Notes:
#   - Failure statuses: Failed, Blocked
#   - Only 30d window available from current Testray extract
#   - 90d and 365d windows require broader Testray pull (future)
#   - Flaky tests are flagged but still counted (conservative approach)
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_test_risk started ---")

source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load staged data
# -----------------------------------------------------------------------------
if (!file.exists("staging/raw_testray_caseresults.rds")) {
  log_error("staging/raw_testray_caseresults.rds not found — run extract_testray.R first")
  stop("raw_testray_caseresults.rds not found")
}

cr <- readRDS("staging/raw_testray_caseresults.rds")
log_info("Case results loaded: {nrow(cr)} records")
log_info("Date range: {min(cr$date_created)} to {max(cr$date_created)}")

# -----------------------------------------------------------------------------
# Load dim_component and dim_module IDs from DB
# -----------------------------------------------------------------------------
comp_ids <- dbGetQuery(con, "SELECT component_id, component_name FROM dim_component")
mod_ids  <- dbGetQuery(con, "SELECT module_id, module_name FROM dim_module")
crosswalk <- dbGetQuery(con, "
  SELECT mc.module_id, mc.component_id, m.module_name, c.component_name
  FROM module_component_map mc
  JOIN dim_module m    ON mc.module_id    = m.module_id
  JOIN dim_component c ON mc.component_id = c.component_id
")

log_info("dim_component: {nrow(comp_ids)} components")
log_info("Crosswalk entries: {nrow(crosswalk)}")

# ---
# Exclude Components
# ---
EXCLUDED_COMPONENTS <- c(
  "A/B Test",
  "License",
  "Smoke"
)

cr <- cr |>
  filter(!component_name %in% EXCLUDED_COMPONENTS)

log_info("After exclusions: {nrow(cr)} records remaining")

# -----------------------------------------------------------------------------
# Step 1 — Calculate failure metrics per component
# Failure = Failed or Blocked
# Window = 30d only (current extract covers ~30 days)
# -----------------------------------------------------------------------------
FAILURE_STATUSES <- c("Failed", "Blocked")
WINDOW_DAYS      <- 30

log_info("Calculating component failure rates (window: {WINDOW_DAYS}d)")
log_info("Failure statuses: {paste(FAILURE_STATUSES, collapse=', ')}")

component_stats <- cr |>
  group_by(component_name) |>
  summarise(
    test_run_count  = n(),
    failure_count   = sum(status %in% FAILURE_STATUSES),
    flaky_count     = sum(flaky == TRUE, na.rm = TRUE),
    .groups         = "drop"
  ) |>
  mutate(
    failure_rate = round(failure_count / test_run_count, 4)
  ) |>
  arrange(desc(failure_rate))

log_info("Component stats calculated: {nrow(component_stats)} components")
log_info("Components with failures: {sum(component_stats$failure_count > 0)}")

# -----------------------------------------------------------------------------
# Step 2 — Calculate co-failure score per component
# Co-failure: proportion of builds where this component had failures
# alongside failures in OTHER components (indicates systemic risk)
# -----------------------------------------------------------------------------
log_info("Calculating co-failure scores...")

# Per build, flag which components had failures
build_component_failures <- cr |>
  filter(status %in% FAILURE_STATUSES) |>
  distinct(build_id, component_name)

# For each component, how many builds had failures in 2+ components?
build_failure_counts <- build_component_failures |>
  group_by(build_id) |>
  summarise(components_failing = n_distinct(component_name), .groups = "drop")

# Join back to get co-failure count per component
co_failure_stats <- build_component_failures |>
  left_join(build_failure_counts, by = "build_id") |>
  group_by(component_name) |>
  summarise(
    builds_with_failures    = n_distinct(build_id),
    builds_with_co_failures = sum(components_failing > 1),
    .groups = "drop"
  ) |>
  mutate(
    co_failure_score = round(
      ifelse(builds_with_failures > 0,
             builds_with_co_failures / builds_with_failures,
             0),
      4
    )
  )

log_info("Co-failure scores calculated: {nrow(co_failure_stats)} components")

# -----------------------------------------------------------------------------
# Step 3 — Combine stats and join to dim_component / dim_module
# -----------------------------------------------------------------------------
test_risk <- component_stats |>
  left_join(co_failure_stats, by = "component_name") |>
  mutate(
    co_failure_score      = coalesce(co_failure_score, 0),
    builds_with_failures  = coalesce(builds_with_failures, 0L),
    builds_with_co_failures = coalesce(builds_with_co_failures, 0L)
  ) |>
  left_join(comp_ids, by = "component_name") |>
  # Join to get module via crosswalk (take first module match per component)
  left_join(
    crosswalk |> distinct(component_name, module_id) |>
      select(component_name, module_id),
    by = "component_name"
  ) |>
  mutate(window_days = WINDOW_DAYS)

log_info("Test risk rows prepared: {nrow(test_risk)}")
log_info("Rows with component_id: {sum(!is.na(test_risk$component_id))}")
log_info("Rows with module_id: {sum(!is.na(test_risk$module_id))}")

# -----------------------------------------------------------------------------
# Step 4 — Bulk upsert into fact_test_failure via temp table
# Note: UNIQUE constraint is on (module_id, window_days)
# Components without module mapping are stored with NULL module_id
# -----------------------------------------------------------------------------
log_info("Loading fact_test_failure...")

# Aggregate to one row per module_id + window_days
# Multiple components can map to the same module — sum counts, average co-failure
test_risk_with_module <- test_risk |>
  filter(!is.na(module_id)) |>
  group_by(module_id, window_days) |>
  summarise(
    component_id     = first(component_id),
    test_run_count   = sum(test_run_count),
    failure_count    = sum(failure_count),
    failure_rate     = round(sum(failure_count) / sum(test_run_count), 4),
    co_failure_score = round(mean(co_failure_score), 4),
    .groups          = "drop"
  ) |>
  mutate(across(where(is.integer), as.integer))

log_info("Rows with module mapping (aggregated): {nrow(test_risk_with_module)}")
log_info("Skipping {nrow(test_risk |> filter(is.na(module_id)))} components without module mapping")
log_info("These components exist in dim_component for component-level reporting")

# Write with module to temp table and upsert
dbWriteTable(con, "temp_test_risk", test_risk_with_module,
             temporary = TRUE, overwrite = TRUE)

dbExecute(con, "
  INSERT INTO fact_test_failure (
    module_id, component_id, window_days,
    test_run_count, failure_count, failure_rate, co_failure_score, calculated_at
  )
  SELECT module_id, component_id, window_days,
         test_run_count, failure_count, failure_rate, co_failure_score, NOW()
  FROM temp_test_risk
  ON CONFLICT (module_id, window_days) DO UPDATE SET
    component_id    = EXCLUDED.component_id,
    test_run_count  = EXCLUDED.test_run_count,
    failure_count   = EXCLUDED.failure_count,
    failure_rate    = EXCLUDED.failure_rate,
    co_failure_score = EXCLUDED.co_failure_score,
    calculated_at   = NOW()
")


dbExecute(con, "DROP TABLE IF EXISTS temp_test_risk")

# -----------------------------------------------------------------------------
# Step 5 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(test_risk, "staging/transformed_test_risk.rds")
log_info("Saved to staging/transformed_test_risk.rds")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
final_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM fact_test_failure")
log_info("fact_test_failure total rows: {final_count$n}")

# Top 10 highest failure rate components
log_info("Top 10 components by failure rate:")
top10comps <- test_risk |>
  filter(!is.na(component_id)) |>
  arrange(desc(failure_rate)) |>
  head(10)

log_info("Test risk with module")
test_risk_with_module |>
  left_join(dbGetQuery(con, "SELECT module_id, module_name FROM dim_module"), by = "module_id") |>
  arrange(desc(failure_count)) |>
  select(module_name, test_run_count, failure_count, failure_rate) |>
  head(10)

# Test risk for commerce
# test_risk |>
#   filter(grepl("commerce|Commerce|Shopping|Order|Product Info", component_name, ignore.case = TRUE)) |>
#   select(component_name, test_run_count, failure_count, failure_rate, co_failure_score, module_id) |>
#   arrange(desc(failure_count))

for (i in seq_len(nrow(top10comps))) {
  log_info("  {top10comps$component_name[i]}: {top10comps$failure_rate[i]} ({top10comps$failure_count[i]}/{top10comps$test_run_count[i]})")
}

log_info("--- transform_test_risk complete ---")
