# =============================================================================
# extract_jira.R
# Extracts LPP (customer) and LPD (internal) bugs from Jira
#
# LPP: Customer Issues — priority field: priority.name (Fire/Critical/High/Medium/Low)
# LPD: Internal Bugs  — priority field: customfield_10211.value (5/4/3/2/1)
#
# Output: staging/raw_jira_issues.rds
# =============================================================================

library(dplyr)
library(httr)
library(jsonlite)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- extract_jira started ---")

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
cfg               <- read_yaml("config/config.yml")
email             <- cfg$jira$email
token             <- cfg$jira$api_token
base_url          <- cfg$jira$base_url
fix_priority_field <- cfg$jira$fix_priority_field
jql_lpp           <- cfg$jira$queries$lpp
jql_lpd           <- cfg$jira$queries$lpd
jql_lpd_blockers  <- cfg$jira$queries$lpd_blockers
jql_lpd_stories   <- cfg$jira$queries$lpd_stories

# Fields to fetch from Jira
FIELDS <- paste(
  "summary",
  "issuetype",
  "project",
  "priority",
  "status",
  "resolution",
  "components",
  "created",
  "resolutiondate",
  "versions",             # affectedVersion — standard Jira field
  fix_priority_field,
  sep = ","
)

# Fields to fetch for Stories (lighter — no severity, no fix version needed)
FIELDS_STORIES <- paste(
  "summary",
  "issuetype",
  "project",
  "status",
  "components",
  "created",
  "fixVersions",
  sep = ","
)

# -----------------------------------------------------------------------------
# Priority normalization maps
# Normalize both LPP and LPD to a common 1-5 severity scale
# -----------------------------------------------------------------------------
lpp_priority_map <- c(
  "Fire"     = 5,
  "Critical" = 4,
  "High"     = 3,
  "Medium"   = 2,
  "Low"      = 1
)

# LPD fix priority is already 1-5, just coerce to numeric

# -----------------------------------------------------------------------------
# Paginated Jira fetch using /rest/api/3/search/jql
# -----------------------------------------------------------------------------
fetch_jira_issues <- function(jql, fields, label) {
  all_issues  <- list()
  start_token <- NULL
  page        <- 1
  
  log_info("Fetching {label} issues")
  
  repeat {
    query <- list(
      jql        = jql,
      fields     = fields,
      maxResults = 100
    )
    if (!is.null(start_token)) {
      query$nextPageToken <- start_token
    }
    
    resp <- GET(
      url   = glue("{base_url}/rest/api/3/search/jql"),
      query = query,
      authenticate(email, token, type = "basic")
    )
    
    if (status_code(resp) != 200) {
      log_error("{label} fetch failed on page {page}: HTTP {status_code(resp)}")
      stop(glue("{label} fetch failed: HTTP {status_code(resp)}"))
    }
    
    parsed <- fromJSON(
      content(resp, as = "text", encoding = "UTF-8"),
      flatten = TRUE
    )
    
    issues <- parsed$issues
    if (is.null(issues) || nrow(issues) == 0) break
    
    all_issues[[page]] <- issues
    log_info("  {label} page {page} — {nrow(issues)} issues fetched")
    
    if (isTRUE(parsed$isLast) || is.null(parsed$nextPageToken)) break
    
    start_token <- parsed$nextPageToken
    page        <- page + 1
    Sys.sleep(0.3)
  }
  
  bind_rows(all_issues)
}

# -----------------------------------------------------------------------------
# Step 1 — Fetch LPP issues (customer-reported)
# -----------------------------------------------------------------------------
raw_lpp <- fetch_jira_issues(jql_lpp, FIELDS, "LPP")
log_info("LPP raw issues fetched: {nrow(raw_lpp)}")

# -----------------------------------------------------------------------------
# Step 2 — Fetch LPD issues (internal bugs)
# -----------------------------------------------------------------------------
raw_lpd <- fetch_jira_issues(jql_lpd, FIELDS, "LPD")
log_info("LPD raw issues fetched: {nrow(raw_lpd)}")

# -----------------------------------------------------------------------------
# Step 2b — Fetch LPD release blocker issue keys
# Only fetches issue_key — used to flag existing LPD rows, not add new ones
# -----------------------------------------------------------------------------
blocker_keys <- character(0)
if (!is.null(jql_lpd_blockers) && jql_lpd_blockers != "") {
  raw_blockers <- tryCatch(
    fetch_jira_issues(jql_lpd_blockers, "summary,created", "LPD Blockers"),
    error = function(e) {
      log_error("Blocker fetch failed: {e$message}")
      NULL
    }
  )
  if (!is.null(raw_blockers) && nrow(raw_blockers) > 0) {
    blocker_keys <- raw_blockers$key
    log_info("Release blocker keys fetched: {length(blocker_keys)}")
  }
} else {
  log_info("No lpd_blockers query configured — skipping")
}

