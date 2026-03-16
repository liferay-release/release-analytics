# =============================================================================
# lda_analysis.R
# Topic Analysis for the Release Landscape Report
#
# Runs LDA topic modeling for multiple time periods and exports CSVs + PNGs.
# Each run produces a self-contained set of outputs in its own subfolder.
#
# Input:  staging/raw_jira_issues.rds
# Output: reports/release_landscape/exports/topics_<label>/
#           L05_topic_terms.csv
#           L05_topic_by_source.csv
#           L05_topic_divergence.csv
#           L05_topic_by_component.csv
#           L05_bigrams.csv
#           plots/L05a_topic_terms.png
#           plots/L05b_topic_distribution.png
#           plots/L05c_topic_divergence.png
#           plots/L05d_component_topics_lpp.png
#           plots/L05e_component_topics_lpd.png
#           plots/L05f_bigrams.png
#
# Configure runs in the RUNS section below, then source the file.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(tidytext)
  library(topicmodels)
  library(yaml)
  library(stringr)
  library(ggplot2)
  library(forcats)
})

options(scipen = 999)
set.seed(1234)

# =============================================================================
# SHARED CONFIG
# =============================================================================
N_TOPICS       <- 10    # Number of LDA topics
MIN_BUGS       <- 50    # Minimum bugs needed to run LDA
MIN_WORD_LEN   <- 3     # Minimum word length
MIN_DOC_FREQ   <- 3     # Minimum times a word must appear across documents
TOP_COMPONENTS <- 15    # Components to show in heatmap

BASE_DIR <- "reports/release_landscape/exports"

# =============================================================================
# RUNS — add or remove entries to control which periods are analysed
# =============================================================================
RUNS <- list(
  list(
    label       = "all_time",
    title       = "All Available Data (2024+)",
    date_from   = as.Date("2024-01-01"),
    date_to     = Sys.Date(),
    min_quarter = "2024.Q1"
  ),
  list(
    label       = "2024",
    title       = "2024 Only (Pre/Early Process Change)",
    date_from   = as.Date("2024-01-01"),
    date_to     = as.Date("2024-12-31"),
    min_quarter = "2024.Q1"
  ),
  list(
    label       = "2025",
    title       = "2025 Only (Post Process Change)",
    date_from   = as.Date("2025-01-01"),
    date_to     = as.Date("2025-12-31"),
    min_quarter = "2025.Q1"
  )
)

# =============================================================================
# LOAD DATA ONCE
# =============================================================================
message("\n=== LDA TOPIC ANALYSIS ===")

jira_path <- "staging/raw_jira_issues.rds"
if (!file.exists(jira_path)) stop("raw_jira_issues.rds not found — run extract_jira.R first")

jira_raw <- readRDS(jira_path)
message(sprintf("  Loaded %d Jira issues", nrow(jira_raw)))

cfg <- read_yaml("config/config.yml")
dev_windows <- bind_rows(lapply(cfg$jira$dev_windows, as.data.frame)) %>%
  mutate(dev_start = as.Date(dev_start), dev_end = as.Date(dev_end))

date_to_dev_quarter <- function(dates, windows) {
  sapply(dates, function(d) {
    if (is.na(d)) return(NA_character_)
    idx <- which(d >= windows$dev_start & d <= windows$dev_end)
    if (length(idx) == 0) return(NA_character_)
    windows$quarter[idx[1]]
  }, USE.NAMES = FALSE)
}

# =============================================================================
# STOPWORDS — built once, shared across all runs
# =============================================================================
message("\n--- Building stopword list ---")

custom_stopwords_path <- "config/exclusion-list.txt"
custom_stops <- character(0)

if (file.exists(custom_stopwords_path)) {
  raw_lines <- readLines(custom_stopwords_path, warn = FALSE)
  custom_stops <- raw_lines %>%
    trimws() %>% tolower() %>%
    .[!grepl("^#", .)] %>%
    .[nchar(.) > 0]
  message(sprintf("  Loaded %d custom stopwords from %s",
                  length(custom_stops), custom_stopwords_path))
} else {
  message("  No custom stopwords file found — using tidytext defaults only")
}

all_stops <- unique(c(stop_words$word, custom_stops))
message(sprintf("  Total stopwords: %d", length(all_stops)))

