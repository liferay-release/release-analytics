# =============================================================================
# ingest_churn_csv.R
# Reads the two churn CSVs (Q releases and U releases), applies the
# module → component weight map, rolls up to component grain, and
# seeds fact_forecast_input in the DB.
#
# Inputs:
#   - data/churn_by_module_Q.csv      Q releases (2024.Q1 → 2025.Q4)
#   - data/churn_by_module_U.csv      U releases (U110 → U147)
#   - dim_module_component_map        already seeded via load_module_component_map.R
#   - dim_release                     already seeded via sync_releases.R
#
# Output:
#   - fact_forecast_input             upserted rows per (component, quarter)
#   - staging/transformed_churn_input.rds   cache for offline use
#
# Run after:
#   sync_releases.R
#   load_module_component_map.R (called automatically)
#
# Run before:
#   release_situation_deck.Rmd
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(DBI)
  library(lubridate)
})

select  <- dplyr::select
filter  <- dplyr::filter
mutate  <- dplyr::mutate

source("config/release_analytics_db.R")
source("utils/load_module_component_map.R")

options(scipen = 999)
STAGING <- "staging"

# =============================================================================
# CONFIGURATION — update paths if your files live elsewhere
# =============================================================================
Q_CSV <- "data/churn_by_module_Q.csv"    # Q releases: 2024.Q1 → 2025.Q4
U_CSV <- "data/churn_by_module_U.csv"    # U releases: U110 → U147

# =============================================================================
# 1. CONNECT + ENSURE MAPS ARE SEEDED
# =============================================================================
message("\n=== INGEST: Churn CSVs → fact_forecast_input ===")

con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# Ensure dim_component and dim_module_component_map are current
load_module_component_map(con)

# =============================================================================
# 2. LOAD BOTH CSVs
# =============================================================================
message("\n=== LOADING CSVs ===")

read_churn_csv <- function(path, label) {
  if (!file.exists(path)) stop("File not found: ", path)
  df <- read_csv(path, col_types = cols(
    Quarter = col_character(),
    Module  = col_character(),
    .default = col_double()
  ), show_col_types = FALSE)
  message(sprintf("  %s: %d rows, %d quarters, %d unique modules",
                  label,
                  nrow(df),
                  n_distinct(df$Quarter),
                  n_distinct(df$Module)))
  df
}

q_churn <- read_churn_csv(Q_CSV, "Q CSV")
u_churn <- read_churn_csv(U_CSV, "U CSV")

# Stack into one frame — Quarter column distinguishes them
churn_raw <- bind_rows(q_churn, u_churn)
message(sprintf("\n  Combined: %d rows across %d unique quarters",
                nrow(churn_raw),
                n_distinct(churn_raw$Quarter)))

# =============================================================================
# 3. VALIDATE QUARTERS AGAINST dim_release
# =============================================================================
message("\n=== VALIDATING QUARTERS ===")

