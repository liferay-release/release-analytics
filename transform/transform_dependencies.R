# =============================================================================
# transform_dependencies.R
# Builds dependency scores from the module dependency graph using two signals:
#
#   1. Blast radius (incoming) — how many modules depend on this module
#      High blast = breaking this module breaks many others
#      BFS walk: reverse edges, depth-capped at MAX_DEPTH
#
#   2. Integration depth (outgoing) — how deeply this module is embedded
#      in critical shared infrastructure (top 10% by dependent_count)
#      High integration = module is wired into critical portal internals
#      even if nothing explicitly depends on it (e.g. elasticsearch-impl)
#
#   Final dependency_score = (blast_score * 0.60) + (integration_score * 0.40)
#
# Input:  staging/raw_dependencies.rds       — compileOnly edge list
#         staging/raw_module_registry.rds    — module metadata + graph stats
# Output: fact_file_dependencies (PostgreSQL) — per-file dependency scores
#         fact_module_dependencies (PostgreSQL) — per-module scores
#         staging/transformed_dependencies.rds
#
# Notes:
#   - is_shared_util = top 10% by dependent_count (set in extract_dependencies.R)
#   - Blast score normalized by p95 total_blast
#   - Integration score normalized by p95 outgoing_critical_count
#   - Manual overrides supported via config/blast_radius_overrides.yml (future)
# =============================================================================

library(dplyr)
library(purrr)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- transform_dependencies started ---")

source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

MAX_DEPTH <- 3  # BFS depth cap — beyond this blast radius signal is too noisy

# -----------------------------------------------------------------------------
# Load staged data
# -----------------------------------------------------------------------------
if (!file.exists("staging/raw_dependencies.rds")) {
  log_error("staging/raw_dependencies.rds not found — run extract_dependencies.R first")
  stop("raw_dependencies.rds not found")
}

edges    <- readRDS("staging/raw_dependencies.rds")
registry <- readRDS("staging/raw_module_registry.rds")

log_info("Dependency edges loaded: {nrow(edges)}")
log_info("Module registry loaded:  {nrow(registry)} modules")

# Shared util lookup — top 10% by dependent_count (set in extract)
shared_utils <- registry |>
  filter(is_shared_util == TRUE) |>
  pull(module_name)

log_info("Shared utility modules (top 10% by dependents): {length(shared_utils)}")

# -----------------------------------------------------------------------------
# Step 1 — Build adjacency lists
# reverse_adj: "who depends on module X" — used for blast radius
# forward_adj: "what does module X depend on" — used for integration depth
# -----------------------------------------------------------------------------
log_info("Building adjacency lists...")

reverse_adj_list <- edges |>
  group_by(to_module) |>
  summarise(dependents = list(unique(from_module)), .groups = "drop") |>
  (\(x) setNames(x$dependents, x$to_module))()

forward_adj_list <- edges |>
  group_by(from_module) |>
  summarise(imports = list(unique(to_module)), .groups = "drop") |>
  (\(x) setNames(x$imports, x$from_module))()

all_modules <- unique(registry$module_name)
log_info("Modules in graph: {length(all_modules)}")

# -----------------------------------------------------------------------------
# Step 2 — BFS for blast radius (reverse direction)
# -----------------------------------------------------------------------------
bfs_blast_radius <- function(start_module, adj_list, max_depth = MAX_DEPTH) {
  visited <- character(0)
  queue   <- data.frame(module = start_module, depth = 0L, stringsAsFactors = FALSE)
  result  <- data.frame(module = character(), depth = integer(), stringsAsFactors = FALSE)
  
  while (nrow(queue) > 0) {
    current <- queue[1, ]
    queue   <- queue[-1, ]
    
    if (current$module %in% visited) next
    visited <- c(visited, current$module)
    
    if (current$depth > 0) {
      result <- rbind(result, current)
    }
    
    if (current$depth < max_depth) {
      neighbors <- adj_list[[current$module]]
      if (!is.null(neighbors)) {
        new_nodes <- neighbors[!neighbors %in% visited]
        if (length(new_nodes) > 0) {
          queue <- rbind(queue, data.frame(
            module = new_nodes,
            depth  = current$depth + 1L,
            stringsAsFactors = FALSE
          ))
        }
      }
    }
  }
  
  result
}

