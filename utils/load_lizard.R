# =============================================================================
# utils/load_lizard.R
# Loads lizard function-level complexity output into PostgreSQL.
#
# Pipeline position: runs after lizard CLI, before transform_forecast_input.R
# Output: stg_lizard_raw (function-level), fact_file_complexity (file-level)
#
# Usage:
#   Rscript utils/load_lizard.R
#   source("utils/load_lizard.R")
# =============================================================================

library(tidyverse)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)
library(glue)

log_info("=== load_lizard.R started ===")

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
cfg         <- yaml::read_yaml("config/config.yml")
lizard_path <- "data/lizard_output_20250323.csv"

con <- dbConnect(
  RPostgres::Postgres(),
  host     = cfg$databases$release_analytics$host,
  port     = cfg$databases$release_analytics$port,
  dbname   = cfg$databases$release_analytics$dbname,
  user     = cfg$databases$release_analytics$user,
  password = cfg$databases$release_analytics$password
)
log_info("DB connection established")

# -----------------------------------------------------------------------------
# 1. Load CSV
# -----------------------------------------------------------------------------
log_info("Reading {lizard_path}")

liz <- read_csv(
  lizard_path,
  col_names = c("NLOC", "CCN", "token_count", "PARAM", "length",
                "location", "file", "function_name", "long_name",
                "start_line", "end_line"),
  skip           = 1,
  show_col_types = FALSE
)

log_info("Raw rows loaded: {nrow(liz)}")

# -----------------------------------------------------------------------------
# 2. Clean and filter
# -----------------------------------------------------------------------------
liz_clean <- liz %>%
  # Strip leading ./
  mutate(file = str_remove(file, "^\\./" )) %>%

  # Exclude third-party, ANTLR-generated, and osb (extra nesting depth, zero component mappings)
  filter(
    !str_detect(file, "^modules/third-party/"),
    !str_detect(file, "/antlr/"),
    !str_detect(file, "^modules/dxp/apps/osb/")
  ) %>%

  # Cap CCN at 100
  mutate(CCN = pmin(CCN, 100)) %>%

  # Derive module_path — depth-aware:
  #   5-segment: dxp (non-osb) + deep-nesting apps categories
  #   3-segment: all other groups
  mutate(module_path = case_when(
    str_detect(file, "^modules/dxp/") |
    str_detect(file, "^modules/apps/commerce/") |
    str_detect(file, "^modules/apps/fragment/") |
    str_detect(file, "^modules/apps/headless/") |
    str_detect(file, "^modules/apps/layout/") |
    str_detect(file, "^modules/apps/portlet-configuration/") |
    str_detect(file, "^modules/apps/push-notifications/") |
    str_detect(file, "^modules/apps/site-initializer/") |
    str_detect(file, "^modules/apps/static/") ~
      str_replace(file, "^(modules/[^/]+/[^/]+/[^/]+/[^/]+).*", "\\1"),
    str_detect(file, "^modules/") ~
      str_replace(file, "^(modules/[^/]+/[^/]+).*", "\\1"),
    TRUE ~ NA_character_
  )) %>%

  # Classify language
  mutate(
    ext      = tools::file_ext(file),
    language = case_when(
      ext == "java"                              ~ "java",
      ext %in% c("js", "ts", "jsx", "tsx", "mjs") ~ "frontend",
      TRUE                                       ~ "other"
    )
  ) %>%

  # Drop unmapped and 'other' language rows
  filter(
    !is.na(module_path),
    language != "other"
  ) %>%

  # Rename to match staging DDL
  rename(
    nloc        = NLOC,
    ccn         = CCN,
    param_count = PARAM,
    file_path   = file
  ) %>%

  # Select staging columns in DDL order
  select(
    nloc, ccn, token_count, param_count, length,
    location, file_path, function_name, long_name,
    start_line, end_line, language, module_path
  )

log_info("Rows after exclusions + cap: {nrow(liz_clean)}")
log_info("Excluded rows: {nrow(liz) - nrow(liz_clean)}")

liz_clean %>%
  count(language) %>%
  pwalk(~log_info("  {..1}: {..2} functions"))

