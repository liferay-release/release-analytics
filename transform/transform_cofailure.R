# =============================================================================
# transform_cofailure.R
# Computes two co-failure signals from Testray build history:
#
#   1. Component co-failure pairs
#      Which components tend to fail together in the same build?
#      High co-failure frequency = runtime blast radius that the static
#      dependency graph (build.gradle) cannot capture — e.g. two modules
#      with no compile-time relationship that always break together at runtime.
#
#      Approach:
#        - Unit of analysis is the TEST CASE, not the build
#        - Build-level co-failure (any failure in component = build failed) was
#          rejected because a single flaky test inflates a component fail rate
#          to near-100%, making everything appear co-correlated
#        - Jaccard similarity computed at test-case level, aggregated to
#          component pairs (simple mean, not weighted — Jaccard is already
#          normalized to 0-1 per pair)
#        - No hard exclusion of chronic components — Jaccard handles it
#        - Requires 5+ independent test pairs (test_pair_count > 4) for
#          confident component-level signal
#        - 365-day rolling window on start_date
#        - Computation delegated to db/cofailure_pairs.sql for performance
#          (R self-join timed out; SQL + indexes completes in ~15 min)
#
#   2. Test case quality scores
#      Which test cases most reliably catch real bugs?
#      Measured by correlation between test failure and linked Jira issues.
#      Note: jira_issue links are weak signal (mostly investigation tickets,
#      not bug/fix distinctions). Kept for future improvement when better
#      Jira linkage is available.
#
# Scope: EE Development Acceptance (master), EE Development (master),
#        EE Package Tester, [master] ci:test:upstream-dxp
#
# Exclusions:
#   - CI infrastructure failures (timeouts, build failures, git sync errors)
#   - Non-functional case types (Batch, Compile, Semantic Versioning, etc.)
#   - 29% of raw failures were infrastructure noise — excluded from all analysis
#
# Input:  testray_analytical.caseresult_analytical
#         db/cofailure_pairs.sql (co-failure computation)
# Output: fact_component_cofailure (release_analytics)
#         fact_test_quality        (release_analytics)
#         staging/transformed_cofailure.rds
# =============================================================================