# -----------------------------------------------------------------------------
# Step 2c — Fetch LPD Stories
# Fetched separately — different field structure, saved to raw_jira_stories.rds
# -----------------------------------------------------------------------------
raw_stories <- NULL
if (!is.null(jql_lpd_stories) && jql_lpd_stories != "") {
  raw_stories <- tryCatch(
    fetch_jira_issues(jql_lpd_stories, FIELDS_STORIES, "LPD Stories"),
    error = function(e) {
      log_error("Stories fetch failed: {e$message}")
      NULL
    }
  )
  if (!is.null(raw_stories)) {
    log_info("LPD Stories raw issues fetched: {nrow(raw_stories)}")
  }
} else {
  log_info("No lpd_stories query configured — skipping")
}

# -----------------------------------------------------------------------------
# affectedVersion parsing helpers
# -----------------------------------------------------------------------------

# Extract affected version names from fields.versions (list of {name: ...})
parse_affected_versions <- function(versions_col) {
  sapply(versions_col, function(v) {
    if (is.data.frame(v) && "name" %in% names(v) && nrow(v) > 0)
      paste(v$name, collapse = "|")
    else NA_character_
  })
}

# For LPP: take the most recent 202x.Qy version, strip patch suffix
# e.g. "2025.Q1.15|2025.Q2.3" -> "2025.Q2"
extract_lpp_quarter <- function(affected_versions_str) {
  sapply(affected_versions_str, function(s) {
    if (is.na(s) || s == "") return(NA_character_)
    # Split on pipe, keep only 202x.Qy(.z) pattern
    parts <- unlist(strsplit(s, "\\|"))
    parts <- trimws(parts)
    # Match 202x.Qy pattern (with optional .patch)
    valid <- grep("^20\\d{2}\\.Q[1-4]", parts, value = TRUE)
    if (length(valid) == 0) return(NA_character_)
    # Strip patch suffix: "2025.Q1.15" -> "2025.Q1"
    cleaned <- sub("^(20\\d{2}\\.Q[1-4]).*$", "\\1", valid)
    # Return the most recent (last alphabetically sorts correctly for 202x.Qy)
    tail(sort(cleaned), 1)
  }, USE.NAMES = FALSE)
}

# For Stories: try fixVersions first (202x.Qy pattern), fall back to created_date
# dev window lookup happens in transform_forecast_input.R since it needs dim_release
extract_story_quarter <- function(fix_versions_col, created_dates) {
  mapply(function(fv, cd) {
    # Try fixVersions first
    if (is.data.frame(fv) && "name" %in% names(fv) && nrow(fv) > 0) {
      parts   <- trimws(fv$name)
      valid   <- grep("^20\\d{2}\\.Q[1-4]", parts, value = TRUE)
      cleaned <- sub("^(20\\d{2}\\.Q[1-4]).*$", "\\1", valid)
      if (length(cleaned) > 0) return(list(quarter = tail(sort(cleaned), 1), source = "fixVersion"))
    }
    # Fall back to created_date — quarter resolved in transform step
    return(list(quarter = NA_character_, source = "created_date"))
  }, fix_versions_col, created_dates, SIMPLIFY = FALSE)
}

# Step 3 — Parse and normalize LPP
# -----------------------------------------------------------------------------
parse_lpp <- function(raw) {
  raw |>
    mutate(
      issue_key         = key,
      project           = "LPP",
      source            = "customer",
      summary           = fields.summary,
      status            = fields.status.name,
      resolution        = if ("fields.resolution.name" %in% names(raw))
        fields.resolution.name else NA_character_,
      created_date      = as.Date(substr(fields.created, 1, 10)),
      resolution_date   = if ("fields.resolutiondate" %in% names(raw))
        as.Date(substr(fields.resolutiondate, 1, 10)) else NA,
      priority_raw      = fields.priority.name,
      severity_score    = lpp_priority_map[fields.priority.name],
      fix_priority      = NA_real_,
      components        = sapply(fields.components, function(c) {
        if (is.data.frame(c) && "name" %in% names(c))
          paste(c$name, collapse = "|")
        else NA_character_
      }),
      affected_versions = if ("fields.versions" %in% names(raw))
        parse_affected_versions(raw$fields.versions)
      else NA_character_,
      quarter_lpp       = extract_lpp_quarter(affected_versions)
    ) |>
    mutate(is_release_blocker = FALSE) |>
    dplyr::select(issue_key, project, source, summary, status, resolution,
                  created_date, resolution_date, priority_raw,
                  severity_score, fix_priority, components,
                  affected_versions, quarter_lpp, is_release_blocker)
}

# -----------------------------------------------------------------------------
# Step 4 — Parse and normalize LPD
# -----------------------------------------------------------------------------
fix_priority_col <- glue("fields.{fix_priority_field}.value")

