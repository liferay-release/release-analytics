# =============================================================================
# extract_stories.R
# Pulls Jira Stories (issue type = Story) by component, used as a workload
# signal in the bug forecasting model.
#
# Output: staging/raw_stories.rds
#
# Mirrors the structure of extract_jira.R — reuses the same Jira connection
# config from config.yml. Add your Jira base URL and auth there.
#
# Fields extracted per story:
#   issue_key, project, components, created_date, status, resolution,
#   resolution_date, story_points (if available), fix_version
# =============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(yaml)
  library(lubridate)
})

source("config/release_analytics_db.R")   # for config loading pattern
options(scipen = 999)
STAGING <- "staging"

# =============================================================================
# 1. LOAD CONFIG
# =============================================================================
cfg     <- yaml::read_yaml("config/config.yml")
jira    <- cfg$jira

base_url  <- jira$base_url          # e.g. "https://liferay.atlassian.net"
auth_user <- jira$username
auth_token <- jira$api_token

# Project keys to query — Stories live in LPP project (same as bugs)
# Adjust if Stories are tracked separately
story_projects <- jira$story_projects %||% c("LPP", "LPD")

# Date window: pull stories from this far back
# Matches the training window used in the forecasting model
lookback_months <- jira$lookback_months %||% 30   # ~2.5 years = 2024Q1 onwards
since_date <- format(Sys.Date() - months(lookback_months), "%Y-%m-%d")

`%||%` <- function(a, b) if (!is.null(a)) a else b

# =============================================================================
# 2. JIRA FETCH HELPER (mirrors extract_jira.R pattern)
# =============================================================================
fetch_jira_stories <- function(project_key) {
  message(sprintf("\n  Fetching Stories for project: %s (since %s)", project_key, since_date))

  jql <- sprintf(
    'project = "%s" AND issuetype = Story AND created >= "%s" ORDER BY created ASC',
    project_key, since_date
  )

  fields <- paste(c(
    "summary", "status", "resolution", "created", "resolutiondate",
    "components", "fixVersions", "story_points", "priority",
    "customfield_10016"   # story points field (common Jira config)
  ), collapse = ",")

  all_issues <- list()
  start_at   <- 0
  page_size  <- 100

  repeat {
    resp <- GET(
      url   = paste0(base_url, "/rest/api/3/search"),
      query = list(
        jql        = jql,
        startAt    = start_at,
        maxResults = page_size,
        fields     = fields
      ),
      authenticate(auth_user, auth_token, type = "basic"),
      add_headers("Content-Type" = "application/json")
    )

    if (http_error(resp)) {
      msg <- content(resp, as = "text", encoding = "UTF-8")
      stop(sprintf("Jira API error (project %s, startAt %d): %s", project_key, start_at, msg))
    }

    body  <- content(resp, as = "parsed", type = "application/json")
    batch <- body$issues

    if (length(batch) == 0) break

    parsed <- lapply(batch, function(issue) {
      f <- issue$fields

      # components: list of {name: ...}
      components <- if (length(f$components) > 0) {
        paste(sapply(f$components, `[[`, "name"), collapse = "|")
      } else { NA_character_ }

      # fix versions: list of {name: ...}
      fix_versions <- if (length(f$fixVersions) > 0) {
        paste(sapply(f$fixVersions, `[[`, "name"), collapse = "|")
      } else { NA_character_ }

      data.frame(
        issue_key       = issue$key,
        project         = project_key,
        summary         = f$summary %||% NA_character_,
        status          = f$status$name %||% NA_character_,
        resolution      = f$resolution$name %||% NA_character_,
        created_date    = as.Date(substr(f$created %||% NA_character_, 1, 10)),
        resolution_date = as.Date(substr(f$resolutiondate %||% NA_character_, 1, 10)),
        components      = components,
        fix_versions    = fix_versions,
        story_points    = f$customfield_10016 %||% NA_real_,
        stringsAsFactors = FALSE
      )
    })

    all_issues <- c(all_issues, parsed)
    start_at   <- start_at + length(batch)
    total      <- body$total

    message(sprintf("    Fetched %d / %d", start_at, total))
    if (start_at >= total) break
    Sys.sleep(0.2)   # polite rate limiting
  }

  if (length(all_issues) == 0) {
    message(sprintf("  No stories found for project %s", project_key))
    return(NULL)
  }

  bind_rows(all_issues)
}

# =============================================================================
# 3. FETCH ALL PROJECTS
# =============================================================================
story_list <- lapply(story_projects, function(proj) {
  tryCatch(fetch_jira_stories(proj), error = function(e) {
    message(sprintf("  ERROR fetching %s: %s", proj, e$message))
    NULL
  })
})

raw_stories <- bind_rows(Filter(Negate(is.null), story_list))

if (nrow(raw_stories) == 0) {
  stop("No stories retrieved. Check Jira config (base_url, credentials, project keys).")
}

message(sprintf("\n  Total stories fetched: %d", nrow(raw_stories)))
message(sprintf("  Projects: %s", paste(sort(unique(raw_stories$project)), collapse = ", ")))
message(sprintf("  Date range: %s to %s",
                min(raw_stories$created_date, na.rm = TRUE),
                max(raw_stories$created_date, na.rm = TRUE)))

# =============================================================================
# 4. QUICK VALIDATION
# =============================================================================
no_component <- sum(is.na(raw_stories$components))
message(sprintf("  Stories with no component: %d (%.1f%%)",
                no_component, 100 * no_component / nrow(raw_stories)))

# Quarter preview
raw_stories <- raw_stories %>%
  mutate(quarter = paste0(
    lubridate::year(created_date), "Q", lubridate::quarter(created_date)
  ))

story_summary <- raw_stories %>%
  filter(!is.na(components)) %>%
  count(quarter, name = "n_stories") %>%
  arrange(quarter)

message("\n  Stories by quarter:")
print(story_summary)

# =============================================================================
# 5. SAVE
# =============================================================================
out_path <- file.path(STAGING, "raw_stories.rds")
saveRDS(raw_stories, out_path)
message(sprintf("\n  ✓ Saved %d rows to %s", nrow(raw_stories), out_path))
message("  Next: run transform_forecast_input.R")