# Pre-process all bugs once
all_bugs_clean <- jira_raw %>%
  mutate(
    quarter = case_when(
      project == "LPP" & !is.na(quarter_lpp) & quarter_lpp >= "2024.Q1" ~ quarter_lpp,
      project == "LPP" & is.na(quarter_lpp) ~ date_to_dev_quarter(resolution_date, dev_windows),
      project == "LPD" ~ date_to_dev_quarter(created_date, dev_windows),
      TRUE ~ NA_character_
    ),
    source = case_when(
      project == "LPP" ~ "Customer (LPP)",
      project == "LPD" ~ "Internal (LPD)",
      TRUE ~ NA_character_
    ),
    full_text = tolower(summary),
    full_text = str_replace_all(full_text, "[^[:alnum:]\\s]", " "),
    full_text = str_squish(full_text),
    doc_id    = paste(source, coalesce(components, "Unspecified"), sep = "_"),
    ref_date  = as.Date(ifelse(project == "LPP",
                               as.character(coalesce(resolution_date, created_date)),
                               as.character(created_date)))
  ) %>%
  filter(!is.na(quarter), !is.na(source),
         !is.na(summary), summary != "")

# =============================================================================
# CORE LDA FUNCTION
# =============================================================================
run_lda <- function(run) {

  message(sprintf("\n%s", strrep("=", 70)))
  message(sprintf("RUN: %s — %s", run$label, run$title))
  message(sprintf("Period: %s to %s", run$date_from, run$date_to))
  message(strrep("=", 70))

  dir_out   <- file.path(BASE_DIR, paste0("topics_", run$label))
  dir_plots <- file.path(dir_out, "plots")
  dir.create(dir_plots, recursive = TRUE, showWarnings = FALSE)

  write_export <- function(df, filename) {
    path <- file.path(dir_out, filename)
    write_csv(df, path)
    message(sprintf("  ✓ %s (%d rows)", filename, nrow(df)))
    invisible(path)
  }

  save_plot <- function(p, filename, width=12, height=8) {
    path <- file.path(dir_plots, filename)
    ggsave(path, plot=p, width=width, height=height, dpi=300, bg="white")
    message(sprintf("  ✓ plots/%s", filename))
    invisible(path)
  }

  # Filter to this run's window
  bugs <- all_bugs_clean %>%
    filter(ref_date >= run$date_from,
           ref_date <= run$date_to,
           quarter  >= run$min_quarter)

  message(sprintf("\n  LPP: %d bugs", sum(bugs$source == "Customer (LPP)")))
  message(sprintf("  LPD: %d bugs", sum(bugs$source == "Internal (LPD)")))
  message(sprintf("  Quarters: %s", paste(sort(unique(bugs$quarter)), collapse=", ")))

  if (nrow(bugs) < MIN_BUGS) {
    message(sprintf("  ⚠️  Skipping — not enough bugs (%d < %d)", nrow(bugs), MIN_BUGS))
    return(invisible(NULL))
  }

  # ── Tokenize ────────────────────────────────────────────────────────────────
  message("\n--- Tokenizing ---")

  tokens <- bugs %>%
    select(doc_id, source, components, quarter, full_text) %>%
    unnest_tokens(word, full_text) %>%
    filter(!word %in% all_stops,
           !str_detect(word, "^\\d+$"),
           nchar(word) >= MIN_WORD_LEN)

  message(sprintf("  %d tokens | %d unique terms",
                  nrow(tokens), n_distinct(tokens$word)))

  # ── DTM ─────────────────────────────────────────────────────────────────────
  common_words <- tokens %>% count(word) %>%
    filter(n >= MIN_DOC_FREQ) %>% pull(word)

  dtm <- tokens %>%
    filter(word %in% common_words) %>%
    count(doc_id, word) %>%
    cast_dtm(doc_id, word, n)

  message(sprintf("  DTM: %d docs × %d terms", nrow(dtm), ncol(dtm)))

  # ── Fit LDA ─────────────────────────────────────────────────────────────────
  message(sprintf("\n--- Fitting LDA (k=%d) ---", N_TOPICS))
  lda_model <- LDA(dtm, k = N_TOPICS, control = list(seed = 1234))
  message("  Model fitted ✓")

  # ── Beta ────────────────────────────────────────────────────────────────────
  topics_beta <- tidy(lda_model, matrix = "beta") %>%
    filter(!term %in% all_stops, nchar(term) >= MIN_WORD_LEN)

  top_terms_per_topic <- topics_beta %>%
    group_by(topic) %>%
    slice_max(beta, n = 10) %>%
    ungroup() %>%
    arrange(topic, desc(beta)) %>%
    mutate(period = run$label)

  message("\n  Top terms per topic:")
  for (t in 1:N_TOPICS) {
    terms <- top_terms_per_topic %>% filter(topic == t) %>% pull(term)
    message(sprintf("    Topic %2d: %s", t, paste(terms, collapse=", ")))
  }

  write_export(top_terms_per_topic, "L05_topic_terms.csv")

  # ── Gamma ───────────────────────────────────────────────────────────────────
  topics_gamma <- tidy(lda_model, matrix = "gamma") %>%
    separate(document, into = c("source", "components"),
             sep = "_", extra = "merge", fill = "right") %>%
    mutate(source = case_when(
      str_detect(source, "Customer") ~ "Customer (LPP)",
      str_detect(source, "Internal") ~ "Internal (LPD)",
      TRUE ~ source
    ))

  topic_by_source <- topics_gamma %>%
    group_by(source, topic) %>%
    summarise(avg_gamma = mean(gamma), .groups = "drop") %>%
    group_by(source) %>%
    mutate(prop = round(avg_gamma / sum(avg_gamma) * 100, 1)) %>%
    ungroup() %>%
    mutate(period = run$label) %>%
    arrange(topic, source)

  write_export(topic_by_source, "L05_topic_by_source.csv")

  # ── Divergence ──────────────────────────────────────────────────────────────
  topic_divergence <- topic_by_source %>%
    select(topic, source, prop) %>%
    pivot_wider(names_from = source, values_from = prop, values_fill = 0) %>%
    rename(lpp_pct = `Customer (LPP)`, lpd_pct = `Internal (LPD)`) %>%
    mutate(
      difference     = round(lpp_pct - lpd_pct, 1),
      abs_difference = abs(difference),
      direction      = case_when(
        difference > 5  ~ "Customer-skewed",
        difference < -5 ~ "Internal-skewed",
        TRUE            ~ "Balanced"
      ),
      period = run$label
    ) %>%
    left_join(
      top_terms_per_topic %>%
        group_by(topic) %>%
        slice_max(beta, n = 5) %>%
        summarise(top_terms = paste(term, collapse=", "), .groups="drop"),
      by = "topic"
    ) %>%
    arrange(desc(abs_difference))

  write_export(topic_divergence, "L05_topic_divergence.csv")

  # ── Component topics ────────────────────────────────────────────────────────
  top_comp_list <- bugs %>%
    filter(!is.na(components), components != "") %>%
    count(components, sort = TRUE) %>%
    head(TOP_COMPONENTS) %>%
    pull(components)

  topic_by_component <- topics_gamma %>%
    filter(components %in% top_comp_list) %>%
    group_by(components, topic, source) %>%
    summarise(avg_gamma = round(mean(gamma), 3), .groups = "drop") %>%
    mutate(period = run$label) %>%
    arrange(components, source, topic)

  write_export(topic_by_component, "L05_topic_by_component.csv")

  # ── Bigrams ─────────────────────────────────────────────────────────────────
  bigrams <- bugs %>%
    select(source, full_text) %>%
    unnest_tokens(bigram, full_text, token = "ngrams", n = 2) %>%
    separate(bigram, into = c("word1", "word2"), sep = " ") %>%
    filter(!word1 %in% all_stops, !word2 %in% all_stops,
           !str_detect(word1, "^\\d+$"), !str_detect(word2, "^\\d+$"),
           nchar(word1) >= MIN_WORD_LEN, nchar(word2) >= MIN_WORD_LEN) %>%
    unite(bigram, word1, word2, sep = " ") %>%
    count(source, bigram, sort = TRUE) %>%
    group_by(source) %>%
    slice_max(n, n = 15) %>%
    ungroup() %>%
    mutate(period = run$label)

  write_export(bigrams, "L05_bigrams.csv")

  # ── Plots ───────────────────────────────────────────────────────────────────
  message("\n--- Generating plots ---")

  p_terms <- top_terms_per_topic %>%
    mutate(term = reorder_within(term, beta, topic)) %>%
    ggplot(aes(x=term, y=beta, fill=factor(topic))) +
    geom_col(show.legend=FALSE) +
    facet_wrap(~topic, scales="free", ncol=3) +
    coord_flip() + scale_x_reordered() +
    labs(title=sprintf("Topic Analysis: Top Terms — %s", run$title),
         subtitle=sprintf("%d hidden themes in bug reports", N_TOPICS),
         x=NULL, y="Term Probability (beta)") +
    theme_minimal(base_size=10) +
    theme(axis.text.y=element_text(size=8))
  save_plot(p_terms, "L05a_topic_terms.png", width=14, height=10)

  p_dist <- ggplot(topic_by_source,
                   aes(x=factor(topic), y=prop, fill=source)) +
    geom_col(position="dodge") +
    geom_text(aes(label=sprintf("%.1f%%", prop)),
              position=position_dodge(width=0.9), vjust=-0.4, size=3) +
    scale_fill_manual(values=c("Customer (LPP)"="#e8735a",
                                "Internal (LPD)"="#4ecdc4"), name=NULL) +
    labs(title=sprintf("Topic Distribution — %s", run$title),
         subtitle="Which themes dominate each bug source?",
         x="Topic", y="Percentage of Bugs (%)") +
    theme_minimal(base_size=11) + theme(legend.position="bottom")
  save_plot(p_dist, "L05b_topic_distribution.png", width=10, height=6)

  p_div <- topic_divergence %>%
    mutate(topic_label = paste0("Topic ", topic, "\n(",
                                str_trunc(top_terms, 30), ")"),
           fill_color  = ifelse(difference > 0, "Customer-skewed", "Internal-skewed")) %>%
    ggplot(aes(x=reorder(topic_label, difference), y=difference, fill=fill_color)) +
    geom_col() +
    geom_hline(yintercept=c(-5, 5), linetype="dashed", color="grey60", linewidth=0.5) +
    coord_flip() +
    scale_fill_manual(values=c("Customer-skewed"="#e8735a",
                                "Internal-skewed"="#4ecdc4"), name=NULL) +
    labs(title=sprintf("Topic Divergence — %s", run$title),
         subtitle="Positive = over-represented in customer bugs (testing gap)",
         x=NULL, y="Difference in % (LPP - LPD)") +
    theme_minimal(base_size=11) +
    theme(legend.position="bottom", axis.text.y=element_text(size=8))
  save_plot(p_div, "L05c_topic_divergence.png", width=12, height=7)

  for (src in c("Customer (LPP)", "Internal (LPD)")) {
    suffix <- ifelse(src == "Customer (LPP)", "lpp", "lpd")
    label  <- ifelse(src == "Customer (LPP)", "Customer (LPP)", "Internal (LPD)")
    p_comp <- topic_by_component %>%
      filter(source == src) %>%
      ggplot(aes(x=factor(topic), y=components, fill=avg_gamma)) +
      geom_tile(color="white", linewidth=0.4) +
      geom_text(aes(label=sprintf("%.2f", avg_gamma)),
                color="white", fontface="bold", size=2.8) +
      scale_fill_gradient2(low="#3498db", mid="#9b59b6", high="#e74c3c",
                           midpoint=0.5, name="Topic\nProbability") +
      labs(title=sprintf("Component Topics: %s — %s", label, run$title),
           x="Topic", y="Component") +
      theme_minimal(base_size=10) +
      theme(axis.text.y=element_text(size=8), panel.grid.major=element_blank())
    save_plot(p_comp, sprintf("L05d_component_topics_%s.png", suffix), width=12, height=8)
  }

  p_bigrams <- ggplot(bigrams,
                      aes(x=reorder_within(bigram, n, source), y=n, fill=source)) +
    geom_col(show.legend=FALSE) +
    facet_wrap(~source, scales="free") + coord_flip() + scale_x_reordered() +
    scale_fill_manual(values=c("Customer (LPP)"="#e8735a",
                                "Internal (LPD)"="#4ecdc4")) +
    labs(title=sprintf("Top 15 Two-Word Phrases — %s", run$title),
         x=NULL, y="Frequency") +
    theme_minimal(base_size=11) + theme(axis.text.y=element_text(size=9))
  save_plot(p_bigrams, "L05f_bigrams.png", width=14, height=8)

  # ── Run summary ─────────────────────────────────────────────────────────────
  under_covered <- topic_divergence %>% filter(difference > 5)
  message(sprintf("\n  ✅ Run '%s' complete — output: %s", run$label, dir_out))
  if (nrow(under_covered) > 0) {
    message(sprintf("  ⚠️  %d topics under-covered in internal testing:",
                    nrow(under_covered)))
    for (i in seq_len(nrow(under_covered))) {
      message(sprintf("    Topic %d (+%.1f%%): %s",
                      under_covered$topic[i], under_covered$difference[i],
                      under_covered$top_terms[i]))
    }
  }

  invisible(list(label=run$label, n_bugs=nrow(bugs), n_topics=N_TOPICS,
                 topic_divergence=topic_divergence))
}

# =============================================================================
# EXECUTE ALL RUNS
# =============================================================================
message(sprintf("\n  Running %d LDA configurations...", length(RUNS)))

results <- lapply(RUNS, run_lda)

message("\n=== ALL LDA RUNS COMPLETE ===")
message("Output structure:")
for (run in RUNS) {
  dir_out <- file.path(BASE_DIR, paste0("topics_", run$label))
  files   <- list.files(dir_out, recursive=TRUE, pattern="\\.csv$|\\.png$")
  message(sprintf("  topics_%s/ (%d files)", run$label, length(files)))
}