dim_release <- dbGetQuery(con, "
  SELECT release_id, release_label, quarter_label,
         is_major_release, is_lts, release_status
  FROM dim_release
")

csv_quarters    <- sort(unique(churn_raw$Quarter))
release_labels  <- dim_release$release_label
unmatched       <- setdiff(csv_quarters, release_labels)

if (length(unmatched) > 0) {
  message(sprintf("  WARNING: %d quarters in CSV have no dim_release entry — they will be skipped:",
                  length(unmatched)))
  message(paste("   ", unmatched, collapse = "\n"))
} else {
  message(sprintf("  All %d quarters matched to dim_release ✓", length(csv_quarters)))
}

# Join release metadata onto churn rows
churn_with_release <- churn_raw %>%
  inner_join(dim_release, by = c("Quarter" = "release_label")) %>%
  rename(module_path = Module)

message(sprintf("  Rows after join: %d (dropped %d unmatched)",
                nrow(churn_with_release),
                nrow(churn_raw) - nrow(churn_with_release)))

# =============================================================================
# 4. NORMALIZE MODULE PATHS
# Truncate full paths to the top-level module dir used in the map
# e.g. "modules/apps/commerce/commerce-api" → "modules/apps/commerce"
# The CSVs already appear to use top-level dirs, but we normalize defensively
# =============================================================================
message("\n=== NORMALIZING MODULE PATHS ===")

churn_with_release <- churn_with_release %>%
  mutate(
    module_path_norm = gsub(
      "^(modules/(?:apps|dxp/apps|core|util)/[^/]+|portal-impl|portal-kernel|util-taglib).*$",
      "\\1",
      module_path,
      perl = TRUE
    )
  )

# =============================================================================
# 5. APPLY MODULE → COMPONENT MAP (with weights)
# =============================================================================
message("\n=== APPLYING MODULE → COMPONENT MAP ===")

mcm <- dbGetQuery(con, "
  SELECT m.module_path, m.component_id, m.weight, c.component_name
  FROM dim_module_component_map m
  JOIN dim_component c ON c.component_id = m.component_id
")

churn_mapped <- churn_with_release %>%
  left_join(mcm, by = c("module_path_norm" = "module_path"))

# Report unmapped modules
unmapped <- churn_mapped %>%
  filter(is.na(component_id)) %>%
  distinct(module_path_norm) %>%
  arrange(module_path_norm)

message(sprintf("  Unmapped module paths: %d (excluded from rollup)", nrow(unmapped)))
if (nrow(unmapped) > 0 && nrow(unmapped) <= 20) {
  message(paste("   ", unmapped$module_path_norm, collapse = "\n"))
} else if (nrow(unmapped) > 20) {
  message(paste("   ", head(unmapped$module_path_norm, 20), collapse = "\n"))
  message(sprintf("   ... and %d more", nrow(unmapped) - 20))
}

# Save unmapped for review
unmapped_path <- file.path(STAGING, "churn_unmapped_modules.csv")
write_csv(unmapped, unmapped_path)
message(sprintf("  Full unmapped list saved to: %s", unmapped_path))

churn_mapped <- churn_mapped %>%
  filter(!is.na(component_id))

# =============================================================================
# 6. ROLL UP TO COMPONENT × QUARTER (weighted)
# =============================================================================
message("\n=== ROLLING UP TO COMPONENT × QUARTER ===")

# Numeric churn columns
churn_cols <- c(
  "Total_FileCount", "Total_LinesOfCode", "Total_ModifiedFileCount",
  "Total_Insertions", "Total_Deletions",
  "java_FileCount", "java_LinesOfCode", "java_ModifiedFileCount",
  "java_Insertions", "java_Deletions",
  "js_FileCount", "js_LinesOfCode", "js_ModifiedFileCount",
  "js_Insertions", "js_Deletions",
  "jsp_FileCount", "jsp_LinesOfCode", "jsp_ModifiedFileCount",
  "jsp_Insertions", "jsp_Deletions",
  "ts_FileCount", "ts_LinesOfCode", "ts_ModifiedFileCount",
  "ts_Insertions", "ts_Deletions",
  "tsx_FileCount", "tsx_LinesOfCode", "tsx_ModifiedFileCount",
  "tsx_Insertions", "tsx_Deletions",
  "css_FileCount", "css_LinesOfCode", "css_ModifiedFileCount",
  "css_Insertions", "css_Deletions",
  "scss_FileCount", "scss_LinesOfCode", "scss_ModifiedFileCount",
  "scss_Insertions", "scss_Deletions"
)

# Apply weight to each numeric column, then sum by component + quarter
rolled_up <- churn_mapped %>%
  mutate(across(all_of(churn_cols), ~ .x * weight)) %>%
  group_by(
    component_id,
    component_name,
    Quarter,
    release_id,
    quarter_label,
    is_major_release,
    is_lts,
    release_status
  ) %>%
  summarise(
    across(all_of(churn_cols), ~ sum(.x, na.rm = TRUE)),
    .groups = "drop"
  ) %>%
  # Derive composite signals
  mutate(
    backend_changes  = java_Insertions + java_Deletions,
    frontend_changes = tsx_Insertions  + tsx_Deletions  +
                       scss_Insertions + scss_Deletions  +
                       js_Insertions   + js_Deletions,
    total_churn      = backend_changes  + frontend_changes +
                       ts_Insertions   + ts_Deletions   +
                       jsp_Insertions  + jsp_Deletions  +
                       css_Insertions  + css_Deletions,
    is_forecast_row  = (release_status == "IN_DEVELOPMENT"),
    calculated_at    = Sys.time()
  )

message(sprintf("  Rolled up to %d component × quarter rows", nrow(rolled_up)))
message(sprintf("  Quarters: %s", paste(sort(unique(rolled_up$Quarter)), collapse = ", ")))

# =============================================================================
# 7. UPSERT TO fact_forecast_input
# =============================================================================
message("\n=== WRITING TO fact_forecast_input ===")

# Map CSV column names to DB column names
to_write <- rolled_up %>%
  select(
    component_id,
    quarter                = Quarter,
    release_id,
    java_file_count        = java_FileCount,
    java_lines_of_code     = java_LinesOfCode,
    java_modified_files    = java_ModifiedFileCount,
    java_insertions        = java_Insertions,
    java_deletions         = java_Deletions,
    js_file_count          = js_FileCount,
    js_lines_of_code       = js_LinesOfCode,
    js_modified_files      = js_ModifiedFileCount,
    js_insertions          = js_Insertions,
    js_deletions           = js_Deletions,
    jsp_file_count         = jsp_FileCount,
    jsp_lines_of_code      = jsp_LinesOfCode,
    jsp_modified_files     = jsp_ModifiedFileCount,
    jsp_insertions         = jsp_Insertions,
    jsp_deletions          = jsp_Deletions,
    ts_file_count          = ts_FileCount,
    ts_lines_of_code       = ts_LinesOfCode,
    ts_modified_files      = ts_ModifiedFileCount,
    ts_insertions          = ts_Insertions,
    ts_deletions           = ts_Deletions,
    tsx_file_count         = tsx_FileCount,
    tsx_lines_of_code      = tsx_LinesOfCode,
    tsx_modified_files     = tsx_ModifiedFileCount,
    tsx_insertions         = tsx_Insertions,
    tsx_deletions          = tsx_Deletions,
    css_insertions         = css_Insertions,
    css_deletions          = css_Deletions,
    scss_insertions        = scss_Insertions,
    scss_deletions         = scss_Deletions,
    backend_changes,
    frontend_changes,
    total_churn,
    is_forecast_row,
    calculated_at
  ) %>%
  # lpp_count, lpd_count, story_count default to 0 — populated later by
  # transform_forecast_input.R once Jira data is extracted.
  # breaking_changes defaults to 0 — populated once breaking_changes script is integrated.
  mutate(
    lpp_count        = 0L,
    lpd_count        = 0L,
    story_count      = 0L,
    breaking_changes = 0
  )

# Temp table
dbExecute(con, "
  CREATE TEMP TABLE _tmp_churn_ingest (LIKE fact_forecast_input INCLUDING DEFAULTS)
  ON COMMIT DROP
")

dbWriteTable(con, "_tmp_churn_ingest", to_write, overwrite = TRUE, row.names = FALSE)

# Build SET clause for all churn columns (don't overwrite bug counts if already populated)
update_cols <- c(
  "release_id",
  "java_file_count", "java_lines_of_code", "java_modified_files",
  "java_insertions", "java_deletions",
  "js_file_count", "js_lines_of_code", "js_modified_files",
  "js_insertions", "js_deletions",
  "jsp_file_count", "jsp_lines_of_code", "jsp_modified_files",
  "jsp_insertions", "jsp_deletions",
  "ts_file_count", "ts_lines_of_code", "ts_modified_files",
  "ts_insertions", "ts_deletions",
  "tsx_file_count", "tsx_lines_of_code", "tsx_modified_files",
  "tsx_insertions", "tsx_deletions",
  "css_insertions", "css_deletions",
  "scss_insertions", "scss_deletions",
  "backend_changes", "frontend_changes", "total_churn",
  "is_forecast_row", "calculated_at"
)

set_clause <- paste(
  sapply(update_cols, function(c) sprintf("%s = EXCLUDED.%s", c, c)),
  collapse = ",\n    "
)

rows_affected <- dbExecute(con, sprintf("
  INSERT INTO fact_forecast_input
    (component_id, quarter, release_id,
     java_file_count, java_lines_of_code, java_modified_files,
     java_insertions, java_deletions,
     js_file_count, js_lines_of_code, js_modified_files,
     js_insertions, js_deletions,
     jsp_file_count, jsp_lines_of_code, jsp_modified_files,
     jsp_insertions, jsp_deletions,
     ts_file_count, ts_lines_of_code, ts_modified_files,
     ts_insertions, ts_deletions,
     tsx_file_count, tsx_lines_of_code, tsx_modified_files,
     tsx_insertions, tsx_deletions,
     css_insertions, css_deletions,
     scss_insertions, scss_deletions,
     backend_changes, frontend_changes, total_churn,
     lpp_count, lpd_count, story_count,
     breaking_changes,
     is_forecast_row, calculated_at)
  SELECT
    component_id, quarter, release_id,
    java_file_count, java_lines_of_code, java_modified_files,
    java_insertions, java_deletions,
    js_file_count, js_lines_of_code, js_modified_files,
    js_insertions, js_deletions,
    jsp_file_count, jsp_lines_of_code, jsp_modified_files,
    jsp_insertions, jsp_deletions,
    ts_file_count, ts_lines_of_code, ts_modified_files,
    ts_insertions, ts_deletions,
    tsx_file_count, tsx_lines_of_code, tsx_modified_files,
    tsx_insertions, tsx_deletions,
    css_insertions, css_deletions,
    scss_insertions, scss_deletions,
    backend_changes, frontend_changes, total_churn,
    lpp_count, lpd_count, story_count,
    breaking_changes,
    is_forecast_row, calculated_at
  FROM _tmp_churn_ingest
  ON CONFLICT (component_id, quarter)
    DO UPDATE SET
    %s
", set_clause))

message(sprintf("  ✓ Upserted %d rows into fact_forecast_input", rows_affected))

# =============================================================================
# 8. CACHE TO STAGING
# =============================================================================
cache_path <- file.path(STAGING, "transformed_churn_input.rds")
saveRDS(rolled_up, cache_path)
message(sprintf("  ✓ Cache written to %s", cache_path))

# =============================================================================
# 9. VALIDATION SUMMARY
# =============================================================================
message("\n=== VALIDATION ===")

summary_q <- dbGetQuery(con, "
  SELECT
    fi.quarter,
    dr.is_major_release,
    dr.is_lts,
    COUNT(*)                            AS n_components,
    ROUND(AVG(fi.total_churn)::NUMERIC) AS avg_total_churn,
    ROUND(AVG(fi.backend_changes)::NUMERIC)  AS avg_backend,
    ROUND(AVG(fi.frontend_changes)::NUMERIC) AS avg_frontend
  FROM fact_forecast_input fi
  JOIN dim_release dr ON dr.release_label = fi.quarter
  GROUP BY fi.quarter, dr.is_major_release, dr.is_lts, dr.release_date
  ORDER BY COALESCE(dr.release_date, '9999-12-31'), fi.quarter
")

print(summary_q)

message("\n✅ ingest_churn_csv.R complete")
message("   Next: run transform_forecast_input.R to add LPP/LPD bug counts")
message("   Then: render release_situation_deck.Rmd")
