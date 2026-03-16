# =============================================================================
# scan_playwright_tests.R
# Scans the Playwright test directory and builds a module → test mapping
# Output: staging/playwright_test_index.rds
#         staging/playwright_prefix_matches.rds
# =============================================================================

library(dplyr)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- scan_playwright_tests started ---")

cfg             <- read_yaml("config/config.yml")
repo            <- path.expand(cfg$git$repo_path)
playwright_root <- file.path(repo, "modules/test/playwright/tests")

if (!dir.exists(playwright_root)) {
  log_error("Playwright test directory not found: {playwright_root}")
  stop("Playwright test directory not found")
}

# -----------------------------------------------------------------------------
# Find all spec files
# -----------------------------------------------------------------------------
spec_files <- list.files(
  path       = playwright_root,
  pattern    = "\\.spec\\.(ts|js)$",
  recursive  = TRUE,
  full.names = FALSE
)

log_info("Found {length(spec_files)} Playwright spec files")

# Extract module name — first folder segment under tests/
playwright_index <- data.frame(
  spec_path   = spec_files,
  module_name = sapply(strsplit(spec_files, "/"), `[`, 1),
  stringsAsFactors = FALSE
)

log_info("Unique modules with Playwright tests: {n_distinct(playwright_index$module_name)}")

# -----------------------------------------------------------------------------
# Prefix match table
# For cases where one Playwright folder covers many git modules
# e.g. commerce/ covers commerce-account-web, commerce-cart-web, etc.
# -----------------------------------------------------------------------------
prefix_matches <- data.frame(
  playwright_module = c("commerce"),
  git_prefix        = c("commerce-"),
  stringsAsFactors  = FALSE
)

log_info("Prefix match rules defined: {nrow(prefix_matches)}")

# -----------------------------------------------------------------------------
# Save
# -----------------------------------------------------------------------------
if (!dir.exists("staging")) dir.create("staging")

saveRDS(playwright_index,   "staging/playwright_test_index.rds")
saveRDS(prefix_matches,     "staging/playwright_prefix_matches.rds")
write.csv(playwright_index, "staging/playwright_test_index.csv", row.names = FALSE)

log_info("Saved playwright_test_index.rds ({nrow(playwright_index)} specs)")
log_info("Saved playwright_prefix_matches.rds ({nrow(prefix_matches)} rules)")
log_info("--- scan_playwright_tests complete ---")