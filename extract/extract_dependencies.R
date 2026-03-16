# =============================================================================
# extract_dependencies.R
# Parses build.gradle and bnd.bnd files across liferay-portal/modules to build
# a module-level dependency graph for blast radius analysis.
#
# Usage:
#   Rscript extract/extract_dependencies.R
#   Rscript extract/extract_dependencies.R --force   # force full rescan
#
# Input:  ~/dev/projects/liferay-portal/modules (build.gradle, bnd.bnd)
# Output: staging/raw_dependencies.rds        — compileOnly edges (blast radius)
#         staging/raw_test_dependencies.rds   — testImplementation edges (test recommendations)
#         staging/raw_module_registry.rds     — module metadata + graph stats
#
# Notes:
#   - compileOnly project(...) edges used for blast radius only
#   - testImplementation project(...) edges used for test recommendations only
#   - External group: dependencies ignored (not intra-portal)
#   - Bundle-SymbolicName from bnd.bnd is the canonical module identity
#   - Rescan recommended when build.gradle or bnd.bnd files appear in a PR diff
# =============================================================================

library(dplyr)
library(tidyr)
library(purrr)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- extract_dependencies started ---")

cfg          <- read_yaml("config/config.yml")
portal_dir   <- cfg$git$repo_path  # e.g. ~/dev/projects/liferay-portal
modules_root <- file.path(path.expand(portal_dir), "modules")

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
args  <- commandArgs(trailingOnly = TRUE)
force <- "--force" %in% args

# -----------------------------------------------------------------------------
# Check if rescan is needed
# -----------------------------------------------------------------------------
registry_path     <- "staging/raw_module_registry.rds"
dependencies_path <- "staging/raw_dependencies.rds"
test_deps_path    <- "staging/raw_test_dependencies.rds"

if (!force && file.exists(registry_path) && file.exists(dependencies_path) && file.exists(test_deps_path)) {
  log_info("Staging files exist. Use --force to rescan. Exiting.")
  quit(status = 0)
}

# -----------------------------------------------------------------------------
# Step 1 — Find all modules (directories containing bnd.bnd)
# -----------------------------------------------------------------------------
log_info("Scanning modules root: {modules_root}")

bnd_files <- list.files(
  path       = modules_root,
  pattern    = "^bnd\\.bnd$",
  recursive  = TRUE,
  full.names = TRUE
)

log_info("Found {length(bnd_files)} bnd.bnd files")

# -----------------------------------------------------------------------------
# Step 2 — Parse bnd.bnd for Bundle-SymbolicName and Bundle-Version
# -----------------------------------------------------------------------------
parse_bnd <- function(bnd_path) {
  lines <- tryCatch(readLines(bnd_path, warn = FALSE), error = function(e) character(0))

  get_field <- function(field) {
    match <- grep(paste0("^", field, ":"), lines, value = TRUE)
    if (length(match) == 0) return(NA_character_)
    trimws(sub(paste0("^", field, ":\\s*"), "", match[1]))
  }

  module_dir <- dirname(bnd_path)
  # Derive short module name from directory path
  # e.g. .../modules/apps/document-library/document-library-service
  #   -> apps/document-library/document-library-service
  rel_path <- sub(paste0("^", modules_root, "/?"), "", module_dir)

  data.frame(
    module_path          = rel_path,
    module_dir           = module_dir,
    bundle_symbolic_name = get_field("Bundle-SymbolicName"),
    bundle_version       = get_field("Bundle-Version"),
    bundle_name          = get_field("Bundle-Name"),
    stringsAsFactors     = FALSE
  )
}

log_info("Parsing bnd.bnd files...")
module_registry <- map_dfr(bnd_files, parse_bnd)

# Derive short module name from last path component
module_registry <- module_registry |>
  mutate(
    module_name = basename(module_path),
    module_path = module_path
  ) |>
  filter(!is.na(bundle_symbolic_name)) |>
  distinct(bundle_symbolic_name, .keep_all = TRUE)

log_info("Module registry built: {nrow(module_registry)} modules")

# -----------------------------------------------------------------------------
# Step 3 — Parse build.gradle for compileOnly project(...) dependencies
# -----------------------------------------------------------------------------

# Convert gradle project path to module_path
# e.g. ":apps:document-library:document-library-api"
#   -> "apps/document-library/document-library-api"
gradle_path_to_module <- function(gradle_path) {
  trimws(gsub(":", "/", gradle_path), whitespace = "/")
}

