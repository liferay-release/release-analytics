# =============================================================================
# sync_releases.R
# Reads config/releases.yml and upserts every release block into dim_release.
#
# Safe to re-run at any time:
#   - New releases are inserted
#   - Existing releases are updated if any field changed
#   - No releases are deleted (history is preserved)
#
# Usage:
#   Rscript utils/sync_releases.R
#   — or —
#   source("utils/sync_releases.R") from RStudio
#
# Run this whenever releases.yml is updated.
# =============================================================================

suppressPackageStartupMessages({
  library(yaml)
  library(dplyr)
  library(DBI)
  library(lubridate)
})

source("config/release_analytics_db.R")

RELEASES_YML <- "config/releases.yml"
VALID_STATUSES <- c("IN_DEVELOPMENT", "BRANCH_CUT", "RELEASED")

# =============================================================================
# 1. LOAD AND VALIDATE releases.yml
# =============================================================================
message("\n=== SYNC: releases.yml → dim_release ===")

if (!file.exists(RELEASES_YML)) {
  stop("releases.yml not found at: ", RELEASES_YML,
       "\nExpected location: config/releases.yml")
}

cfg      <- yaml::read_yaml(RELEASES_YML)
releases <- cfg$releases

if (is.null(releases) || length(releases) == 0) {
  stop("No releases found in releases.yml — check the file structure.")
}

message(sprintf("  Found %d release blocks in releases.yml", length(releases)))

# ---------------------------------------------------------------------------
# Parse and validate each block
# ---------------------------------------------------------------------------
parsed <- lapply(seq_along(releases), function(i) {
  r   <- releases[[i]]
  err <- character(0)

  # Required fields
  if (is.null(r$label)         || trimws(r$label) == "")
    err <- c(err, "label is required")
  if (is.null(r$quarter_label) || trimws(r$quarter_label) == "")
    err <- c(err, "quarter_label is required")
  if (is.null(r$git_tag))
    err <- c(err, "git_tag is required (use empty string if tag not yet cut)")
  if (is.null(r$is_major_release))
    err <- c(err, "is_major_release is required (true or false)")
  if (is.null(r$status) || !trimws(toupper(r$status)) %in% VALID_STATUSES)
    err <- c(err, sprintf("status must be one of: %s", paste(VALID_STATUSES, collapse = ", ")))

  # Warn if RELEASED but no release_date
  if (!is.null(r$status) && toupper(r$status) == "RELEASED" &&
      (is.null(r$release_date) || r$release_date == "")) {
    message(sprintf("  WARNING: release '%s' has status RELEASED but no release_date — months_in_field will fall back to 3",
                    r$label))
  }

  if (length(err) > 0) {
    stop(sprintf("Release block #%d ('%s') has validation errors:\n  %s",
                 i, r$label %||% "unknown", paste(err, collapse = "\n  ")))
  }

  data.frame(
    release_label           = trimws(r$label),
    quarter_label           = trimws(r$quarter_label),
    git_tag                 = trimws(as.character(r$git_tag %||% "")),
    release_date            = if (!is.null(r$release_date) && r$release_date != "")
                                as.Date(as.character(r$release_date)) else as.Date(NA),
    is_major_release        = isTRUE(r$is_major_release),
    is_lts                  = isTRUE(r$is_lts),
    release_status          = toupper(trimws(r$status)),
    notes                   = trimws(as.character(r$notes %||% "")),
    stringsAsFactors        = FALSE
  )
})

releases_df <- bind_rows(parsed)

# Check for duplicate labels in the yml itself
dupes <- releases_df$release_label[duplicated(releases_df$release_label)]
if (length(dupes) > 0) {
  stop("Duplicate release labels in releases.yml: ", paste(dupes, collapse = ", "),
       "\nEach release label must be unique.")
}

message(sprintf("  Validation passed for all %d releases", nrow(releases_df)))

# =============================================================================
# 2. CONNECT AND UPSERT
# =============================================================================
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# Temp table for upsert
dbExecute(con, "
  CREATE TEMP TABLE _tmp_releases (
    release_label           VARCHAR(20),
    quarter_label           VARCHAR(20),
    git_tag                 VARCHAR(60),
    release_date            DATE,
    is_major_release        BOOLEAN,
    is_lts                  BOOLEAN,
    release_status          VARCHAR(20),
    notes                   TEXT
  ) ON COMMIT DROP
")

dbWriteTable(con, "_tmp_releases", releases_df, overwrite = TRUE, row.names = FALSE)

rows_affected <- dbExecute(con, "
  INSERT INTO dim_release
    (release_label, quarter_label, git_tag,
     release_date, is_major_release, is_lts,
     release_status, notes)
  SELECT
    release_label, quarter_label, git_tag,
    release_date, is_major_release, is_lts,
    release_status, notes
  FROM _tmp_releases
  ON CONFLICT (release_label)
    DO UPDATE SET
      quarter_label           = EXCLUDED.quarter_label,
      git_tag                 = EXCLUDED.git_tag,
      release_date            = EXCLUDED.release_date,
      is_major_release        = EXCLUDED.is_major_release,
      is_lts                  = EXCLUDED.is_lts,
      release_status          = EXCLUDED.release_status,
      notes                   = EXCLUDED.notes
")

message(sprintf("\n  ✓ Upserted %d rows into dim_release", rows_affected))

# =============================================================================
# 3. SUMMARY — show current state of dim_release
# =============================================================================
current <- dbGetQuery(con, "
  SELECT
    release_label,
    quarter_label,
    release_status,
    is_major_release,
    is_lts,
    release_date,
    CASE
      WHEN release_date IS NOT NULL
        THEN ROUND((CURRENT_DATE - release_date) / 30.0)::INT
      ELSE NULL
    END AS months_in_field,
    git_tag
  FROM dim_release
  ORDER BY
    COALESCE(release_date, '9999-12-31'),
    release_label
")

message("\n  Current dim_release state:")
print(current)

# Highlight anything that may need attention
needs_attention <- current %>%
  filter(
    (release_status == "RELEASED" & is.na(release_date)) |
    (release_status == "RELEASED"   & (is.na(git_tag) | git_tag == "")) |
    (release_status == "BRANCH_CUT" & (is.na(git_tag) | git_tag == ""))
  )

if (nrow(needs_attention) > 0) {
  message("\n  ⚠️  Releases needing attention:")
  print(needs_attention %>% select(release_label, release_status, release_date, git_tag))
}

message("\n✅ sync_releases.R complete")
message("   If any hashes changed, re-run extract_git.R to refresh churn snapshots.")

# =============================================================================
# Helpers
# =============================================================================
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b
