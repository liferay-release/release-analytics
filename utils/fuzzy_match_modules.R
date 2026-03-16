# =============================================================================
# fuzzy_match_modules.R
# Generates candidate module → Testray component mappings using fuzzy matching
# Compares unmapped git module names against dim_component names
#
# Output: staging/fuzzy_match_candidates.csv  — review and approve before loading
# =============================================================================

library(dplyr)
library(stringr)
library(stringdist)
library(DBI)
library(RPostgres)
library(logger)
library(yaml)

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- fuzzy_match_modules started ---")

source("config/release_analytics_db.R")
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Load unmapped modules and all components
# -----------------------------------------------------------------------------
unmapped_modules <- dbGetQuery(con, "
  SELECT m.module_id, m.module_name
  FROM dim_module m
  WHERE m.module_id NOT IN (
    SELECT DISTINCT module_id FROM module_component_map
  )
  ORDER BY m.module_name
")

all_components <- dbGetQuery(con, "
  SELECT component_id, component_name
  FROM dim_component
  ORDER BY component_name
")

log_info("Unmapped modules: {nrow(unmapped_modules)}")
log_info("Components to match against: {nrow(all_components)}")

# -----------------------------------------------------------------------------
# Normalize names for matching
# Strip common suffixes and separators to improve signal
# e.g. portal-search-elasticsearch8-impl → portal search elasticsearch
#      Search Infrastructure > Elasticsearch Connector → search elasticsearch connector
# -----------------------------------------------------------------------------
normalize <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("-impl$|-api$|-service$|-web$|-test$|-client$|-spi$|-core$|-util$") |>
    str_replace_all("[-_>]", " ") |>
    str_remove_all("[^a-z0-9 ]") |>
    str_squish()
}

mod_norm  <- normalize(unmapped_modules$module_name)
comp_norm <- normalize(all_components$component_name)

# -----------------------------------------------------------------------------
# Fuzzy match — for each module find best matching component
# Uses Jaro-Winkler distance (good for short strings with common prefixes)
# Also tries token overlap for longer compound names
# -----------------------------------------------------------------------------
log_info("Running fuzzy match...")

results <- lapply(seq_len(nrow(unmapped_modules)), function(i) {
  mod_name  <- unmapped_modules$module_name[i]
  mod_clean <- mod_norm[i]

  # Jaro-Winkler distances
  jw_dist   <- stringdist(mod_clean, comp_norm, method = "jw", p = 0.1)
  jw_sim    <- 1 - jw_dist

  # Token overlap — what fraction of module tokens appear in component name
  mod_tokens  <- str_split(mod_clean, " ")[[1]]
  token_sim   <- sapply(comp_norm, function(cn) {
    comp_tokens <- str_split(cn, " ")[[1]]
    overlap     <- sum(mod_tokens %in% comp_tokens)
    if (length(mod_tokens) == 0) return(0)
    overlap / length(mod_tokens)
  })

  # Combined score — weighted average
  combined <- (jw_sim * 0.5) + (token_sim * 0.5)

  best_idx   <- which.max(combined)
  best_score <- combined[best_idx]

  # Second best for confidence gap
  sorted_scores <- sort(combined, decreasing = TRUE)
  gap <- if (length(sorted_scores) >= 2) sorted_scores[1] - sorted_scores[2] else 1

  data.frame(
    module_name      = mod_name,
    component_name   = all_components$component_name[best_idx],
    combined_score   = round(best_score, 3),
    confidence_gap   = round(gap, 3),
    jw_sim           = round(jw_sim[best_idx], 3),
    token_sim        = round(token_sim[best_idx], 3),
    stringsAsFactors = FALSE
  )
})

candidates <- bind_rows(results) |>
  arrange(desc(combined_score))

# -----------------------------------------------------------------------------
# Tier by confidence
# HIGH   >= 0.70 — likely correct, review recommended
# MEDIUM  0.50-0.69 — plausible, review required
# LOW    < 0.50 — weak match, probably wrong
# -----------------------------------------------------------------------------
candidates <- candidates |>
  mutate(
    confidence = case_when(
      combined_score >= 0.70 ~ "HIGH",
      combined_score >= 0.50 ~ "MEDIUM",
      TRUE                   ~ "LOW"
    )
  ) |>
  select(module_name, component_name, confidence, combined_score, confidence_gap, jw_sim, token_sim)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log_info("Match confidence distribution:")
log_info("  HIGH   (>=0.70): {sum(candidates$confidence == 'HIGH')} modules")
log_info("  MEDIUM (>=0.50): {sum(candidates$confidence == 'MEDIUM')} modules")
log_info("  LOW    (<0.50):  {sum(candidates$confidence == 'LOW')} modules")

log_info("Top 20 HIGH confidence matches:")
top20 <- candidates |> filter(confidence == "HIGH") |> head(20)
for (i in seq_len(nrow(top20))) {
  log_info("  {top20$module_name[i]} → {top20$component_name[i]} ({top20$combined_score[i]})")
}

# -----------------------------------------------------------------------------
# Save candidates CSV for review
# Add approve column (blank = review needed, TRUE = approved, FALSE = rejected)
# -----------------------------------------------------------------------------
candidates$approve <- ""
candidates$notes   <- ""

if (!dir.exists("staging")) dir.create("staging")
write.csv(candidates, "staging/fuzzy_match_candidates.csv", row.names = FALSE)

log_info("Saved staging/fuzzy_match_candidates.csv")
log_info("Review and set approve=TRUE for correct matches, then run load_fuzzy_approved.R")
log_info("--- fuzzy_match_modules complete ---")