parse_gradle <- function(module_dir, dep_type = "compileOnly") {
  gradle_path <- file.path(module_dir, "build.gradle")
  if (!file.exists(gradle_path)) return(NULL)

  lines <- tryCatch(readLines(gradle_path, warn = FALSE), error = function(e) character(0))
  if (length(lines) == 0) return(NULL)

  pattern   <- paste0(dep_type, '\\s+project\\s*\\(\\s*":[^"]*"')
  dep_lines <- grep(pattern, lines, value = TRUE)
  if (length(dep_lines) == 0) return(NULL)

  dep_paths <- regmatches(dep_lines, regexpr('":[^"]+"', dep_lines))
  dep_paths <- gsub('"', '', dep_paths)

  data.frame(
    module_dir      = module_dir,
    dependency_path = gradle_path_to_module(dep_paths),
    dep_type        = dep_type,
    stringsAsFactors = FALSE
  )
}

log_info("Parsing build.gradle files (compileOnly + testImplementation)...")

raw_compile <- map_dfr(module_registry$module_dir, parse_gradle, dep_type = "compileOnly")
raw_test    <- map_dfr(module_registry$module_dir, parse_gradle, dep_type = "testImplementation")

log_info("compileOnly edges found:        {nrow(raw_compile)}")
log_info("testImplementation edges found: {nrow(raw_test)}")

# -----------------------------------------------------------------------------
# Step 4 — Resolve module names from paths
# -----------------------------------------------------------------------------

# Build a lookup: module_path -> module_name + bundle_symbolic_name
path_lookup <- module_registry |>
  select(module_path, module_name, bundle_symbolic_name)

resolve_edges <- function(raw) {
  raw |>
    left_join(
      module_registry |> select(module_dir, module_name, bundle_symbolic_name) |>
        rename(from_module = module_name, from_bsn = bundle_symbolic_name),
      by = "module_dir"
    ) |>
    left_join(
      path_lookup |>
        rename(dependency_path = module_path, to_module = module_name, to_bsn = bundle_symbolic_name),
      by = "dependency_path"
    ) |>
    filter(!is.na(from_module), !is.na(to_module)) |>
    select(from_module, from_bsn, to_module, to_bsn, dependency_path) |>
    distinct()
}

dependencies      <- resolve_edges(raw_compile)
test_dependencies <- resolve_edges(raw_test)

log_info("Resolved compileOnly edges:        {nrow(dependencies)}")
log_info("Resolved testImplementation edges: {nrow(test_dependencies)}")
log_info("Unique source modules (compile):   {n_distinct(dependencies$from_module)}")
log_info("Unique target modules (compile):   {n_distinct(dependencies$to_module)}")

# -----------------------------------------------------------------------------
# Step 5 — Compute basic graph stats per module
# -----------------------------------------------------------------------------

# dependent_count: how many modules depend ON this module (incoming edges)
incoming <- dependencies |>
  count(to_module, name = "dependent_count") |>
  rename(module_name = to_module)

# dependency_count: how many modules this module depends on (outgoing edges)
outgoing <- dependencies |>
  count(from_module, name = "dependency_count") |>
  rename(module_name = from_module)

module_graph_stats <- module_registry |>
  select(module_name, module_path, bundle_symbolic_name) |>
  left_join(incoming, by = "module_name") |>
  left_join(outgoing, by = "module_name") |>
  mutate(
    dependent_count  = coalesce(dependent_count, 0L),
    dependency_count = coalesce(dependency_count, 0L),
    # Shared utilities: high dependent count relative to corpus
    is_shared_util   = dependent_count >= quantile(dependent_count, 0.90, na.rm = TRUE)
  )

log_info("Top 10 most depended-upon modules:")
module_graph_stats |>
  arrange(desc(dependent_count)) |>
  head(10) |>
  with(log_info("  {module_name}: {dependent_count} dependents"))

# -----------------------------------------------------------------------------
# Step 6 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(dependencies,      dependencies_path)
saveRDS(test_dependencies, test_deps_path)
saveRDS(module_graph_stats, registry_path)

log_info("Saved raw_dependencies.rds:      {nrow(dependencies)} compileOnly edges")
log_info("Saved raw_test_dependencies.rds: {nrow(test_dependencies)} testImplementation edges")
log_info("Saved raw_module_registry.rds:   {nrow(module_graph_stats)} modules")
log_info("--- extract_dependencies complete ---")