# -----------------------------------------------------------------------------
# Step 3 — Run blast radius BFS for all modules
# -----------------------------------------------------------------------------
log_info("Running blast radius BFS for {length(all_modules)} modules (max depth: {MAX_DEPTH})...")

blast_stats <- map_dfr(all_modules, function(mod) {
  affected <- bfs_blast_radius(mod, reverse_adj_list, MAX_DEPTH)
  
  data.frame(
    module_name       = mod,
    dependent_count   = sum(affected$depth == 1),
    transitive_count  = sum(affected$depth > 1),
    total_blast       = nrow(affected),
    max_depth_reached = ifelse(nrow(affected) > 0, max(affected$depth), 0L),
    stringsAsFactors  = FALSE
  )
})

log_info("Blast radius BFS complete")
log_info("Modules with any dependents:    {sum(blast_stats$dependent_count > 0)}")
log_info("Modules with transitive impact: {sum(blast_stats$transitive_count > 0)}")
log_info("Max blast radius observed:      {max(blast_stats$total_blast)}")

# -----------------------------------------------------------------------------
# Step 4 — Compute integration depth (forward direction)
# For each module, count how many direct imports are shared utilities
# -----------------------------------------------------------------------------
log_info("Computing integration depth scores...")

integration_stats <- map_dfr(all_modules, function(mod) {
  imports <- forward_adj_list[[mod]]
  
  if (is.null(imports)) {
    return(data.frame(
      module_name             = mod,
      outgoing_count          = 0L,
      outgoing_critical_count = 0L,
      outgoing_critical_ratio = 0,
      stringsAsFactors        = FALSE
    ))
  }
  
  critical_imports <- sum(imports %in% shared_utils)
  
  data.frame(
    module_name             = mod,
    outgoing_count          = length(imports),
    outgoing_critical_count = critical_imports,
    outgoing_critical_ratio = round(critical_imports / length(imports), 4),
    stringsAsFactors        = FALSE
  )
})

log_info("Integration depth computed: {nrow(integration_stats)} modules")
log_info("Modules with critical imports: {sum(integration_stats$outgoing_critical_count > 0)}")

log_info("Top 10 modules by integration depth:")
integration_stats |>
  arrange(desc(outgoing_critical_count)) |>
  head(10) |>
  rowwise() |>
  group_walk(~ log_info("  {.x$module_name}: {.x$outgoing_critical_count} critical imports of {.x$outgoing_count} total ({.x$outgoing_critical_ratio})"))

# -----------------------------------------------------------------------------
# Step 5 — Normalize both signals and compute blended dependency_score
# blast_score:        normalized by p95 total_blast
# integration_score:  normalized by p95 outgoing_critical_count
# dependency_score  = (blast_score * 0.60) + (integration_score * 0.40)
# -----------------------------------------------------------------------------
p95_blast       <- quantile(blast_stats$total_blast,                   0.95, na.rm = TRUE)
p95_integration <- quantile(integration_stats$outgoing_critical_count, 0.95, na.rm = TRUE)

log_info("p95 blast radius:      {p95_blast}")
log_info("p95 integration depth: {p95_integration}")

module_scores <- blast_stats |>
  left_join(integration_stats, by = "module_name") |>
  left_join(registry |> select(module_name, is_shared_util), by = "module_name") |>
  mutate(
    is_shared_util    = coalesce(is_shared_util, FALSE),
    blast_score       = round(pmin(total_blast / p95_blast, 1), 4),
    integration_score = round(
      pmin(outgoing_critical_count / max(p95_integration, 1), 1), 4
    ),
    dependency_score  = round(
      (blast_score * 0.60) + (integration_score * 0.40), 4
    )
  )

log_info("Top 10 modules by blended dependency score:")
module_scores |>
  arrange(desc(dependency_score)) |>
  head(10) |>
  rowwise() |>
  group_walk(~ log_info("  {.x$module_name}: {.x$dependency_score} (blast: {.x$blast_score}, integration: {.x$integration_score})"))

