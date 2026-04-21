# =============================================================================
# load_testray.R
# Loads Testray case results from testray_analytical into fact_test_quality.
#
# Previously: queried raw o_22235989312226_* tables in testray_working_db.
# Now:        queries caseresult_analytical — denormalized, project-scoped,
#             names resolved inline.
#
# Routines:
#   590307 — EE Development Acceptance (master)  [daily gate]
#   82964  — EE Package Tester                   [pre-ship release gate]
#
# Grain: case × routine × window_quarter
#
# Filters:
#   Acceptance (590307): builds where pass rate >= 50%  (daily gate noise filter)
#   Release (82964):     builds where promoted_ = TRUE  (ship gate — authoritative only)
#   Windows: excluded if overall pass rate < 60% (CI/infra instability)
#
# Run after:  load_module_component_map.R
# Run before: export_looker.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(DBI)
  library(RPostgres)
  library(logger)
  library(yaml)
  library(purrr)
})

log_appender(appender_file(
  Sys.getenv("RAP_LOG_FILE", unset = "logs/pipeline.log"),
  append = TRUE
))
log_info("=== load_testray.R started ===")

cfg <- read_yaml("config/config.yml")

# -----------------------------------------------------------------------------
# Connections
# -----------------------------------------------------------------------------
db_connect <- function(db_cfg) {
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = db_cfg$host,
    port     = db_cfg$port,
    dbname   = db_cfg$dbname,
    user     = db_cfg$user,
    password = db_cfg$password %||% ""
  )
}

con         <- db_connect(cfg$databases$release_analytics)
con_testray <- db_connect(cfg$databases$testray)
on.exit({
  DBI::dbDisconnect(con)
  DBI::dbDisconnect(con_testray)
}, add = TRUE)

log_info("Connected: {cfg$databases$release_analytics$dbname} + {cfg$databases$testray$dbname}")

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
TARGET_ROUTINES <- list(
  list(id = 590307L, name = "EE Development Acceptance (master)"),
  list(id = 82964L,  name = "EE Package Tester")
)
WINDOW_MIN_PASS_RATE <- 0.60
FAILURE_STATUSES     <- c("FAILED", "BLOCKED", "UNTESTED", "TESTFIX")
EXCLUDED_COMPONENTS  <- c("A/B Test", "License", "Smoke")

routine_name_map <- tibble(
  routine_id   = as.integer(sapply(TARGET_ROUTINES, `[[`, "id")),
  routine_name = sapply(TARGET_ROUTINES, `[[`, "name")
)

# Load dev windows from config
dev_windows <- bind_rows(lapply(cfg$jira$dev_windows, as.data.frame)) %>%
  mutate(
    dev_start = as.Date(dev_start),
    dev_end   = as.Date(dev_end)
  )

