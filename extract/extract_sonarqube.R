# =============================================================================
# extract_sonarqube.R
# Extracts file-level metrics from SonarQube for top 5,000 files by churn
#
# Fetches per file: complexity, cognitive_complexity, violations,
#                   blocker_violations, critical_violations, ncloc, debt
#
# Replaces two-tier approach — single request per file covers all metrics
# Checkpoints every 100 files for resume on failure
#
# Output: staging/raw_sonarqube_combined.rds
# =============================================================================

library(dplyr)
library(httr)
library(jsonlite)
library(logger)
library(yaml)
library(glue)
library(DBI)
library(RPostgres)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- extract_sonarqube started ---")

source("config/release_analytics_db")
cfg         <- read_yaml("config/config.yml")
base_url    <- cfg$sonarqube$base_url
token       <- cfg$sonarqube$token
project_key <- cfg$sonarqube$project_key
con         <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

CHECKPOINT_FILE <- "staging/sonarqube_extract_checkpoint.rds"
CHECKPOINT_EVERY <- 100
TARGET_FILES <- 25092
METRICS <- "complexity,cognitive_complexity,violations,blocker_violations,critical_violations,ncloc,sqale_index"

# -----------------------------------------------------------------------------
# Helper: GET with auth and retry
# -----------------------------------------------------------------------------
sonar_get <- function(endpoint, query_params) {
  for (attempt in 1:3) {
    resp <- tryCatch(
      GET(
        url        = glue("{base_url}{endpoint}"),
        query      = query_params,
        authenticate(token, "", type = "basic"),
        timeout(15)
      ),
      error = function(e) NULL
    )
    if (!is.null(resp) && status_code(resp) == 200) return(resp)
    if (!is.null(resp) && status_code(resp) == 404) return(NULL)  # skip missing files fast
    Sys.sleep(2)  # flat 2 second wait, not exponential
  }
  return(NULL)  # return NULL instead of stopping — let loop continue
}

# -----------------------------------------------------------------------------
# Get top 5,000 files by churn from DB
# -----------------------------------------------------------------------------
log_info("Loading top {TARGET_FILES} files by churn score...")

target_files <- dbGetQuery(con, "
  SELECT f.file_path, s.churn_score
  FROM fact_file_risk_score s
  JOIN dim_file f ON s.file_id = f.file_id
  WHERE f.language = 'java'
  AND f.file_path NOT LIKE '%Test.java'
  AND f.file_path NOT LIKE '%TestCase.java'
  AND f.file_path NOT LIKE '%/test/%'
  AND f.file_path NOT LIKE '%/testIntegration/%'
  AND f.file_path NOT LIKE '%/testFunctional/%'
  AND f.file_path NOT SIMILAR TO '%/Base[A-Z]%Impl.java'
  ORDER BY s.churn_score DESC
")

log_info("Target files loaded: {nrow(target_files)}")

# -----------------------------------------------------------------------------
# Resume from checkpoint if available
# -----------------------------------------------------------------------------
results      <- list()
start_index  <- 1

if (file.exists(CHECKPOINT_FILE)) {
  checkpoint  <- readRDS(CHECKPOINT_FILE)
  results     <- checkpoint$results
  start_index <- checkpoint$next_index
  log_info("Resuming from checkpoint — file {start_index} of {nrow(target_files)}")
} else {
  log_info("Starting fresh extract...")
}

# -----------------------------------------------------------------------------
# Fetch metrics per file
# -----------------------------------------------------------------------------
log_info("Fetching SonarQube metrics for {nrow(target_files) - start_index + 1} remaining files...")

for (i in start_index:nrow(target_files)) {
  file_path     <- target_files$file_path[i]
  component_key <- glue("{project_key}:{file_path}")

  resp <- tryCatch(
    sonar_get("/api/measures/component", list(
      component  = component_key,
      metricKeys = METRICS
    )),
    error = function(e) {
      log_info("  Skipping {basename(file_path)}: {e$message}")
      NULL
    }
  )

  if (!is.null(resp)) {
    parsed   <- fromJSON(content(resp, as = "text", encoding = "UTF-8"), flatten = TRUE)
    measures <- parsed$component$measures

    if (!is.null(measures) && nrow(measures) > 0) {
      get_metric <- function(key) {
        val <- measures$value[measures$metric == key]
        if (length(val) == 0 || is.na(val)) return(0)
        as.numeric(val)
      }

      results[[i]] <- data.frame(
        file_path                = file_path,
        cyclomatic_complexity    = get_metric("complexity"),
        cognitive_complexity     = get_metric("cognitive_complexity"),
        violation_count          = get_metric("violations"),
        violation_blocker_count  = get_metric("blocker_violations"),
        violation_critical_count = get_metric("critical_violations"),
        lines_of_code            = get_metric("ncloc"),
        tech_debt_minutes        = get_metric("sqale_index"),
        stringsAsFactors         = FALSE
      )
    }
  }

  # Checkpoint
  if (i %% CHECKPOINT_EVERY == 0) {
    saveRDS(list(results = results, next_index = i + 1), CHECKPOINT_FILE)
    elapsed_per_file <- 2  # approximate
    remaining <- nrow(target_files) - i
    eta_min <- round(remaining * elapsed_per_file / 60, 0)
    log_info("  Progress: {i} of {nrow(target_files)} files — ~{eta_min} min remaining")
  }

  Sys.sleep(0.1)
}

# -----------------------------------------------------------------------------
# Combine and save
# -----------------------------------------------------------------------------
sonarqube_combined <- bind_rows(results)
log_info("SonarQube extract complete: {nrow(sonarqube_combined)} files")

saveRDS(sonarqube_combined, "staging/raw_sonarqube_combined.rds")
log_info("Saved staging/raw_sonarqube_combined.rds")

# Clean up checkpoint
if (file.exists(CHECKPOINT_FILE)) file.remove(CHECKPOINT_FILE)

# Summary
log_info("Top 10 files by cyclomatic complexity:")
top10 <- sonarqube_combined |>
  arrange(desc(cyclomatic_complexity)) |>
  head(10)

for (i in seq_len(nrow(top10))) {
  log_info("  {basename(top10$file_path[i])}: cyclomatic={top10$cyclomatic_complexity[i]}, cognitive={top10$cognitive_complexity[i]}, violations={top10$violation_count[i]}")
}

log_info("--- extract_sonarqube complete ---")

#
# == Remove later ==
#
target_files <- dbGetQuery(con, "
  SELECT f.file_path
  FROM fact_file_risk_score s
  JOIN dim_file f ON s.file_id = f.file_id
  WHERE f.language = 'java'
  AND f.file_path NOT LIKE '%Test.java'
  AND f.file_path NOT LIKE '%/test/%'
  AND f.file_path NOT LIKE '%/testIntegration/%'
  ORDER BY s.churn_score DESC
  LIMIT 1
")

component_key <- glue::glue("liferay-portal:{target_files$file_path[1]}")
cat(component_key, "\n")

resp <- GET(
  url   = "http://localhost:9000/api/measures/component",
  query = list(component = component_key, metricKeys = "complexity"),
  authenticate(token, "", type = "basic"),
  timeout(30)
)
cat(status_code(resp), "\n")
