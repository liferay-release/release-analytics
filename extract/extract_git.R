# =============================================================================
# extract_git.R
# Extracts git log history from the Liferay portal repo
# Output: staging/raw_git_log.rds
# =============================================================================

library(dplyr)
library(logger)
library(yaml)
library(glue)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- extract_git started ---")

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
cfg     <- read_yaml("config/config.yml")
repo    <- path.expand(cfg$git$repo_path)
windows <- cfg$scoring$windows  # c(30, 90, 365)

if (!dir.exists(repo)) {
  log_error("Repo path not found: {repo}")
  stop("Repo path not found: ", repo)
}

log_info("Repo path: {repo}")
log_info("Extracting last {max(windows)} days of git history")

# -----------------------------------------------------------------------------
# Pull raw git log
# Format: COMMIT|<hash>|<author_email>|<date> then file paths follow
# -----------------------------------------------------------------------------
cmd <- glue(
  'git -C "{repo}" log ',
  '--since="{max(windows)} days ago" ',
  '--name-only ',
  '--pretty=format:"COMMIT|%H|%ae|%ad" ',
  '--date=short'
)

log_info("Running git log command")
raw <- system(cmd, intern = TRUE)

if (length(raw) == 0) {
  log_error("git log returned no output — check repo path and branch")
  stop("git log returned no output")
}

log_info("Raw git log lines returned: {length(raw)}")

# -----------------------------------------------------------------------------
# Parse raw output into a tidy data frame
# -----------------------------------------------------------------------------
parse_git_log <- function(raw_lines) {
  commits <- list()
  current_commit <- NULL
  current_email  <- NULL
  current_date   <- NULL

  for (line in raw_lines) {
    line <- trimws(line)
    if (nchar(line) == 0) next

    if (startsWith(line, "COMMIT|")) {
      parts          <- strsplit(line, "\\|")[[1]]
      current_commit <- parts[2]
      current_email  <- parts[3]
      current_date   <- parts[4]
    } else {
      # It's a file path
      if (!is.null(current_commit)) {
        commits[[length(commits) + 1]] <- data.frame(
          commit_hash  = current_commit,
          author_email = current_email,
          commit_date  = as.Date(current_date),
          file_path    = line,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  bind_rows(commits)
}

log_info("Parsing git log output")
git_log <- parse_git_log(raw)

if (nrow(git_log) == 0) {
  log_error("Parsed git log is empty — check git log format")
  stop("Parsed git log is empty")
}

log_info("Parsed {nrow(git_log)} file-commit records")

# Filter to Java files only and enforce date window
git_log <- git_log |>
  filter(grepl("\\.(java|js|ts|tsx|jsx)$", file_path, ignore.case = TRUE)) |>
  filter(commit_date >= Sys.Date() - max(windows))

log_info("Unique files touched: {n_distinct(git_log$file_path)}")
log_info("Unique authors: {n_distinct(git_log$author_email)}")
log_info("Date range: {min(git_log$commit_date)} to {max(git_log$commit_date)}")

# -----------------------------------------------------------------------------
# Save to staging
# -----------------------------------------------------------------------------
if (!dir.exists("staging")) dir.create("staging")

saveRDS(git_log, "staging/raw_git_log.rds")
log_info("Saved to staging/raw_git_log.rds")
log_info("--- extract_git complete ---")

# -----------------------------------------------------------------------------
# Quick sanity check — top 10 most changed files
# -----------------------------------------------------------------------------
top_files <- git_log |>
  count(file_path, sort = TRUE) |>
  head(10)

log_info("Top 10 most changed files:")
for (i in seq_len(nrow(top_files))) {
  log_info("  {top_files$n[i]} commits — {top_files$file_path[i]}")
}

readLines("logs/pipeline.log") |> tail(20)