# Abort if coverage looks wrong
coverage_pct <- mean(!is.na(liz_clean$module_path)) * 100
log_info("Module path coverage: {round(coverage_pct, 1)}%")
if (coverage_pct < 95) {
  log_error("Coverage below 95% — aborting. Check REGEXP pattern or file paths.")
  dbDisconnect(con)
  stop("Coverage check failed")
}

# -----------------------------------------------------------------------------
# 3. Stage: truncate and reload stg_lizard_raw
# -----------------------------------------------------------------------------
log_info("Truncating stg_lizard_raw")
dbExecute(con, "TRUNCATE TABLE stg_lizard_raw")

log_info("Writing {nrow(liz_clean)} rows to stg_lizard_raw")
dbWriteTable(
  con,
  name      = "stg_lizard_raw",
  value     = liz_clean,
  append    = TRUE,
  row.names = FALSE
)
log_info("stg_lizard_raw load complete")

# -----------------------------------------------------------------------------
# 4a. Upsert new file paths into dim_file
#     lizard may have found files SonarQube never catalogued.
#     module_id resolved via dim_module.module_path_full -> dim_module.module_id
# -----------------------------------------------------------------------------
log_info("Upserting new file paths into dim_file")

dim_file_upsert_sql <- "
INSERT INTO dim_file (file_path, module_id, language, is_active)
SELECT DISTINCT
    s.file_path,
    dm.module_id,
    s.language,
    TRUE
FROM stg_lizard_raw s
LEFT JOIN dim_module dm ON dm.module_path_full = s.module_path
WHERE NOT EXISTS (
    SELECT 1 FROM dim_file df WHERE df.file_path = s.file_path
)
ON CONFLICT (file_path) DO NOTHING;
"

new_files <- dbExecute(con, dim_file_upsert_sql)
log_info("dim_file: {new_files} new file rows inserted")

# -----------------------------------------------------------------------------
# 4b. File-level aggregation -> fact_file_complexity
#     Joins stg_lizard_raw -> dim_file to resolve file_id FK
# -----------------------------------------------------------------------------
log_info("Aggregating file-level complexity into fact_file_complexity")

file_agg_sql <- "
INSERT INTO fact_file_complexity (
    file_id,
    avg_ccn,
    avg_nloc,
    max_ccn,
    avg_ccn_java,
    avg_nloc_java,
    avg_ccn_frontend,
    avg_nloc_frontend,
    language_mix,
    tech_debt_minutes,
    snapshot_date,
    calculated_at
)
SELECT
    df.file_id,

    ROUND(AVG(s.ccn)::NUMERIC,  2) AS avg_ccn,
    ROUND(AVG(s.nloc)::NUMERIC, 2) AS avg_nloc,
    MAX(s.ccn)                      AS max_ccn,

    ROUND(AVG(s.ccn)  FILTER (WHERE s.language = 'java')::NUMERIC,     2) AS avg_ccn_java,
    ROUND(AVG(s.nloc) FILTER (WHERE s.language = 'java')::NUMERIC,     2) AS avg_nloc_java,
    ROUND(AVG(s.ccn)  FILTER (WHERE s.language = 'frontend')::NUMERIC, 2) AS avg_ccn_frontend,
    ROUND(AVG(s.nloc) FILTER (WHERE s.language = 'frontend')::NUMERIC, 2) AS avg_nloc_frontend,

    CASE
        WHEN COUNT(*) FILTER (WHERE s.language = 'java')     > 0
         AND COUNT(*) FILTER (WHERE s.language = 'frontend') > 0 THEN 'mixed'
        WHEN COUNT(*) FILTER (WHERE s.language = 'java')     > 0 THEN 'java_only'
        ELSE 'frontend_only'
    END AS language_mix,

    0            AS tech_debt_minutes,
    CURRENT_DATE AS snapshot_date,
    NOW()        AS calculated_at

FROM stg_lizard_raw s
JOIN dim_file df ON df.file_path = s.file_path

GROUP BY df.file_id