parse_lpd <- function(raw) {
  raw |>
    mutate(
      issue_key         = key,
      project           = "LPD",
      source            = "internal",
      summary           = fields.summary,
      status            = fields.status.name,
      resolution        = if ("fields.resolution.name" %in% names(raw))
        fields.resolution.name else NA_character_,
      created_date      = as.Date(substr(fields.created, 1, 10)),
      resolution_date   = if ("fields.resolutiondate" %in% names(raw))
        as.Date(substr(fields.resolutiondate, 1, 10)) else NA,
      priority_raw      = if (fix_priority_col %in% names(raw))
        as.character(raw[[fix_priority_col]]) else NA_character_,
      severity_score    = as.numeric(priority_raw),
      fix_priority      = as.numeric(priority_raw),
      components        = sapply(fields.components, function(c) {
        if (is.data.frame(c) && "name" %in% names(c))
          paste(c$name, collapse = "|")
        else NA_character_
      }),
      affected_versions = if ("fields.versions" %in% names(raw))
        parse_affected_versions(raw$fields.versions)
      else NA_character_,
      quarter_lpp       = NA_character_   # LPD quarter assigned from created_date window
    ) |>
    dplyr::select(issue_key, project, source, summary, status, resolution,
                  created_date, resolution_date, priority_raw,
                  severity_score, fix_priority, components,
                  affected_versions, quarter_lpp)
}

# -----------------------------------------------------------------------------
# Step 4c — Parse Stories
# -----------------------------------------------------------------------------
parse_stories <- function(raw) {
  if (is.null(raw) || nrow(raw) == 0) return(NULL)
  
  quarter_results <- extract_story_quarter(
    if ("fields.fixVersions" %in% names(raw)) raw$fields.fixVersions else vector("list", nrow(raw)),
    as.Date(substr(raw$fields.created, 1, 10))
  )
  
  raw |>
    mutate(
      issue_key        = key,
      project          = fields.project.key,
      summary          = fields.summary,
      status           = fields.status.name,
      created_date     = as.Date(substr(fields.created, 1, 10)),
      components       = sapply(fields.components, function(c) {
        if (is.data.frame(c) && "name" %in% names(c))
          paste(c$name, collapse = "|")
        else NA_character_
      }),
      quarter          = sapply(quarter_results, function(x) x$quarter),
      quarter_source   = sapply(quarter_results, function(x) x$source)
    ) |>
    dplyr::select(issue_key, project, summary, status,
                  created_date, components, quarter, quarter_source)
}

lpp <- parse_lpp(raw_lpp)
lpd <- parse_lpd(raw_lpd)

log_info("LPP parsed: {nrow(lpp)} issues")
log_info("LPD parsed: {nrow(lpd)} issues")

# -----------------------------------------------------------------------------
# Step 5 — Combine + flag release blockers
# -----------------------------------------------------------------------------
issues <- bind_rows(lpp, lpd) |>
  mutate(
    is_release_blocker = coalesce(is_release_blocker, FALSE) | (issue_key %in% blocker_keys)
  )

log_info("Total issues combined: {nrow(issues)}")
log_info("Date range: {min(issues$created_date)} to {max(issues$created_date)}")

# Status breakdown
log_info("Status breakdown:")
status_summary <- issues |> count(project, status, sort = TRUE)
for (i in seq_len(nrow(status_summary))) {
  log_info("  {status_summary$project[i]} | {status_summary$status[i]}: {status_summary$n[i]}")
}

# Severity breakdown
log_info("Severity breakdown:")
sev_summary <- issues |> count(project, priority_raw, sort = TRUE)
for (i in seq_len(nrow(sev_summary))) {
  log_info("  {sev_summary$project[i]} | {sev_summary$priority_raw[i]}: {sev_summary$n[i]}")
}

# Component coverage
log_info("Issues with components assigned: {sum(!is.na(issues$components))}")
log_info("Issues missing components: {sum(is.na(issues$components))}")
log_info("Release blockers flagged: {sum(issues$is_release_blocker)}")

# -----------------------------------------------------------------------------
# Step 6 — Save
# -----------------------------------------------------------------------------
if (!dir.exists("staging")) dir.create("staging")
saveRDS(issues, "staging/raw_jira_issues.rds")
log_info("Saved to staging/raw_jira_issues.rds")

# -----------------------------------------------------------------------------
# Step 6b — Parse and save Stories
# -----------------------------------------------------------------------------
if (!is.null(raw_stories) && nrow(raw_stories) > 0) {
  stories <- parse_stories(raw_stories)
  log_info("Stories parsed: {nrow(stories)} issues")
  log_info("  With fixVersion quarter: {sum(stories$quarter_source == 'fixVersion', na.rm=TRUE)}")
  log_info("  Falling back to created_date: {sum(stories$quarter_source == 'created_date', na.rm=TRUE)}")
  log_info("  Missing components: {sum(is.na(stories$components))}")
  
  # Component breakdown
  comp_counts <- stories |>
    filter(!is.na(components)) |>
    count(components, sort = TRUE)
  log_info("  Top 5 components by story count:")
  for (i in seq_len(min(5, nrow(comp_counts)))) {
    log_info("    {comp_counts$components[i]}: {comp_counts$n[i]}")
  }
  
  saveRDS(stories, "staging/raw_jira_stories.rds")
  log_info("Saved to staging/raw_jira_stories.rds")
} else {
  log_info("No stories fetched — staging/raw_jira_stories.rds not written")
}

log_info("--- extract_jira complete ---")