library(dplyr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_cofailure started ---")

cfg <- read_yaml("config/config.yml")

# -----------------------------------------------------------------------------
# Connections
# -----------------------------------------------------------------------------
get_connection <- function(db_key) {
  db <- cfg$databases[[db_key]]
  dbConnect(
    RPostgres::Postgres(),
    host     = db$host,
    port     = db$port,
    dbname   = db$dbname,
    user     = db$user,
    password = db$password
  )
}

con_testray   <- get_connection("testray")
con_analytics <- get_connection("release_analytics")

on.exit({
  dbDisconnect(con_testray)
  dbDisconnect(con_analytics)
}, add = TRUE)

ROUTINES <- c(
  "EE Development Acceptance (master)",
  "EE Development (master)",
  "EE Package Tester",
  "[master] ci:test:upstream-dxp"
)

MIN_FAIL_BUILDS <- 10  # minimum builds a test case must fail to qualify for quality scoring

# -----------------------------------------------------------------------------
# Step 1 — Component co-failure pairs via SQL
# Heavy computation delegated to db/cofailure_pairs.sql.
# Runs against testray_analytical with indexes on caseresult_analytical.
# -----------------------------------------------------------------------------
log_info("Running co-failure SQL (db/cofailure_pairs.sql)...")

cofail_sql <- paste(readLines("db/cofailure_pairs.sql"), collapse = "\n")
cofail_scored <- cofail_scored |>
  distinct(component_a, component_b, .keep_all = TRUE)

log_info("Co-failure pairs returned: {nrow(cofail_scored)}")
log_info("Top 10 co-failure pairs by Jaccard score:")
cofail_scored |>
  head(10) |>
  rowwise() |>
  group_walk(~ log_info("  {.x$component_a} <-> {.x$component_b}: jaccard={.x$jaccard_score} co_fail_builds={.x$co_fail_builds} test_pairs={.x$test_pair_count}"))

# -----------------------------------------------------------------------------
# Step 2 — Test case quality scores
# Pulled directly from testray_analytical — stays in R since it is simpler
# and does not have the join performance problem of co-failure computation.
# -----------------------------------------------------------------------------
log_info("Loading failures for test quality scoring...")

routines_sql <- paste(sprintf("'%s'", ROUTINES), collapse = ", ")

failures <- dbGetQuery(con_testray, sprintf("
  SELECT
    build_id,
    case_id,
    case_name,
    case_type,
    component_name,
    team_name,
    jira_issue,
    start_date
  FROM caseresult_analytical
  WHERE routine_name IN (%s)
  AND status = 'FAILED'
  AND start_date >= CURRENT_DATE - INTERVAL '365 days'
  AND case_type NOT IN (
    'Batch',
    'Modules Compile Test',
    'Modules Integration AWS Test',
    'Modules Semantic Versioning Test',
    'Release OSGI State Test',
    'Semantic Versioning Test',
    'LPKG Test'
  )
  AND (
    errors IS NULL
    OR (
      errors NOT ILIKE 'Failed prior to running test%%%%'
      AND errors NOT ILIKE '%%%%Failed to run test on CI%%%%'
      AND errors NOT ILIKE 'The build failed prior to running the test%%%%'
      AND errors NOT ILIKE '%%%%timed out after 2 hours%%%%'
      AND errors NOT ILIKE '%%%%Unable to synchronize with local Git mirror%%%%'
      AND errors NOT ILIKE '%%%%test failed to compile successfully%%%%'
    )
  )
", routines_sql))

log_info("Failures loaded for quality scoring: {nrow(failures)}")
log_info("Distinct test cases: {n_distinct(failures$case_id)}")

log_info("Computing test case quality scores...")

test_quality <- failures |>
  group_by(case_id, case_name, case_type, component_name, team_name) |>
  summarise(
    total_fail_builds    = n_distinct(build_id),
    bug_linked_builds    = n_distinct(build_id[!is.na(jira_issue) & nchar(jira_issue) > 0]),
    distinct_bugs_linked = n_distinct(jira_issue[!is.na(jira_issue) & nchar(jira_issue) > 0]),
    .groups = "drop"
  ) |>
  mutate(
    investigation_rate = round(bug_linked_builds / total_fail_builds, 4),
    signal_score       = round(
      (
        (investigation_rate * 0.70) +
          (pmin(bug_linked_builds / max(bug_linked_builds, 1), 1) * 0.30)
      ) * (1 - sqrt(total_fail_builds) / sqrt(max(total_fail_builds, 1))),
      4
    )
  ) |>
  filter(total_fail_builds >= MIN_FAIL_BUILDS) |>
  arrange(desc(signal_score), desc(investigation_rate), desc(total_fail_builds))

# Resolve cases mapped to multiple components — keep most recent component
latest_component <- failures |>
  group_by(case_id) |>
  slice_max(start_date, n = 1, with_ties = FALSE) |>
  select(case_id, component_name) |>
  rename(latest_component = component_name)

test_quality <- test_quality |>
  left_join(latest_component, by = "case_id") |>
  mutate(component_name = latest_component) |>
  select(-latest_component) |>
  group_by(case_id) |>
  slice_max(total_fail_builds, n = 1, with_ties = FALSE) |>
  ungroup()

log_info("Test cases scored: {nrow(test_quality)}")
log_info("Test cases with at least one bug linked: {sum(test_quality$bug_linked_builds > 0)}")
log_info("Top 10 highest signal test cases:")
test_quality |>
  head(10) |>
  rowwise() |>
  group_walk(~ log_info("  [{.x$component_name}] {.x$case_name}: signal={.x$signal_score} investigation_rate={.x$investigation_rate} ({.x$bug_linked_builds}/{.x$total_fail_builds})"))

# -----------------------------------------------------------------------------
# Step 3 — Create tables in release_analytics if not exists
# -----------------------------------------------------------------------------
dbExecute(con_analytics, "ALTER TABLE fact_component_cofailure ADD COLUMN IF NOT EXISTS co_fail_builds  INT DEFAULT 0")
dbExecute(con_analytics, "ALTER TABLE fact_component_cofailure ADD COLUMN IF NOT EXISTS test_pair_count INT DEFAULT 0")
dbExecute(con_analytics, "ALTER TABLE fact_component_cofailure ADD COLUMN IF NOT EXISTS fail_rate_a     NUMERIC(6,4) DEFAULT 0")
dbExecute(con_analytics, "ALTER TABLE fact_component_cofailure ADD COLUMN IF NOT EXISTS fail_rate_b     NUMERIC(6,4) DEFAULT 0")

dbExecute(con_analytics, "
  CREATE TABLE IF NOT EXISTS fact_component_cofailure (
    cofailure_id     SERIAL PRIMARY KEY,
    component_a      VARCHAR(200) NOT NULL,
    component_b      VARCHAR(200) NOT NULL,
    co_fail_builds   INT DEFAULT 0,
    co_fail_count    INT DEFAULT 0,
    co_fail_rate     NUMERIC(6,4) DEFAULT 0,
    test_pair_count  INT DEFAULT 0,
    fail_count_a     INT DEFAULT 0,
    fail_count_b     INT DEFAULT 0,
    fail_rate_a      NUMERIC(6,4) DEFAULT 0,
    fail_rate_b      NUMERIC(6,4) DEFAULT 0,
    jaccard_score    NUMERIC(6,4) DEFAULT 0,
    calculated_at    TIMESTAMP DEFAULT NOW(),
    UNIQUE (component_a, component_b)
  )
")

dbExecute(con_analytics, "
  CREATE TABLE IF NOT EXISTS fact_test_quality (
    test_quality_id      SERIAL PRIMARY KEY,
    case_id              BIGINT,
    case_name            VARCHAR(500),
    case_type            VARCHAR(200),
    component_name       VARCHAR(200),
    team_name            VARCHAR(200),
    total_fail_builds    INT DEFAULT 0,
    bug_linked_builds    INT DEFAULT 0,
    distinct_bugs_linked INT DEFAULT 0,
    investigation_rate   NUMERIC(6,4) DEFAULT 0,
    signal_score         NUMERIC(6,4) DEFAULT 0,
    calculated_at        TIMESTAMP DEFAULT NOW(),
    UNIQUE (case_id)
  )
")

# -----------------------------------------------------------------------------
# Step 4 — Upsert fact_component_cofailure
# -----------------------------------------------------------------------------
log_info("Upserting fact_component_cofailure...")

dbWriteTable(con_analytics, "temp_cofailure",
             cofail_scored |>
               select(component_a, component_b, co_fail_builds, co_fail_count,
                      co_fail_rate, test_pair_count, fail_count_a, fail_count_b,
                      fail_rate_a, fail_rate_b, jaccard_score),
             temporary = TRUE, overwrite = TRUE
)

dbExecute(con_analytics, "
  INSERT INTO fact_component_cofailure (
    component_a, component_b, co_fail_builds, co_fail_count, co_fail_rate,
    test_pair_count, fail_count_a, fail_count_b, fail_rate_a, fail_rate_b,
    jaccard_score, calculated_at
  )
  SELECT component_a, component_b, co_fail_builds, co_fail_count, co_fail_rate,
         test_pair_count, fail_count_a, fail_count_b, fail_rate_a, fail_rate_b,
         jaccard_score, NOW()
  FROM temp_cofailure
  ON CONFLICT (component_a, component_b) DO UPDATE SET
    co_fail_builds  = EXCLUDED.co_fail_builds,
    co_fail_count   = EXCLUDED.co_fail_count,
    co_fail_rate    = EXCLUDED.co_fail_rate,
    test_pair_count = EXCLUDED.test_pair_count,
    fail_count_a    = EXCLUDED.fail_count_a,
    fail_count_b    = EXCLUDED.fail_count_b,
    fail_rate_a     = EXCLUDED.fail_rate_a,
    fail_rate_b     = EXCLUDED.fail_rate_b,
    jaccard_score   = EXCLUDED.jaccard_score,
    calculated_at   = NOW()
")

dbExecute(con_analytics, "DROP TABLE IF EXISTS temp_cofailure")

cofailure_count <- dbGetQuery(con_analytics, "SELECT COUNT(*) AS n FROM fact_component_cofailure")$n
log_info("fact_component_cofailure rows: {cofailure_count}")

# -----------------------------------------------------------------------------
# Step 5 — Upsert fact_test_quality
# -----------------------------------------------------------------------------
log_info("Upserting fact_test_quality...")

dbWriteTable(con_analytics, "temp_test_quality",
             test_quality |>
               select(case_id, case_name, case_type, component_name, team_name,
                      total_fail_builds, bug_linked_builds, distinct_bugs_linked,
                      investigation_rate, signal_score),
             temporary = TRUE, overwrite = TRUE
)

dbExecute(con_analytics, "
  INSERT INTO fact_test_quality (
    case_id, case_name, case_type, component_name, team_name,
    total_fail_builds, bug_linked_builds, distinct_bugs_linked,
    investigation_rate, signal_score, calculated_at
  )
  SELECT case_id, case_name, case_type, component_name, team_name,
         total_fail_builds, bug_linked_builds, distinct_bugs_linked,
         investigation_rate, signal_score, NOW()
  FROM temp_test_quality
  ON CONFLICT (case_id) DO UPDATE SET
    case_name            = EXCLUDED.case_name,
    case_type            = EXCLUDED.case_type,
    component_name       = EXCLUDED.component_name,
    team_name            = EXCLUDED.team_name,
    total_fail_builds    = EXCLUDED.total_fail_builds,
    bug_linked_builds    = EXCLUDED.bug_linked_builds,
    distinct_bugs_linked = EXCLUDED.distinct_bugs_linked,
    investigation_rate   = EXCLUDED.investigation_rate,
    signal_score         = EXCLUDED.signal_score,
    calculated_at        = NOW()
")

dbExecute(con_analytics, "DROP TABLE IF EXISTS temp_test_quality")

quality_count <- dbGetQuery(con_analytics, "SELECT COUNT(*) AS n FROM fact_test_quality")$n
log_info("fact_test_quality rows: {quality_count}")

# -----------------------------------------------------------------------------
# Step 6 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(
  list(cofailure = cofail_scored, test_quality = test_quality),
  "staging/transformed_cofailure.rds"
)
log_info("Saved staging/transformed_cofailure.rds")
log_info("--- transform_cofailure complete ---")