ON CONFLICT (file_id) DO UPDATE SET
    avg_ccn           = EXCLUDED.avg_ccn,
    avg_nloc          = EXCLUDED.avg_nloc,
    max_ccn           = EXCLUDED.max_ccn,
    avg_ccn_java      = EXCLUDED.avg_ccn_java,
    avg_nloc_java     = EXCLUDED.avg_nloc_java,
    avg_ccn_frontend  = EXCLUDED.avg_ccn_frontend,
    avg_nloc_frontend = EXCLUDED.avg_nloc_frontend,
    language_mix      = EXCLUDED.language_mix,
    tech_debt_minutes = 0,
    snapshot_date     = EXCLUDED.snapshot_date,
    calculated_at     = EXCLUDED.calculated_at;
"

rows_affected <- dbExecute(con, file_agg_sql)
log_info("fact_file_complexity upserted: {rows_affected} file-level rows")

# -----------------------------------------------------------------------------
# 5. Update scoring_normalization p95 denominators
#
# complexity_p95 (max_ccn denominator) is PINNED at 16.
#   - Anchored at lizard's own warning threshold (CCN >= 15 = complex function)
#   - Using max_ccn not avg_ccn — worst function per file is where bugs live
#   - avg_ccn gets diluted by getters/setters in OSGi modules; max_ccn does not
#   - DO NOT auto-recalibrate this value — it is a fixed reference point,
#     not a corpus statistic. Changing it shifts all historical risk scores.
#
# cognitive_p95 (avg_nloc) continues to auto-recalibrate — it has no
# established industry threshold equivalent to CCN 15.
# -----------------------------------------------------------------------------
log_info("Updating scoring_normalization p95 denominators")

MAX_CCN_P95_PINNED <- 16  # fixed — lizard warning threshold anchor, do not change

recal_sql <- glue::glue("
UPDATE scoring_normalization
SET
    complexity_p95 = {MAX_CCN_P95_PINNED},
    cognitive_p95  = (
        SELECT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY avg_nloc)
        FROM fact_file_complexity
    ),
    calculated_at  = NOW()
WHERE scoring_version = '1.0';
")

recal_rows <- dbExecute(con, recal_sql)
log_info("scoring_normalization rows updated: {recal_rows}")

# Log current values for the record
p95_check <- dbGetQuery(con, "
  SELECT complexity_p95, cognitive_p95
  FROM scoring_normalization
  WHERE scoring_version = '1.0'
  LIMIT 1
")
log_info("  p95 complexity (max_ccn, pinned): {p95_check$complexity_p95[1]}")
log_info("  p95 cognitive  (avg_nloc, auto):  {p95_check$cognitive_p95[1]}")

# -----------------------------------------------------------------------------
# 6. Spot-check: top 10 components by max_ccn
#    Sorted by MAX(max_ccn) — worst function per file, per component.
#    This is the primary complexity signal used in scoring and L04.
# -----------------------------------------------------------------------------
log_info("Spot check: top 10 components by max_ccn")

spot <- dbGetQuery(con, "
  SELECT
      dc.component_name,
      MAX(f.max_ccn)                              AS component_max_ccn,
      ROUND(AVG(f.avg_ccn)::NUMERIC,          2) AS component_avg_ccn,
      ROUND(AVG(f.avg_ccn_java)::NUMERIC,     2) AS avg_ccn_java,
      ROUND(AVG(f.avg_ccn_frontend)::NUMERIC, 2) AS avg_ccn_frontend
  FROM fact_file_complexity f
  JOIN dim_file df                  ON df.file_id       = f.file_id
  JOIN dim_module dm                ON dm.module_id     = df.module_id
  JOIN dim_module_component_map mcm ON mcm.module_path  = dm.module_path_category
  JOIN dim_component dc             ON dc.component_id  = mcm.component_id
  GROUP BY dc.component_name
  ORDER BY component_max_ccn DESC
  LIMIT 10
")

pwalk(spot, ~log_info(
  "  {..1}: max_ccn={..2}, avg_ccn={..3}, java={..4}, frontend={..5}"
))

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
dbDisconnect(con)
log_info("=== load_lizard.R complete ===")