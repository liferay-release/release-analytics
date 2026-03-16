# =============================================================================
# extract_testray.R
# Extracts case results from Testray API with lookup joins
#
# Filters:
#   - dateCreated within last 30 days
#   - routine ID = 590307
#   - project ID = 35392
#   - excludes cases matching *modules-compile*
#
# Output: staging/raw_testray_caseresults.rds
# =============================================================================

library(dplyr)
library(httr)
library(jsonlite)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- extract_testray started ---")

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
cfg          <- read_yaml("./config/config.yml")
client_id    <- cfg$testray$client_id
client_secret <- cfg$testray$client_secret
base_url     <- cfg$testray$base_url  # https://testray.liferay.com

# Date filter — last 30 days
date_from <- format(Sys.Date() - 30, "%Y-%m-%dT00:00:00Z")
log_info("Extracting case results from {date_from} onward")

# Constants
TARGET_ROUTINE_ID <- 590307
TARGET_PROJECT_ID <- 35392

# -----------------------------------------------------------------------------
# Auth helpers (reused from testray-fetch-builds.R pattern)
# -----------------------------------------------------------------------------
get_token <- function() {
  resp <- POST(
    url  = glue("{base_url}/o/oauth2/token"),
    body = list(
      grant_type    = "client_credentials",
      client_id     = client_id,
      client_secret = client_secret,
      scope         = paste(
        "c_caseresult.everything.read",
        "c_component.everything.read",
        "c_team.everything.read",
        "c_build.everything.read",
        "c_routine.everything.read",
        "c_case.everything.read",
        sep = " "
      )
    ),
    encode = "form"
  )
  stop_for_status(resp)
  content(resp, as = "parsed")$access_token
}

access_token <- get_token()
log_info("OAuth2 token acquired")

# -----------------------------------------------------------------------------
# Generic paginated fetch with token refresh and checkpoint support
# -----------------------------------------------------------------------------
fetch_all_pages <- function(endpoint, query_params = list(), 
                            checkpoint_name = NULL, page_size = 500) {
  
  url          <- glue("{base_url}{endpoint}")
  checkpoint_file <- if (!is.null(checkpoint_name)) {
    glue("staging/checkpoint_{checkpoint_name}.rds")
  } else NULL

  fetch_page <- function(page) {
    params <- c(query_params, list(page = page, pageSize = page_size))
    resp <- GET(url, query = params,
                add_headers(Authorization = paste("Bearer", access_token)))

    if (status_code(resp) == 401) {
      log_info("Token expired, refreshing...")
      access_token <<- get_token()
      resp <- GET(url, query = params,
                  add_headers(Authorization = paste("Bearer", access_token)))
    }
    stop_for_status(resp)
    fromJSON(content(resp, as = "text", encoding = "UTF-8"), flatten = TRUE)
  }

  # Check for checkpoint
  if (!is.null(checkpoint_file) && file.exists(checkpoint_file)) {
    log_info("Checkpoint found for {checkpoint_name}, resuming...")
    checkpoint  <- readRDS(checkpoint_file)
    all_items   <- checkpoint$items
    start_page  <- checkpoint$last_page + 1
    pages       <- checkpoint$total_pages
    log_info("Resuming from page {start_page} of {pages}")
  } else {
    first      <- fetch_page(1)
    total      <- first$totalCount
    pages      <- first$lastPage
    log_info("Fetching {total} records across {pages} pages from {endpoint}")
    all_items  <- list(first$items)
    start_page <- 2
  }

  if (start_page <= pages) {
    for (p in start_page:pages) {
      log_info("  Page {p} of {pages} — {endpoint}")
      
      all_items[[p]] <- tryCatch({
        Sys.sleep(0.2)
        fetch_page(p)$items
      }, error = function(e) {
        log_info("  Failed page {p}: {e$message} — retrying...")
        Sys.sleep(2)
        fetch_page(p)$items
      })
      
      # Checkpoint every 20 pages
      if (!is.null(checkpoint_file) && p %% 20 == 0) {
        saveRDS(list(items = all_items, last_page = p, total_pages = pages),
                checkpoint_file)
        log_info("  Checkpoint saved at page {p}")
      }
    }
  }

  if (!is.null(checkpoint_file) && file.exists(checkpoint_file)) {
    file.remove(checkpoint_file)
  }

  bind_rows(all_items)
}

# -----------------------------------------------------------------------------
# Step 1 — Pre-fetch lookup tables
# -----------------------------------------------------------------------------

# Components
log_info("Fetching components lookup")
raw_components <- fetch_all_pages(
  "/o/c/components",
  query_params = list(
    filter = "r_projectToComponents_c_projectId eq '35392'",
    fields = "id,name"
  )
)
components <- raw_components |>
  select(component_id = id, component_name = name) |>
  distinct()
log_info("Components loaded: {nrow(components)}")

# Teams
log_info("Fetching teams lookup")
raw_teams <- fetch_all_pages(
  "/o/c/teams",
  query_params = list(
    filter = "r_projectToTeams_c_projectId eq '35392'",
    fields = "id,name"
  )
)
teams <- raw_teams |>
  select(team_id = id, team_name = name) |>
  distinct()
log_info("Teams loaded: {nrow(teams)}")

# Routines — filter to target routine only
log_info("Fetching routines lookup")
raw_routines <- fetch_all_pages(
  "/o/c/routines",
  query_params = list(
    filter = "r_routineToProjects_c_projectId eq '35392'",
    fields = "id,name"
  )
)
routines <- raw_routines |>
  select(routine_id = id, routine_name = name) |>
  filter(routine_id == TARGET_ROUTINE_ID) |>
  distinct()