# -----------------------------------------------------------------------------
# Step 6 — Resolve module_id from dim_module
# -----------------------------------------------------------------------------
dim_module <- dbGetQuery(con, "SELECT module_id, module_name FROM dim_module")
dim_file   <- dbGetQuery(con, "SELECT file_id, file_path, module_id FROM dim_file")

module_scores_with_ids <- module_scores |>
  left_join(dim_module, by = "module_name") |>
  group_by(module_name) |>
  slice_min(module_id, n = 1, with_ties = FALSE) |>
  ungroup()

log_info("Modules matched to dim_module: {sum(!is.na(module_scores_with_ids$module_id))} of {nrow(module_scores_with_ids)}")

# -----------------------------------------------------------------------------
# Step 7 — Upsert fact_module_dependencies
# Add integration columns if upgrading from earlier schema version
# -----------------------------------------------------------------------------
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS fact_module_dependencies (
    module_dep_id           SERIAL PRIMARY KEY,
    module_id               INT REFERENCES dim_module(module_id),
    module_name             VARCHAR(200) NOT NULL,
    dependent_count         INT DEFAULT 0,
    transitive_count        INT DEFAULT 0,
    total_blast             INT DEFAULT 0,
    max_depth_reached       INT DEFAULT 0,
    is_shared_util          BOOLEAN DEFAULT FALSE,
    outgoing_count          INT DEFAULT 0,
    outgoing_critical_count INT DEFAULT 0,
    outgoing_critical_ratio NUMERIC(5,4) DEFAULT 0,
    blast_score             NUMERIC(5,4) DEFAULT 0,
    integration_score       NUMERIC(5,4) DEFAULT 0,
    dependency_score        NUMERIC(5,4) DEFAULT 0,
    calculated_at           TIMESTAMP DEFAULT NOW(),
    UNIQUE (module_name)
  )
")

# Non-destructive column additions for existing tables
dbExecute(con, "ALTER TABLE fact_module_dependencies ADD COLUMN IF NOT EXISTS outgoing_count          INT DEFAULT 0")
dbExecute(con, "ALTER TABLE fact_module_dependencies ADD COLUMN IF NOT EXISTS outgoing_critical_count INT DEFAULT 0")
dbExecute(con, "ALTER TABLE fact_module_dependencies ADD COLUMN IF NOT EXISTS outgoing_critical_ratio NUMERIC(5,4) DEFAULT 0")
dbExecute(con, "ALTER TABLE fact_module_dependencies ADD COLUMN IF NOT EXISTS blast_score             NUMERIC(5,4) DEFAULT 0")
dbExecute(con, "ALTER TABLE fact_module_dependencies ADD COLUMN IF NOT EXISTS integration_score       NUMERIC(5,4) DEFAULT 0")

dbWriteTable(con, "temp_module_deps",
             module_scores_with_ids |>
               select(module_id, module_name, dependent_count, transitive_count,
                      total_blast, max_depth_reached, is_shared_util,
                      outgoing_count, outgoing_critical_count, outgoing_critical_ratio,
                      blast_score, integration_score, dependency_score),
             temporary = TRUE, overwrite = TRUE
)

