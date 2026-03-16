# =============================================================================
# load_module_component_map.R
# Seeds dim_component (with team_name) and dim_module_component_map.
# Safe to re-run — uses UPSERT logic; existing rows are updated, not duplicated.
#
# Three-layer loading strategy:
#   Layer 1 — module_component_team_map.csv (primary, has team names)
#   Layer 2 — module_component_map.csv (legacy fallback, adds any missed mappings)
#   Layer 3 — fuzzy_match_candidates.csv (last resort, if staging file exists)
#
# Usage (standalone):
#   source("utils/load_module_component_map.R")
#   load_module_component_map(con)
#
# Called automatically by ingest_churn_csv.R and transform_forecast_input.R.
# =============================================================================

load_module_component_map <- function(
    con,
    primary_map_path = "config/module_component_team_map.csv",
    legacy_map_path  = "config/module_component_map.csv",
    fuzzy_path       = "staging/fuzzy_match_candidates.csv"
) {
  
  suppressPackageStartupMessages({
    library(dplyr)
    library(DBI)
    library(readr)
  })
  
  message("\n=== LOADING MODULE → COMPONENT MAP ===")
  
  # ===========================================================================
  # LAYER 1 — Primary: module_component_team_map.csv
  # Has module_path, component_name, team_name
  # ===========================================================================
  message("\n  [Layer 1] Primary map: ", primary_map_path)
  
  primary_raw <- read_csv(
    primary_map_path,
    col_types = cols(.default = "c"),
    show_col_types = FALSE
  )
  colnames(primary_raw) <- c("module_path", "component_name", "team_name")
  
  primary_raw <- primary_raw %>%
    mutate(
      module_path    = trimws(module_path),
      component_name = trimws(component_name),
      team_name      = trimws(team_name)
    )
  
  # Clean: remove blank components, blank teams treated as NULL, dedup
  primary_clean <- primary_raw %>%
    filter(!is.na(component_name), component_name != "") %>%
    mutate(
      team_name = ifelse(team_name %in% c("", "NoMappedTeam", NA), NA_character_, team_name)
    ) %>%
    distinct(module_path, component_name, .keep_all = TRUE)
  
  # Rows with no module_path are component+team-only — still useful for dim_component
  primary_comp_only <- primary_clean %>% filter(is.na(module_path) | module_path == "")
  primary_with_path <- primary_clean %>% filter(!is.na(module_path), module_path != "")
  
  message(sprintf("    %d mappings with module path", nrow(primary_with_path)))
  message(sprintf("    %d component+team entries (no module path — team info only)",
                  nrow(primary_comp_only)))
  
  # ===========================================================================
  # LAYER 2 — Legacy fallback: module_component_map.csv
  # Only adds mappings for module paths NOT already covered by Layer 1
  # ===========================================================================
  message("\n  [Layer 2] Legacy fallback: ", legacy_map_path)
  
  legacy_raw <- read_csv(
    legacy_map_path,
    col_types = cols(.default = "c"),
    show_col_types = FALSE
  )
  colnames(legacy_raw) <- c("module_path", "component_name")
  
  legacy_clean <- legacy_raw %>%
    mutate(
      module_path    = trimws(module_path),
      component_name = trimws(component_name),
      team_name      = NA_character_
    ) %>%
    filter(!is.na(component_name), component_name != "",
           !is.na(module_path),    module_path    != "") %>%
    distinct(module_path, component_name, .keep_all = TRUE)
  
  # Only keep legacy rows where module_path is NOT already in primary
  primary_paths <- unique(primary_with_path$module_path)
  legacy_new <- legacy_clean %>%
    filter(!module_path %in% primary_paths)
  
  n_dupes_removed <- nrow(legacy_clean) - nrow(legacy_new) -
    (nrow(legacy_clean) - nrow(legacy_clean %>% distinct(module_path, component_name)))
  message(sprintf("    %d legacy rows, %d already covered by primary, %d new fallback mappings added",
                  nrow(legacy_clean),
                  nrow(legacy_clean) - nrow(legacy_new),
                  nrow(legacy_new)))
  
  # ===========================================================================
  # LAYER 3 — Fuzzy matches (optional, if staging file exists)
  # ===========================================================================
  fuzzy_new <- tibble(module_path = character(), component_name = character(),
                      team_name = character())
  
  if (file.exists(fuzzy_path)) {
    message("\n  [Layer 3] Fuzzy matches: ", fuzzy_path)
    fuzzy_raw <- tryCatch(
      read_csv(fuzzy_path, col_types = cols(.default = "c"), show_col_types = FALSE),
      error = function(e) NULL
    )
    if (!is.null(fuzzy_raw) && "module_name" %in% names(fuzzy_raw) &&
        "component_name" %in% names(fuzzy_raw)) {
      all_covered <- c(primary_paths, unique(legacy_new$module_path))
      fuzzy_new <- fuzzy_raw %>%
        mutate(
          module_path    = trimws(module_name),   # fuzzy file uses module_name
          component_name = trimws(component_name),
          team_name      = NA_character_
        ) %>%
        filter(
          !is.na(component_name), component_name != "",
          !is.na(module_path),
          !module_path %in% all_covered,
          # Only use approved fuzzy matches if approve column exists
          if ("approve" %in% names(.)) approve == TRUE else TRUE
        ) %>%
        distinct(module_path, component_name, .keep_all = TRUE) %>%
        select(module_path, component_name, team_name)
      message(sprintf("    %d new fuzzy mappings added", nrow(fuzzy_new)))
    }
  } else {
    message("\n  [Layer 3] Fuzzy match file not found — skipping")
  }
  
  # ===========================================================================
  # COMBINE all layers
  # ===========================================================================
  all_mappings <- bind_rows(
    primary_with_path %>% select(module_path, component_name, team_name),
    legacy_new        %>% select(module_path, component_name, team_name),
    fuzzy_new         %>% select(module_path, component_name, team_name)
  ) %>%
    distinct(module_path, component_name, .keep_all = TRUE)
  
  # All unique components (from mappings + comp-only rows)
  all_components <- bind_rows(
    all_mappings  %>% select(component_name, team_name),
    primary_comp_only %>% select(component_name, team_name)
  ) %>%
    group_by(component_name) %>%
    # Prefer non-NA team_name
    summarise(
      team_name = first(na.omit(team_name)),
      .groups = "drop"
    ) %>%
    filter(!is.na(component_name), component_name != "") %>%
    arrange(component_name)
  
  message(sprintf("\n  Combined: %d module mappings → %d unique components across %d teams",
                  nrow(all_mappings),
                  nrow(all_components),
                  n_distinct(na.omit(all_components$team_name))))
  
  # ===========================================================================
  # COMPUTE WEIGHTS (1/n per module path)
  # ===========================================================================
  weights <- all_mappings %>%
    group_by(module_path) %>%
    mutate(
      n_components = n(),
      weight       = round(1 / n_components, 4)
    ) %>%
    ungroup()
  
  multi_mapped <- weights %>%
    filter(n_components > 1) %>%
    distinct(module_path, n_components) %>%
    arrange(desc(n_components))
  
  message(sprintf("  Multi-component modules: %d (weight split applied)", nrow(multi_mapped)))
  if (nrow(multi_mapped) > 0) {
    message("  Top 5 by component count:")
    print(head(multi_mapped, 5))
  }
  
  # ===========================================================================
  # UPSERT dim_component (with team_name)
  # ===========================================================================
  message(sprintf("\n  Upserting %d components into dim_component...", nrow(all_components)))
  
  dbExecute(con, "
    CREATE TEMP TABLE IF NOT EXISTS _tmp_components (
      component_name VARCHAR(200),
      team_name      VARCHAR(100)
    ) ON COMMIT DROP
  ")
  
  dbWriteTable(con, "_tmp_components",
               as.data.frame(all_components),
               overwrite = TRUE, row.names = FALSE)
  
  dbExecute(con, "
    INSERT INTO dim_component (component_name, team_name)
    SELECT component_name, team_name FROM _tmp_components
    ON CONFLICT (component_name)
      DO UPDATE SET team_name = COALESCE(EXCLUDED.team_name, dim_component.team_name)
  ")
  
  message("  dim_component upsert complete.")
  
  # ===========================================================================
  # FETCH component_id lookup
  # ===========================================================================
  comp_lookup <- dbGetQuery(con,
                            "SELECT component_id, component_name FROM dim_component"
  )
  
  # ===========================================================================
  # UPSERT dim_module_component_map
  # ===========================================================================
  map_with_ids <- weights %>%
    left_join(comp_lookup, by = "component_name") %>%
    filter(!is.na(component_id)) %>%
    select(module_path, component_id, weight)
  
  message(sprintf("\n  Upserting %d rows into dim_module_component_map...", nrow(map_with_ids)))
  
  dbExecute(con, "
    CREATE TEMP TABLE IF NOT EXISTS _tmp_mcm (
      module_path  VARCHAR(500),
      component_id INT,
      weight       NUMERIC(6,4)
    ) ON COMMIT DROP
  ")
  
  dbWriteTable(con, "_tmp_mcm", map_with_ids, overwrite = TRUE, row.names = FALSE)
  
  dbExecute(con, "
    INSERT INTO dim_module_component_map (module_path, component_id, weight)
    SELECT module_path, component_id, weight FROM _tmp_mcm
    ON CONFLICT (module_path, component_id)
      DO UPDATE SET weight = EXCLUDED.weight
  ")
  
  message("  dim_module_component_map upsert complete.")
  
  # ===========================================================================
  # VALIDATION SUMMARY
  # ===========================================================================
  n_comp      <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_component")$n
  n_with_team <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_component WHERE team_name IS NOT NULL")$n
  n_map       <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_module_component_map")$n
  n_multi     <- dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM (
      SELECT module_path FROM dim_module_component_map
      GROUP BY module_path HAVING COUNT(*) > 1
    ) t
  ")$n
  
  message(paste0("\n  ✓ dim_component rows:            ", as.integer(n_comp)))
  message(paste0("  ✓   with team_name:              ", as.integer(n_with_team)))
  message(paste0("  ✓ dim_module_component_map rows: ", as.integer(n_map)))
  message(paste0("  ✓ Multi-component module paths:  ", as.integer(n_multi), " (weighted)"))
  
  # Team coverage summary
  team_summary <- dbGetQuery(con, "
    SELECT team_name, COUNT(*) AS n_components
    FROM dim_component
    WHERE team_name IS NOT NULL
    GROUP BY team_name
    ORDER BY n_components DESC
  ")
  message("\n  Components by team:")
  for (i in seq_len(nrow(team_summary))) {
    message(paste0("    ", formatC(team_summary$team_name[i], width=-35), " ", as.integer(team_summary$n_components[i])))
  }
  
  invisible(list(
    n_components  = n_comp,
    n_mappings    = n_map,
    multi_mapped  = multi_mapped,
    team_summary  = team_summary
  ))
}

# =============================================================================
# Run standalone
# =============================================================================
if (sys.nframe() == 0L) {
  source("config/release_analytics_db.R")
  con <- get_db_connection()
  on.exit(dbDisconnect(con))
  load_module_component_map(con)
}