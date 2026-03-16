# =============================================================================
# build_module_index.R
# Extracts module names from git log file paths and builds a module index
#
# Handles path patterns:
#   1. Root level:          portal-impl/src/...        → portal-impl
#   2. Root level:          portal-web/docroot/...     → portal-web
#   3. modules/apps/:       modules/apps/.../module/src/... → module
#   4. modules/dxp/apps/:   modules/dxp/apps/.../module/src/... → module
#   5. modules/util/:       modules/util/.../module/src/... → module
#
# Key fix: extract the folder immediately before /src/ regardless of
# nesting depth — handles multi-level parent structures like:
#   modules/apps/headless/headless-admin-site/headless-admin-site-impl/src/
#   → headless-admin-site-impl (not headless-admin-site)
#
# Output: staging/git_file_module_map.rds
#         staging/git_module_index.rds
# =============================================================================

library(dplyr)
library(stringr)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- build_module_index started ---")

# -----------------------------------------------------------------------------
# Load git log from staging
# -----------------------------------------------------------------------------
if (!file.exists("staging/raw_git_log.rds")) {
  log_error("staging/raw_git_log.rds not found — run extract_git.R first")
  stop("raw_git_log.rds not found")
}

git_log <- readRDS("staging/raw_git_log.rds")
log_info("Loaded git log: {nrow(git_log)} records")

# -----------------------------------------------------------------------------
# Extract module name from file path
# Core rule: grab the folder segment immediately before /src/
# This handles any nesting depth under modules/apps/, modules/dxp/apps/, etc.
# -----------------------------------------------------------------------------
git_modules <- git_log |>
  distinct(file_path) |>
  mutate(
    module_name = case_when(

      # Root level — portal-impl, portal-web, portal-kernel etc.
      grepl("^portal-[a-z]+/", file_path) ~
        str_extract(file_path, "^[^/]+"),

      # modules/* — grab segment immediately before /src/
      grepl("^modules/", file_path) & grepl("/src/", file_path) ~
        str_extract(file_path, "[^/]+(?=/src/)"),

      # modules/* without /src/ — take 4th segment (best guess)
      grepl("^modules/", file_path) ~
        str_extract(file_path, "(?:^(?:[^/]*/){3})([^/]+)") |>
        str_extract("[^/]+$"),

      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(module_name)) |>
  select(file_path, module_name)

log_info("Files with resolved module names: {nrow(git_modules)}")
log_info("Unique modules: {n_distinct(git_modules$module_name)}")

# Sanity check — show sample of resolved modules
sample_check <- git_modules |>
  filter(grepl("headless", file_path)) |>
  select(file_path, module_name) |>
  head(5)

if (nrow(sample_check) > 0) {
  log_info("Sample headless module resolution:")
  for (i in seq_len(nrow(sample_check))) {
    log_info("  {sample_check$file_path[i]} → {sample_check$module_name[i]}")
  }
}

# -----------------------------------------------------------------------------
# Join back to full git log (preserving commit records)
# -----------------------------------------------------------------------------
git_modules_full <- git_log |>
  left_join(git_modules, by = "file_path")

# -----------------------------------------------------------------------------
# Build distinct module index with file counts
# -----------------------------------------------------------------------------
module_index <- git_modules |>
  left_join(
    git_log |> group_by(file_path) |> summarise(commit_count = n(), .groups = "drop"),
    by = "file_path"
  ) |>
  group_by(module_name) |>
  summarise(
    file_count   = n_distinct(file_path),
    commit_count = sum(commit_count),
    .groups      = "drop"
  ) |>
  arrange(desc(commit_count))

log_info("Module index built: {nrow(module_index)} modules")

# -----------------------------------------------------------------------------
# Cross-check against Playwright index
# -----------------------------------------------------------------------------
if (file.exists("staging/playwright_test_index.rds")) {
  playwright_index <- readRDS("staging/playwright_test_index.rds")
  prefix_matches   <- readRDS("staging/playwright_prefix_matches.rds")

  exact_matched <- inner_join(
    module_index |> select(module_name),
    playwright_index |> distinct(module_name),
    by = "module_name"
  )

  prefix_matched <- module_index |>
    cross_join(prefix_matches) |>
    filter(str_starts(module_name, git_prefix)) |>
    select(module_name, playwright_module)

  log_info("Exact Playwright matches: {nrow(exact_matched)} modules")
  log_info("Prefix Playwright matches: {nrow(prefix_matched)} git modules")
  log_info("Total git modules with Playwright coverage: {n_distinct(c(exact_matched$module_name, prefix_matched$module_name))}")
}

# -----------------------------------------------------------------------------
# Save
# -----------------------------------------------------------------------------
if (!dir.exists("staging")) dir.create("staging")
saveRDS(git_modules,  "staging/git_file_module_map.rds")
saveRDS(module_index, "staging/git_module_index.rds")

log_info("Saved git_file_module_map.rds")
log_info("Saved git_module_index.rds")

# -----------------------------------------------------------------------------
# Top 20 most active modules
# -----------------------------------------------------------------------------
log_info("Top 20 most active modules by commit count:")
top20 <- head(module_index, 20)
for (i in seq_len(nrow(top20))) {
  log_info("  {top20$commit_count[i]} commits, {top20$file_count[i]} files — {top20$module_name[i]}")
}

log_info("--- build_module_index complete ---")