log_info("Target routine found: {nrow(routines) > 0}")

# Builds — keep only those linked to target routine
log_info("Fetching builds lookup (filtering to routine {TARGET_ROUTINE_ID})")
raw_builds <- fetch_all_pages(
  "/o/c/builds",
  query_params = list(
    filter = glue(
      "dateCreated ge {date_from} and ",
      "r_routineToBuilds_c_routineId eq '{TARGET_ROUTINE_ID}'"
    )
  ),
  checkpoint_name = "builds_lookup"
)
builds <- raw_builds |>
  select(
    build_id   = id,
    routine_id = r_routineToBuilds_c_routineId
  ) |>
  filter(routine_id == TARGET_ROUTINE_ID) |>
  distinct()
log_info("Builds linked to target routine: {nrow(builds)}")

# Cases — filter to target project, exclude modules-compile
log_info("Fetching cases lookup (project {TARGET_PROJECT_ID})")
raw_cases <- fetch_all_pages(
  "/o/c/cases",
  query_params = list(
    filter = glue("r_projectToCases_c_projectId eq '{TARGET_PROJECT_ID}'"),
    fields = "id,name,flaky,priority"
  ),
  checkpoint_name = "cases_lookup"
)
cases <- raw_cases |>
  select(
    case_id   = id,
    case_name = name,
    flaky     = flaky,
    priority  = priority
  ) |>
  filter(!grepl("modules-compile", case_name, ignore.case = TRUE)) |>
  distinct()
log_info("Cases after filtering: {nrow(cases)}")

# -----------------------------------------------------------------------------
# Step 2 — Fetch case results per build
# -----------------------------------------------------------------------------
log_info("Fetching case results per build ({nrow(builds)} builds)")

valid_build_ids <- builds$build_id
all_caseresults <- list()

for (i in seq_along(valid_build_ids)) {
  bid <- valid_build_ids[i]
  log_info("  Processing build {i} of {length(valid_build_ids)} (build_id: {bid})")
  
  result <- tryCatch({
    fetch_all_pages(
      "/o/c/caseresults",
      query_params = list(
        filter = paste0("r_buildToCaseResult_c_buildId eq '", bid, "'"),
        fields = "id,dueStatus,dateCreated,r_componentToCaseResult_c_componentId,r_teamToCaseResult_c_teamId,r_buildToCaseResult_c_buildId,r_caseToCaseResult_c_caseId"
      )
    )
  }, error = function(e) {
    log_info("  Failed build {bid}: {e$message} — skipping")
    NULL
  })
  
  if (!is.null(result) && nrow(result) > 0) {
    all_caseresults[[length(all_caseresults) + 1]] <- result
  }
  
  Sys.sleep(0.3)
}

raw_caseresults <- bind_rows(all_caseresults)
log_info("Raw case results fetched: {nrow(raw_caseresults)}")

# -----------------------------------------------------------------------------
# Step 3 — Select and rename fields
# -----------------------------------------------------------------------------
caseresults <- raw_caseresults |>
  select(
    caseresult_id  = id,
    component_id   = r_componentToCaseResult_c_componentId,
    team_id        = r_teamToCaseResult_c_teamId,
    build_id       = r_buildToCaseResult_c_buildId,
    case_id        = r_caseToCaseResult_c_caseId,
    status         = dueStatus.name,
    date_created   = dateCreated
  ) |>
  mutate(date_created = as.Date(substr(date_created, 1, 10)))

log_info("Case results after field selection: {nrow(caseresults)}")

# -----------------------------------------------------------------------------
# Step 4 — Apply joins and filters
# -----------------------------------------------------------------------------

# Filter to builds linked to target routine
caseresults <- caseresults |>
  inner_join(builds |> select(build_id), by = "build_id")
log_info("After routine filter: {nrow(caseresults)}")

# Filter to valid cases (project + exclude modules-compile)
caseresults <- caseresults |>
  inner_join(cases |> select(case_id, case_name, flaky, priority), by = "case_id")
log_info("After case filter: {nrow(caseresults)}")

# Join component names
caseresults <- caseresults |>
  left_join(components, by = "component_id")
log_info("Components joined")

# Join team names
caseresults <- caseresults |>
  left_join(teams, by = "team_id")
log_info("Teams joined")

# -----------------------------------------------------------------------------
# Step 5 — Final shape
# -----------------------------------------------------------------------------
caseresults_final <- caseresults |>
  select(
    caseresult_id,
    case_id,
    case_name,
    flaky,
    priority,
    component_id,
    component_name,
    team_id,
    team_name,
    build_id,
    status,
    date_created
  ) |>
  arrange(desc(date_created))

log_info("Final case results: {nrow(caseresults_final)}")
log_info("Unique components: {n_distinct(caseresults_final$component_name)}")
log_info("Unique teams: {n_distinct(caseresults_final$team_name)}")
log_info("Status breakdown:")
status_summary <- caseresults_final |> count(status, sort = TRUE)
for (i in seq_len(nrow(status_summary))) {
  log_info("  {status_summary$status[i]}: {status_summary$n[i]}")
}

log_info("After exclusions: {nrow(cr)} records remaining")
log_info("Excluded components: {paste(EXCLUDED_COMPONENTS, collapse=', ')}")

# -----------------------------------------------------------------------------
# Step 6 — Save to staging
# -----------------------------------------------------------------------------
if (!dir.exists("staging")) dir.create("staging")
saveRDS(caseresults_final, "staging/raw_testray_caseresults.rds")
log_info("Saved to staging/raw_testray_caseresults.rds")
log_info("--- extract_testray complete ---")