# Add 2026.Q2 if IN_DEVELOPMENT but not yet in config
q2_check <- dbGetQuery(con, "
  SELECT release_label FROM dim_release
  WHERE release_label = '2026.Q2' AND release_status = 'IN_DEVELOPMENT'
  LIMIT 1
")
if (nrow(q2_check) > 0 && !("2026.Q2" %in% dev_windows$quarter)) {
  dev_windows <- bind_rows(dev_windows, tibble(
    quarter   = "2026.Q2",
    dev_start = as.Date("2026-02-28"),
    dev_end   = Sys.Date()
  ))
  log_info("Added open window for 2026.Q2 (IN_DEVELOPMENT) — dev_end = {Sys.Date()}")
}

log_info("Dev windows: {nrow(dev_windows)} quarters ({min(dev_windows$quarter)} to {max(dev_windows$quarter)})")

# -----------------------------------------------------------------------------
# Step 1 — Pull clean builds from caseresult_analytical
#   Acceptance (590307): builds with pass rate >= 50% (daily noise filter)
#   Release (82964):     builds with promoted_ = TRUE (ship gate)
# -----------------------------------------------------------------------------
log_info("Step 1: pulling clean builds")

acceptance_builds <- dbGetQuery(con_testray, "
  WITH build_stats AS (
    SELECT
      build_id,
      routine_id,
      MIN(build_date)                                       AS build_date,
      COUNT(*)                                              AS total_results,
      SUM(CASE WHEN status = 'PASSED' THEN 1 ELSE 0 END)    AS passed_count
    FROM caseresult_analytical
    WHERE routine_id = 590307
    GROUP BY build_id, routine_id
  )
  SELECT build_id, routine_id, build_date
  FROM build_stats
  WHERE total_results > 0
    AND passed_count::numeric / NULLIF(total_results, 0) >= 0.50
")

release_builds <- dbGetQuery(con_testray, "
  SELECT DISTINCT
    build_id,
    routine_id,
    build_date
  FROM caseresult_analytical
  WHERE routine_id = 82964
    AND build_promoted = TRUE
")

all_builds <- bind_rows(acceptance_builds, release_builds)

log_info("Acceptance builds (pass rate >= 50%%): {nrow(acceptance_builds)}")
log_info("Release builds (promoted only): {nrow(release_builds)}")
log_info("Total builds: {nrow(all_builds)}")

if (nrow(all_builds) == 0) {
  log_error("No builds found — check testray_analytical connection")
  stop("No builds to process")
}

# Assign each build to a dev window — vectorized cross join + filter
all_builds <- all_builds %>%
  left_join(
    dev_windows %>% rename(window_quarter = quarter),
    by = character()
  ) %>%
  filter(build_date >= dev_start & build_date <= dev_end) %>%
  group_by(build_id, routine_id, build_date) %>%
  slice(1) %>%
  ungroup() %>%
  dplyr::select(build_id, routine_id, build_date, window_quarter)

log_info("Builds assigned to dev windows: {nrow(all_builds)}")
window_cov <- all_builds %>%
  count(window_quarter, routine_id) %>%
  left_join(routine_name_map, by = "routine_id") %>%
  arrange(window_quarter, routine_id)
for (i in seq_len(nrow(window_cov))) {
  log_info("  [{window_cov$window_quarter[i]}] {window_cov$routine_name[i]}: {window_cov$n[i]} builds")
}

# -----------------------------------------------------------------------------
# Step 2 — Pull case results for selected builds (names already resolved)
# -----------------------------------------------------------------------------
log_info("Step 2: pulling case results ({nrow(all_builds)} builds)")

chunk_size <- 500
chunks     <- split(all_builds$build_id, ceiling(seq_along(all_builds$build_id) / chunk_size))

caseresults_raw <- bind_rows(lapply(chunks, function(ids) {
  dbGetQuery(con_testray, sprintf("
    SELECT
      case_id,
      build_id,
      case_name,
      case_type,
      component_name,
      team_name,
      status,
      jira_issue
    FROM caseresult_analytical
    WHERE build_id IN (%s)
  ", paste(ids, collapse = ", ")))
}))

log_info("Raw case results: {nrow(caseresults_raw)}")

build_map <- all_builds %>% dplyr::select(build_id, routine_id, window_quarter)
caseresults <- caseresults_raw %>%
  left_join(build_map, by = "build_id") %>%
  filter(
    !is.na(case_name),
    !grepl("modules-compile", case_name, ignore.case = TRUE),
    !(component_name %in% EXCLUDED_COMPONENTS)
  )

log_info("After exclusions: {nrow(caseresults)} case results")

# -----------------------------------------------------------------------------
# Step 3 — Aggregate to case × routine × window_quarter grain
# -----------------------------------------------------------------------------
log_info("Step 3: aggregating to case x routine x window_quarter grain")

aggregated <- caseresults %>%
  group_by(case_id, routine_id, window_quarter) %>%
  summarise(
    case_name            = first(case_name),
    case_type            = first(case_type),
    component_name       = first(component_name),
    team_name            = first(team_name),
    total_builds         = n_distinct(build_id),
    total_fail_builds    = sum(status %in% FAILURE_STATUSES),
    bug_linked_builds    = sum(
                             status %in% FAILURE_STATUSES &
                             !is.na(jira_issue) & nchar(trimws(jira_issue)) > 0
                           ),
    distinct_bugs_linked = n_distinct(
                             jira_issue[
                               status %in% FAILURE_STATUSES &
                               !is.na(jira_issue) & nchar(trimws(jira_issue)) > 0
                             ]
                           ),
    .groups = "drop"
  ) %>%
  mutate(
    investigation_rate = round(
      ifelse(total_fail_builds > 0, bug_linked_builds / total_fail_builds, 0),
      4
    ),
    signal_score = round(
      investigation_rate * (total_fail_builds / pmax(total_builds, 1)),
      4
    )
  ) %>%
  left_join(routine_name_map, by = "routine_id") %>%
  left_join(
    dev_windows %>% dplyr::select(
      window_quarter = quarter,
      window_start   = dev_start,
      window_end     = dev_end
    ),
    by = "window_quarter"
  )

log_info("Aggregated: {nrow(aggregated)} case x routine x window rows")

# -----------------------------------------------------------------------------
# Step 4 — Filter low-quality windows
# -----------------------------------------------------------------------------
window_pass_rates <- aggregated %>%
  group_by(routine_id, window_quarter) %>%
  summarise(
    window_pass_rate = (sum(total_builds) - sum(total_fail_builds)) /
                       pmax(sum(total_builds), 1),
    .groups = "drop"
  )

low_quality_windows <- window_pass_rates %>%
  filter(window_pass_rate < WINDOW_MIN_PASS_RATE)

if (nrow(low_quality_windows) > 0) {
  log_info("Excluding {nrow(low_quality_windows)} low-quality routine x window combinations (pass_rate < {WINDOW_MIN_PASS_RATE * 100}%%):")
  for (i in seq_len(nrow(low_quality_windows))) {
    log_info("  [{low_quality_windows$window_quarter[i]}] routine {low_quality_windows$routine_id[i]}: pass_rate={round(low_quality_windows$window_pass_rate[i]*100,1)}%%")
  }
  aggregated <- aggregated %>%
    anti_join(low_quality_windows, by = c("routine_id", "window_quarter"))
  log_info("Rows after exclusion: {nrow(aggregated)}")
}

# -----------------------------------------------------------------------------
# Step 5 — Upsert
# -----------------------------------------------------------------------------
log_info("Step 5: upserting into fact_test_quality")

dbWriteTable(con, "tmp_test_quality", aggregated,
             temporary = TRUE, overwrite = TRUE)

rows_upserted <- dbExecute(con, "
  INSERT INTO fact_test_quality (
    case_id, case_name, case_type,
    component_name, team_name,
    total_builds, total_fail_builds, bug_linked_builds, distinct_bugs_linked,
    investigation_rate, signal_score,
    routine_id, routine_name,
    window_quarter, window_start, window_end,
    calculated_at
  )
  SELECT
    case_id, case_name, case_type,
    component_name, team_name,
    total_builds, total_fail_builds, bug_linked_builds, distinct_bugs_linked,
    investigation_rate, signal_score,
    routine_id, routine_name,
    window_quarter, window_start, window_end,
    NOW()
  FROM tmp_test_quality
  ON CONFLICT (case_id, routine_id, window_quarter) DO UPDATE SET
    case_name            = EXCLUDED.case_name,
    case_type            = EXCLUDED.case_type,
    component_name       = EXCLUDED.component_name,
    team_name            = EXCLUDED.team_name,
    total_builds         = EXCLUDED.total_builds,
    total_fail_builds    = EXCLUDED.total_fail_builds,
    bug_linked_builds    = EXCLUDED.bug_linked_builds,
    distinct_bugs_linked = EXCLUDED.distinct_bugs_linked,
    investigation_rate   = EXCLUDED.investigation_rate,
    signal_score         = EXCLUDED.signal_score,
    routine_name         = EXCLUDED.routine_name,
    window_start         = EXCLUDED.window_start,
    window_end           = EXCLUDED.window_end,
    calculated_at        = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS tmp_test_quality")
log_info("Upserted: {rows_upserted} rows")

# -----------------------------------------------------------------------------
# Step 6 — Validation
# -----------------------------------------------------------------------------
log_info("Step 6: validation")

val <- dbGetQuery(con, "
  SELECT
    routine_id,
    routine_name,
    window_quarter,
    COUNT(*)                                              AS n_cases,
    COUNT(DISTINCT component_name)                        AS n_components,
    SUM(total_builds)                                     AS sum_builds,
    SUM(total_fail_builds)                                AS sum_failures,
    ROUND(
      (SUM(total_builds) - SUM(total_fail_builds))::NUMERIC /
      NULLIF(SUM(total_builds), 0) * 100, 1
    )                                                     AS pass_rate_pct,
    MAX(calculated_at)                                    AS last_updated
  FROM fact_test_quality
  WHERE routine_id IS NOT NULL
  GROUP BY routine_id, routine_name, window_quarter
  ORDER BY window_quarter, routine_id
")

log_info("Pass rates by routine x window:")
for (i in seq_len(nrow(val))) {
  log_info("  [{val$window_quarter[i]}] {val$routine_name[i]}: cases={val$n_cases[i]}, pass_rate={val$pass_rate_pct[i]}%")
}

log_info("=== load_testray.R complete ===")
