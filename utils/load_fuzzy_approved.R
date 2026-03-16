# =============================================================================
# load_fuzzy_approved.R
# Loads approved fuzzy match candidates into module_component_map
#
# Workflow:
#   1. Run fuzzy_match_modules.R → staging/fuzzy_match_candidates.csv
#   2. Open CSV, review matches, set approve=TRUE for correct ones
#   3. Run this script to load approved rows
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- load_fuzzy_approved started ---")

source("config/release_analytics_db")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load approved candidates
# -----------------------------------------------------------------------------
if (!file.exists("staging/fuzzy_match_candidates.csv")) {
  stop("staging/fuzzy_match_candidates.csv not found — run fuzzy_match_modules.R first")
}

candidates <- read.csv("staging/fuzzy_match_candidates.csv", stringsAsFactors = FALSE)
approved   <- candidates |> filter(trimws(tolower(approve)) == "true")

log_info("Total candidates: {nrow(candidates)}")
log_info("Approved for loading: {nrow(approved)}")

if (nrow(approved) == 0) {
  log_info("No approved rows found — set approve=TRUE in CSV and re-run")
  stop("Nothing to load")
}

# -----------------------------------------------------------------------------
# Resolve module_id and component_id
# -----------------------------------------------------------------------------
mod_ids  <- dbGetQuery(con, "SELECT module_id, module_name FROM dim_module")
comp_ids <- dbGetQuery(con, "SELECT component_id, component_name FROM dim_component")

to_load <- approved |>
  left_join(mod_ids,  by = "module_name") |>
  left_join(comp_ids, by = "component_name") |>
  filter(!is.na(module_id) & !is.na(component_id)) |>
  select(module_id, component_id, confidence) |>
  distinct()

unresolved <- nrow(approved) - nrow(to_load)
if (unresolved > 0) log_info("WARNING: {unresolved} approved rows could not resolve module_id or component_id")

log_info("Rows ready to insert: {nrow(to_load)}")

# -----------------------------------------------------------------------------
# Bulk insert
# -----------------------------------------------------------------------------
dbWriteTable(con, "temp_fuzzy", to_load, temporary = TRUE, overwrite = TRUE)

inserted <- dbExecute(con, "
  INSERT INTO module_component_map (module_id, component_id, confidence, map_source)
  SELECT module_id, component_id, confidence, 'inferred'
  FROM temp_fuzzy
  ON CONFLICT (module_id, component_id) DO NOTHING
")

dbExecute(con, "DROP TABLE IF EXISTS temp_fuzzy")

final_count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM module_component_map")$n
log_info("Inserted: {nrow(to_load)} rows (conflicts skipped)")
log_info("module_component_map total: {final_count} rows")
log_info("--- load_fuzzy_approved complete ---")