dbExecute(con, "
  INSERT INTO fact_module_dependencies (
    module_id, module_name, dependent_count, transitive_count,
    total_blast, max_depth_reached, is_shared_util,
    outgoing_count, outgoing_critical_count, outgoing_critical_ratio,
    blast_score, integration_score, dependency_score, calculated_at
  )
  SELECT module_id, module_name, dependent_count, transitive_count,
         total_blast, max_depth_reached, is_shared_util,
         outgoing_count, outgoing_critical_count, outgoing_critical_ratio,
         blast_score, integration_score, dependency_score, NOW()
  FROM temp_module_deps
  ON CONFLICT (module_name) DO UPDATE SET
    module_id               = EXCLUDED.module_id,
    dependent_count         = EXCLUDED.dependent_count,
    transitive_count        = EXCLUDED.transitive_count,
    total_blast             = EXCLUDED.total_blast,
    max_depth_reached       = EXCLUDED.max_depth_reached,
    is_shared_util          = EXCLUDED.is_shared_util,
    outgoing_count          = EXCLUDED.outgoing_count,
    outgoing_critical_count = EXCLUDED.outgoing_critical_count,
    outgoing_critical_ratio = EXCLUDED.outgoing_critical_ratio,
    blast_score             = EXCLUDED.blast_score,
    integration_score       = EXCLUDED.integration_score,
    dependency_score        = EXCLUDED.dependency_score,
    calculated_at           = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS temp_module_deps")
log_info("fact_module_dependencies upserted: {nrow(module_scores_with_ids)} rows")

# -----------------------------------------------------------------------------
# Step 8 — Populate fact_file_dependencies
# Add integration columns if upgrading from earlier schema version
# -----------------------------------------------------------------------------
dbExecute(con, "ALTER TABLE fact_file_dependencies ADD COLUMN IF NOT EXISTS blast_score       NUMERIC(5,4) DEFAULT 0")
dbExecute(con, "ALTER TABLE fact_file_dependencies ADD COLUMN IF NOT EXISTS integration_score NUMERIC(5,4) DEFAULT 0")

blast_for_files <- module_scores_with_ids |>
  filter(!is.na(module_id)) |>
  group_by(module_id) |>
  slice_max(dependency_score, n = 1, with_ties = FALSE) |>
  ungroup()

file_deps <- dim_file |>
  filter(!is.na(module_id)) |>
  left_join(
    blast_for_files |> select(module_id, dependent_count, transitive_count,
                              total_blast, is_shared_util,
                              blast_score, integration_score, dependency_score),
    by = "module_id",
    relationship = "many-to-one"
  ) |>
  filter(!is.na(dependency_score)) |>
  mutate(
    dependent_count   = coalesce(dependent_count,  0L),
    transitive_count  = coalesce(transitive_count, 0L),
    blast_score       = coalesce(blast_score,       0),
    integration_score = coalesce(integration_score, 0),
    dependency_score  = coalesce(dependency_score,  0)
  )

log_info("File-level dependency rows to write: {nrow(file_deps)}")
stopifnot(nrow(file_deps) < 100000)  # sanity check before upsert

dbWriteTable(con, "temp_file_deps",
             file_deps |> select(file_id, dependent_count, transitive_count,
                                 total_blast, is_shared_util,
                                 blast_score, integration_score, dependency_score),
             temporary = TRUE, overwrite = TRUE
)

dbExecute(con, "
  INSERT INTO fact_file_dependencies (
    file_id, dependent_count, transitive_count,
    is_shared_util, blast_score, integration_score, dependency_score, calculated_at
  )
  SELECT file_id, dependent_count, transitive_count,
         is_shared_util, blast_score, integration_score, dependency_score, NOW()
  FROM temp_file_deps
  ON CONFLICT (file_id) DO UPDATE SET
    dependent_count   = EXCLUDED.dependent_count,
    transitive_count  = EXCLUDED.transitive_count,
    is_shared_util    = EXCLUDED.is_shared_util,
    blast_score       = EXCLUDED.blast_score,
    integration_score = EXCLUDED.integration_score,
    dependency_score  = EXCLUDED.dependency_score,
    calculated_at     = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS temp_file_deps")

final_count <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM fact_file_dependencies")
log_info("fact_file_dependencies total rows: {final_count$n}")

# -----------------------------------------------------------------------------
# Step 9 — Spot check elasticsearch to validate integration signal
# -----------------------------------------------------------------------------
es_check <- dbGetQuery(con, "
  SELECT module_name, blast_score, integration_score, dependency_score,
         outgoing_count, outgoing_critical_count
  FROM fact_module_dependencies
  WHERE module_name LIKE '%elasticsearch%'
  ORDER BY dependency_score DESC
")

if (nrow(es_check) > 0) {
  log_info("Elasticsearch module scores:")
  for (i in seq_len(nrow(es_check))) {
    log_info("  {es_check$module_name[i]}: dependency={es_check$dependency_score[i]} blast={es_check$blast_score[i]} integration={es_check$integration_score[i]} (critical imports: {es_check$outgoing_critical_count[i]} of {es_check$outgoing_count[i]})")
  }
}

# -----------------------------------------------------------------------------
# Step 10 — Save to staging
# -----------------------------------------------------------------------------
saveRDS(module_scores, "staging/transformed_dependencies.rds")
log_info("Saved staging/transformed_dependencies.rds")
log_info("--- transform_dependencies complete ---")