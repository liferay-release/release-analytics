# =============================================================================
# export_looker.R
# Exports all data needed for Looker Studio dashboards as CSVs.
# Drop the output CSVs into Google Sheets — one tab per file.
#
# Outputs two sets of files:
#
#   RELEASE SITUATION DECK (pre-release, per-release cadence)
#   exports/looker/situation_deck/
#     01_forecast_by_component.csv
#     02_churn_by_component.csv
#     03_churn_by_team.csv
#     04_test_health_by_component.csv
#     05_test_health_by_team.csv
#     06_dim_releases.csv
#
#   RELEASE LANDSCAPE REPORT (retrospective, quarterly cadence)
#   exports/looker/landscape_report/
#     (populated once LDA and complexity transforms are built)
#
# Google Sheets import:
#   File > Import > Upload > Replace current sheet (for each CSV)
#   Or use the Sheets API if you want to automate later.
#
# Run after: transform_forecast_input.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(DBI)
  library(yaml)
  library(lubridate)
  library(MASS)
  library(pscl)
  library(randomForest)
})

source("config/release_analytics_db.R")
options(scipen = 999)

# =============================================================================
# SETUP
# =============================================================================
message("\n=== EXPORT: Looker Studio CSVs ===")

con <- get_db_connection(
  config_path = "config/config.yml"
)
on.exit(dbDisconnect(con), add = TRUE)

# Output directories
dir_situation  <- "reports/situation_deck/exports"
dir_landscape  <- "reports/release_landscape/exports"
dir.create(dir_situation,  recursive = TRUE, showWarnings = FALSE)
dir.create(dir_landscape,  recursive = TRUE, showWarnings = FALSE)

write_export <- function(df, dir, filename) {
  path <- file.path(dir, filename)
  write_csv(df, path)
  message(sprintf("  ✓ %s (%d rows)", filename, nrow(df)))
  invisible(path)
}

# =============================================================================
# SHARED LOOKUP: release metadata
# =============================================================================
releases <- dbGetQuery(con, "
  SELECT
    release_label,
    quarter_label,
    release_date,
    is_major_release,
    is_lts,
    release_status,
    git_tag,
    COALESCE(
      ROUND((CURRENT_DATE - release_date) / 30.0)::INT, 3
    ) AS months_in_field
  FROM dim_release
  ORDER BY COALESCE(release_date, '9999-12-31'), release_label
")

# =============================================================================
# 01. FORECAST BY COMPONENT
# Pre-release risk scores per component for the active/forecast quarter.
# Includes LPP historical risk, LPD prediction inputs, and churn signals.
# Looker use: risk heat map, top components chart, component drilldown table.
# =============================================================================
message("\n--- 01 forecast_by_component ---")

forecast_by_component <- dbGetQuery(con, "
  SELECT
    fi.quarter,
    dr.quarter_label,
    dr.release_date,
    dr.is_major_release,
    dr.is_lts,
    dr.release_status,
    COALESCE(ROUND((CURRENT_DATE - dr.release_date) / 30.0)::INT, 3) AS months_in_field,
    dc.component_name     AS component,
    dc.team_name          AS team,
    fi.lpp_count          AS lpp_actual,
    fi.lpd_count          AS lpd_actual,
    fi.story_count        AS stories,
    fi.blocker_count,
    fi.backend_changes,
    fi.frontend_changes,
    fi.total_churn,
    fi.java_insertions,
    fi.java_deletions,
    fi.tsx_insertions,
    fi.tsx_deletions,
    fi.breaking_changes,
    fi.java_file_count,
    fi.java_lines_of_code,
    fi.is_forecast_row
  FROM fact_forecast_input fi
  JOIN dim_component dc ON dc.component_id = fi.component_id
  JOIN dim_release   dr ON dr.release_label = fi.quarter
  WHERE fi.quarter LIKE '%.Q%'
  ORDER BY dr.release_date NULLS LAST, dc.component_name
") %>%
  # Compute legacy baselines (2024 average per component)
  group_by(component) %>%
  mutate(
    legacy_lpp_avg = mean(lpp_actual[grepl("2024", quarter)], na.rm = TRUE),
    legacy_lpd_avg = mean(lpd_actual[grepl("2024", quarter)], na.rm = TRUE)
  ) %>%
  ungroup() %>%
  mutate(
    legacy_lpp_avg = ifelse(is.nan(legacy_lpp_avg), NA_real_, legacy_lpp_avg),
    legacy_lpd_avg = ifelse(is.nan(legacy_lpd_avg), NA_real_, legacy_lpd_avg),
    # LPP historical risk score (0-100 percentile)
    lpp_hist_score = {
      cs <- log1p(backend_changes) + 0.5 * log1p(frontend_changes)
      ll <- coalesce(legacy_lpp_avg, median(legacy_lpp_avg, na.rm = TRUE))
      z_l <- (ll - mean(ll, na.rm = TRUE)) / max(sd(ll, na.rm = TRUE), 1e-6)
      z_c <- (cs - mean(cs, na.rm = TRUE)) / max(sd(cs, na.rm = TRUE), 1e-6)
      round(percent_rank(0.6 * z_l + 0.4 * z_c) * 100, 1)
    },
    lpp_risk_level = cut(lpp_hist_score,
      breaks = c(-Inf, 20, 40, 60, 80, Inf),
      labels = c("Very Low", "Low", "Medium", "High", "Very High")
    )
  )


# =============================================================================
# LPD FORECAST MODEL
# Trains on mature Q releases (months_in_field >= 9, excluding forecast quarter)
# Selects best model by R² on validation quarter
# Appends lpd_pred, lpd_risk_level, risk_score, overall_risk to export
# =============================================================================
message("\n--- Training LPD forecast model ---")

MIN_MONTHS  <- 9
FORECAST_Q  <- releases$release_label[releases$release_status == "IN_DEVELOPMENT" &
                                       grepl("\\.Q", releases$release_label)]
if (length(FORECAST_Q) == 0) {
  FORECAST_Q <- releases$release_label[which.max(releases$release_date)]
}
FORECAST_Q <- FORECAST_Q[1]
message(sprintf("  Forecast target: %s", FORECAST_Q))

# Split
mature_q <- releases %>%
  filter(
    grepl("\\.Q", release_label),
    release_label != FORECAST_Q,
    !is.na(release_date),
    months_in_field >= MIN_MONTHS
  ) %>%
  arrange(release_date) %>%
  pull(release_label)

train_q <- head(mature_q, -1)
valid_q <- tail(mature_q,  1)
message(sprintf("  Training: %s", paste(train_q, collapse=", ")))
message(sprintf("  Validation: %s", valid_q))

# Prepare model data
model_data <- forecast_by_component %>%
  filter(quarter %in% c(train_q, valid_q, FORECAST_Q)) %>%
  mutate(
    log_months       = log(pmax(months_in_field, 1)),
    legacy_lpp_avg_f = coalesce(legacy_lpp_avg, median(legacy_lpp_avg, na.rm=TRUE)),
    legacy_lpd_avg_f = coalesce(legacy_lpd_avg, median(legacy_lpd_avg, na.rm=TRUE)),
    has_legacy_data  = as.integer(!is.na(legacy_lpp_avg))
  )

td <- model_data %>%
  filter(quarter %in% train_q) %>%
  rename(LPD=lpd_actual, Stories=stories,
         backend=backend_changes, frontend=frontend_changes)

vd <- model_data %>%
  filter(quarter == valid_q) %>%
  rename(LPD=lpd_actual, Stories=stories,
         backend=backend_changes, frontend=frontend_changes)

fd <- model_data %>%
  filter(quarter == FORECAST_Q) %>%
  mutate(log_months=log(3), is_major_release=1L, is_lts=1L) %>%
  rename(LPD=lpd_actual, Stories=stories,
         backend=backend_changes, frontend=frontend_changes)

soft_cap <- function(p, mx, m=3) pmin(p, mx*m)
get_r2   <- function(act, pred) 1 - sum((act-pred)^2)/sum((act-mean(act))^2)

form_lpd <- LPD ~ legacy_lpd_avg_f + Stories + log1p(backend) + log1p(frontend) +
            is_major_release + is_lts + has_legacy_data + is_major_release:Stories

max_lpd <- max(td$LPD, na.rm=TRUE)

m_nb <- tryCatch(glm.nb(update(form_lpd,.~.+offset(log_months)), data=td), error=function(e) NULL)
m_qp <- tryCatch(glm(update(form_lpd,.~.+offset(log_months)), data=td, family="quasipoisson"), error=function(e) NULL)
m_rf <- tryCatch(
  randomForest(LPD ~ months_in_field + legacy_lpd_avg_f + Stories + backend + frontend +
               is_major_release + is_lts + has_legacy_data,
               data=td, ntree=500),
  error=function(e) NULL
)

pred_v <- function(m, is_rf=FALSE) {
  if (is.null(m)) return(rep(NA_real_, nrow(vd)))
  if (is_rf) predict(m, newdata=vd)
  else soft_cap(predict(m, newdata=vd, type="response"), max_lpd)
}

r2s <- c(
  NegBin        = tryCatch(get_r2(vd$LPD, pred_v(m_nb)), error=function(e) NA),
  `Quasi-Poisson`= tryCatch(get_r2(vd$LPD, pred_v(m_qp)), error=function(e) NA),
  `Random Forest`= tryCatch(get_r2(vd$LPD, pred_v(m_rf, TRUE)), error=function(e) NA)
)
r2s <- r2s[!is.na(r2s)]

best_name  <- names(which.max(r2s))
best_r2    <- round(max(r2s, na.rm=TRUE), 3)
best_model <- switch(best_name, "NegBin"=m_nb, "Quasi-Poisson"=m_qp, "Random Forest"=m_rf)
message(sprintf("  Best LPD model: %s (R²=%.3f)", best_name, best_r2))

# Calibration
lpd_vp   <- if(best_name=="Random Forest") predict(best_model,newdata=vd) else
              soft_cap(predict(best_model,newdata=vd,type="response"),max_lpd)
lpd_bias <- (mean(vd$LPD) - mean(lpd_vp)) / mean(vd$LPD) * 100
lpd_cal  <- if(abs(lpd_bias) > 20) mean(vd$LPD) / mean(lpd_vp) else 1.0

# Predictions for forecast quarter
lpd_preds <- (if(best_name=="Random Forest") predict(best_model,newdata=fd) else
               soft_cap(predict(best_model,newdata=fd,type="response"),max_lpd)) * lpd_cal

risk_label <- function(pct) as.character(cut(pct,
  breaks=c(-Inf,20,40,60,80,Inf),
  labels=c("Very Low","Low","Medium","High","Very High")))

# Build prediction results to join back
pred_results <- fd %>%
  mutate(
    lpd_pred      = round(lpd_preds, 2),
    lpd_pct       = round(percent_rank(lpd_preds) * 100, 1),
    lpd_risk_level= risk_label(lpd_pct),
    risk_score    = round(lpp_hist_score + lpd_pct, 1),
    overall_risk  = risk_label(percent_rank(lpp_hist_score + lpd_pct) * 100),
    model_name    = best_name,
    model_r2      = best_r2,
    model_cal     = round(lpd_cal, 3),
    model_mae     = round(mean(abs(vd$LPD - lpd_vp)), 2),
    validated_on  = valid_q
  ) %>%
  select(quarter, component,
         lpd_pred, lpd_pct, lpd_risk_level,
         risk_score, overall_risk,
         model_name, model_r2, model_cal, model_mae, validated_on)

# Merge predictions back into forecast_by_component
# For non-forecast quarters, predictions are NA (historical actual data is used instead)
forecast_by_component <- forecast_by_component %>%
  left_join(pred_results, by = c("quarter", "component")) %>%
  mutate(
    # For historical quarters, compute risk score from actuals for trend context
    lpd_pred      = ifelse(is.na(lpd_pred) & quarter != FORECAST_Q,
                           lpd_actual, lpd_pred),
    lpd_pct       = ifelse(is.na(lpd_pct),
                           round(percent_rank(lpd_actual) * 100, 1), lpd_pct),
    lpd_risk_level= ifelse(is.na(lpd_risk_level),
                           risk_label(lpd_pct), lpd_risk_level),
    risk_score    = ifelse(is.na(risk_score),
                           round(coalesce(lpp_hist_score, 0) + lpd_pct, 1), risk_score),
    overall_risk  = ifelse(is.na(overall_risk),
                           risk_label(percent_rank(risk_score) * 100), overall_risk)
  )

message(sprintf("  LPD predictions appended for %s (%d components)", 
                FORECAST_Q, sum(!is.na(pred_results$lpd_pred))))

write_export(forecast_by_component, dir_situation, "S01_forecast_by_component.csv")

# =============================================================================
# 02. CHURN BY COMPONENT
# All quarters including U releases — for trend analysis in Looker.
# Looker use: churn trend lines, U vs Q comparison, in-development risk view.
# =============================================================================
message("\n--- 02 churn_by_component ---")

churn_by_component <- dbGetQuery(con, "
  SELECT
    fi.quarter,
    dr.quarter_label,
    dr.release_date,
    dr.is_major_release,
    dr.is_lts,
    dr.release_status,
    dc.component_name     AS component,
    dc.team_name          AS team,
    fi.backend_changes,
    fi.frontend_changes,
    fi.total_churn,
    fi.java_insertions,
    fi.java_deletions,
    fi.java_modified_files,
    fi.tsx_insertions,
    fi.tsx_deletions,
    fi.tsx_modified_files,
    fi.js_insertions,
    fi.js_deletions,
    fi.jsp_insertions,
    fi.jsp_deletions,
    fi.ts_insertions,
    fi.ts_deletions,
    fi.scss_insertions,
    fi.scss_deletions,
    fi.css_insertions,
    fi.css_deletions,
    fi.java_file_count,
    fi.java_lines_of_code,
    fi.tsx_file_count,
    fi.tsx_lines_of_code,
    fi.breaking_changes,
    fi.is_forecast_row
  FROM fact_forecast_input fi
  JOIN dim_component dc ON dc.component_id = fi.component_id
  JOIN dim_release   dr ON dr.release_label = fi.quarter
  ORDER BY dr.release_date NULLS LAST, dc.component_name
")

write_export(churn_by_component, dir_situation, "S02_churn_by_component.csv")

# =============================================================================
# 03. CHURN BY TEAM
# Rolled up from component to team per quarter.
# Looker use: team-level churn bar chart, quarter-over-quarter trend.
# =============================================================================
message("\n--- 03 churn_by_team ---")

churn_by_team <- churn_by_component %>%
  filter(!is.na(team)) %>%
  group_by(quarter, quarter_label, release_date, is_major_release,
           is_lts, release_status, team) %>%
  summarise(
    n_components       = n(),
    total_backend      = sum(backend_changes,  na.rm = TRUE),
    total_frontend     = sum(frontend_changes, na.rm = TRUE),
    total_churn        = sum(total_churn,       na.rm = TRUE),
    total_java_ins     = sum(java_insertions,   na.rm = TRUE),
    total_tsx_ins      = sum(tsx_insertions,    na.rm = TRUE),
    total_breaking     = sum(breaking_changes,  na.rm = TRUE),
    avg_churn_per_comp = round(mean(total_churn, na.rm = TRUE), 1),
    .groups = "drop"
  ) %>%
  arrange(release_date, team)

write_export(churn_by_team, dir_situation, "S03_churn_by_team.csv")

# =============================================================================
# 04. TEST HEALTH BY COMPONENT
# From fact_test_quality — bug catch rate and signal score per component.
# Looker use: test effectiveness table, catch rate vs failure rate scatter.
# =============================================================================
message("\n--- 04 test_health_by_component ---")

test_health_by_component <- dbGetQuery(con, "
  SELECT
    tq.component_name     AS component,
    tq.team_name          AS team,
    tq.case_type,
    COUNT(DISTINCT tq.case_id)            AS n_test_cases,
    SUM(tq.total_fail_builds)             AS total_failures,
    SUM(tq.bug_linked_builds)             AS bug_linked_failures,
    SUM(tq.distinct_bugs_linked)          AS distinct_bugs_linked,
    ROUND(AVG(tq.bug_catch_rate)::NUMERIC, 4) AS avg_bug_catch_rate,
    ROUND(AVG(tq.signal_score)::NUMERIC, 4)   AS avg_signal_score,
    -- Failure rate: what proportion of builds fail
    CASE
      WHEN SUM(tq.total_fail_builds) > 0
        THEN ROUND(
          SUM(tq.bug_linked_builds)::NUMERIC /
          SUM(tq.total_fail_builds), 4)
      ELSE 0
    END AS bug_link_rate,
    MAX(tq.calculated_at) AS last_calculated
  FROM fact_test_quality tq
  GROUP BY tq.component_name, tq.team_name, tq.case_type
  ORDER BY total_failures DESC
")

write_export(test_health_by_component, dir_situation, "S04_test_health_by_component.csv")

# =============================================================================
# 05. TEST HEALTH BY TEAM
# Rolled up from component to team.
# Looker use: team test health scorecard, catch rate league table.
# =============================================================================
message("\n--- 05 test_health_by_team ---")

test_health_by_team <- dbGetQuery(con, "
  SELECT
    tq.team_name          AS team,
    tq.case_type,
    COUNT(DISTINCT tq.case_id)              AS n_test_cases,
    COUNT(DISTINCT tq.component_name)       AS n_components,
    SUM(tq.total_fail_builds)               AS total_failures,
    SUM(tq.bug_linked_builds)               AS bug_linked_failures,
    SUM(tq.distinct_bugs_linked)            AS distinct_bugs_linked,
    ROUND(AVG(tq.bug_catch_rate)::NUMERIC, 4)   AS avg_bug_catch_rate,
    ROUND(AVG(tq.signal_score)::NUMERIC, 4)     AS avg_signal_score,
    -- High signal tests: signal_score > 0.1
    COUNT(CASE WHEN tq.signal_score > 0.1 THEN 1 END) AS high_signal_tests,
    -- Zero catch tests: never linked to a bug
    COUNT(CASE WHEN tq.bug_catch_rate = 0 THEN 1 END) AS zero_catch_tests,
    ROUND(
      COUNT(CASE WHEN tq.bug_catch_rate = 0 THEN 1 END)::NUMERIC /
      NULLIF(COUNT(DISTINCT tq.case_id), 0) * 100, 1
    ) AS pct_zero_catch,
    MAX(tq.calculated_at) AS last_calculated
  FROM fact_test_quality tq
  GROUP BY tq.team_name, tq.case_type
  ORDER BY total_failures DESC
")

write_export(test_health_by_team, dir_situation, "S05_test_health_by_team.csv")

# =============================================================================
# 06. DIM RELEASES
# Full release registry for Looker date filters and release selectors.
# Looker use: release filter control, quarter selector, timeline axis.
# =============================================================================
message("\n--- 06 dim_releases ---")

write_export(releases, dir_situation, "S06_dim_releases.csv")


# =============================================================================
# 07. TEAM SCORECARD
# Aggregates forecast_by_component to team level.
# Combines bug counts, blocker counts, churn, and model predictions.
# Looker use: team-level scorecard, testing effectiveness quadrant.
# =============================================================================
message("\n--- 07 team_scorecard ---")

team_scorecard <- forecast_by_component %>%
  filter(!is.na(team), quarter == FORECAST_Q) %>%
  group_by(team) %>%
  summarise(
    n_components    = n(),
    # Bug counts
    lpp_count       = sum(lpp_actual,     na.rm = TRUE),
    lpd_count       = sum(lpd_actual,     na.rm = TRUE),
    blocker_count   = sum(blocker_count,  na.rm = TRUE),
    # LPD forecast
    lpd_predicted   = round(sum(lpd_pred, na.rm = TRUE), 0),
    # Churn
    total_churn     = sum(total_churn,    na.rm = TRUE),
    backend_churn   = sum(backend_changes,na.rm = TRUE),
    frontend_churn  = sum(frontend_changes,na.rm=TRUE),
    # Risk
    avg_risk_score  = round(mean(risk_score, na.rm = TRUE), 1),
    n_high_risk     = sum(overall_risk %in% c("High", "Very High"), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  # Join test health — Acceptance tests (Automated Functional Test)
  left_join(
    test_health_by_team %>%
      filter(case_type == "Automated Functional Test") %>%
      select(team, acceptance_cases = n_test_cases,
             acceptance_failures    = total_failures,
             acceptance_catch_rate  = avg_bug_catch_rate,
             acceptance_signal      = avg_signal_score,
             acceptance_pct_zero    = pct_zero_catch),
    by = "team"
  ) %>%
  # Join test health — Release tests (Modules Integration Test)
  left_join(
    test_health_by_team %>%
      filter(case_type == "Modules Integration Test") %>%
      select(team, release_cases    = n_test_cases,
             release_failures       = total_failures,
             release_catch_rate     = avg_bug_catch_rate,
             release_signal         = avg_signal_score,
             release_pct_zero       = pct_zero_catch),
    by = "team"
  ) %>%
  mutate(
    release_label = FORECAST_Q,
    # Testing effectiveness signal — for quadrant analysis in Looker
    # High LPP + High pass rate = not testing right things
    # High LPD + Low LPP = catching before customers (good)
    # High blockers + High release pass rate = not testing right things
    lpp_lpd_ratio = round(ifelse(lpd_count > 0, lpp_count / lpd_count, NA_real_), 2),
    blocker_rate  = round(ifelse(lpd_count > 0, blocker_count / lpd_count * 100, 0), 1)
  ) %>%
  arrange(desc(avg_risk_score))

write_export(team_scorecard, dir_situation, "S07_team_scorecard.csv")

# =============================================================================
# RELEASE LANDSCAPE REPORT — Jira-based analyses
# All three pull from raw_jira_issues.rds — load once, export three ways
# =============================================================================
message("\n=== RELEASE LANDSCAPE EXPORTS ===")

jira_path <- "staging/raw_jira_issues.rds"
if (!file.exists(jira_path)) {
  message("  WARNING: raw_jira_issues.rds not found — skipping landscape exports")
  message("  Run extract_jira.R first")
} else {

  jira_raw <- readRDS(jira_path)
  message(sprintf("  Loaded %d Jira issues", nrow(jira_raw)))

  # Dev window lookup (same as transform_forecast_input.R)
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

  # Assign quarters
  jira <- jira_raw %>%
    mutate(
      quarter = case_when(
        project == "LPP" & !is.na(quarter_lpp) & quarter_lpp >= "2024.Q1" ~ quarter_lpp,
        project == "LPP" & is.na(quarter_lpp) ~ date_to_dev_quarter(resolution_date, dev_windows),
        project == "LPD" ~ date_to_dev_quarter(created_date, dev_windows),
        TRUE ~ NA_character_
      )
    ) %>%
    filter(!is.na(quarter), quarter >= "2024.Q1")

  # ---------------------------------------------------------------------------
  # L01. SEVERITY DISTRIBUTION
  # LPP vs LPD severity breakdown — are we catching high-priority bugs internally?
  # ---------------------------------------------------------------------------
  message("\n--- L01 severity_distribution ---")

  severity_distribution <- jira %>%
    mutate(
      severity_label = case_when(
        project == "LPP" ~ coalesce(priority_raw, "Unknown"),
        project == "LPD" ~ case_when(
          severity_score == 5 ~ "Fire",
          severity_score == 4 ~ "Critical",
          severity_score == 3 ~ "High",
          severity_score == 2 ~ "Medium",
          severity_score == 1 ~ "Low",
          TRUE ~ "Unknown"
        )
      ),
      severity_order = case_when(
        severity_label == "Fire"     ~ 1,
        severity_label == "Critical" ~ 2,
        severity_label == "High"     ~ 3,
        severity_label == "Medium"   ~ 4,
        severity_label == "Low"      ~ 5,
        TRUE                         ~ 6
      )
    ) %>%
    count(project, quarter, severity_label, severity_order) %>%
    group_by(project, quarter) %>%
    mutate(
      total      = sum(n),
      pct        = round(n / total * 100, 1)
    ) %>%
    ungroup() %>%
    arrange(quarter, project, severity_order)

  write_export(severity_distribution, dir_landscape, "L01_severity_distribution.csv")

  # ---------------------------------------------------------------------------
  # L02. BUG DISCOVERY TIMING
  # For matched LPP/LPD pairs on the same component+quarter:
  # did internal testing find the issue before the customer did?
  # ---------------------------------------------------------------------------
  message("\n--- L02 bug_discovery_timing ---")

  # Component-level: compare earliest LPP and LPD dates per component+quarter
  lpp_dates <- jira %>%
    filter(project == "LPP") %>%
    group_by(quarter, components) %>%
    summarise(first_lpp_date = min(created_date, na.rm = TRUE),
              lpp_count = n(), .groups = "drop")

  lpd_dates <- jira %>%
    filter(project == "LPD") %>%
    group_by(quarter, components) %>%
    summarise(first_lpd_date = min(created_date, na.rm = TRUE),
              lpd_count = n(), .groups = "drop")

  bug_discovery_timing <- lpp_dates %>%
    inner_join(lpd_dates, by = c("quarter", "components")) %>%
    mutate(
      days_diff        = as.integer(first_lpp_date - first_lpd_date),
      # Positive = customer found first (BAD), Negative = internal found first (GOOD)
      found_first_by   = case_when(
        days_diff > 0  ~ "Customer (LPP)",
        days_diff < 0  ~ "Internal (LPD)",
        days_diff == 0 ~ "Same day"
      ),
      internal_caught_first = days_diff <= 0
    ) %>%
    arrange(quarter, days_diff)

  # Summary by quarter
  timing_summary <- bug_discovery_timing %>%
    group_by(quarter) %>%
    summarise(
      n_components          = n(),
      pct_internal_first    = round(mean(internal_caught_first) * 100, 1),
      avg_days_diff         = round(mean(days_diff, na.rm = TRUE), 1),
      median_days_diff      = median(days_diff, na.rm = TRUE),
      .groups = "drop"
    )

  write_export(bug_discovery_timing, dir_landscape, "L02_bug_discovery_timing.csv")
  write_export(timing_summary,       dir_landscape, "L02_bug_discovery_summary.csv")

  # ---------------------------------------------------------------------------
  # L03. BLIND SPOT ANALYSIS
  # Terms appearing disproportionately in LPP vs LPD summaries.
  # High LPP proportion difference = customers reporting things QE isn't catching.
  # ---------------------------------------------------------------------------
  message("\n--- L03 blind_spot_analysis ---")

  if (!requireNamespace("tidytext", quietly = TRUE)) {
    message("  Installing tidytext...")
    install.packages("tidytext", quiet = TRUE)
  }
  library(tidytext)

  # Custom stopwords for Liferay context
  custom_stops <- c(
    "liferay", "portal", "dxp", "lps", "lpp", "lpd",
    "https", "http", "com", "www", "org",
    "1", "2", "3", "0", "10", "true", "false", "null",
    stop_words$word
  )

  word_freq <- jira %>%
    filter(!is.na(summary), summary != "") %>%
    select(project, quarter, summary) %>%
    unnest_tokens(word, summary) %>%
    filter(!word %in% custom_stops, nchar(word) > 2) %>%
    count(project, word) %>%
    group_by(project) %>%
    mutate(proportion = n / sum(n)) %>%
    ungroup()

  lpp_words <- word_freq %>% filter(project == "LPP") %>%
    select(word, lpp_n = n, lpp_prop = proportion)
  lpd_words <- word_freq %>% filter(project == "LPD") %>%
    select(word, lpd_n = n, lpd_prop = proportion)

  blind_spots <- lpp_words %>%
    full_join(lpd_words, by = "word") %>%
    mutate(
      lpp_prop = coalesce(lpp_prop, 0),
      lpd_prop = coalesce(lpd_prop, 0),
      lpp_n    = coalesce(lpp_n, 0L),
      lpd_n    = coalesce(lpd_n, 0L),
      prop_diff_lpp_minus_lpd = round(lpp_prop - lpd_prop, 6),
      prop_diff_lpd_minus_lpp = round(lpd_prop - lpp_prop, 6),
      # Words appearing MORE in customer bugs = potential blind spots
      blind_spot_type = case_when(
        prop_diff_lpp_minus_lpd > 0.001 ~ "Customer only",
        prop_diff_lpd_minus_lpp > 0.001 ~ "Internal only",
        TRUE                            ~ "Shared"
      )
    ) %>%
    filter(lpp_n + lpd_n >= 5) %>%   # minimum frequency threshold
    arrange(desc(prop_diff_lpp_minus_lpd))

  write_export(blind_spots, dir_landscape, "L03_blind_spot_analysis.csv")

  message(sprintf("\n  Landscape exports complete"))
  message(sprintf("  Landscape CSVs: %s", dir_landscape))
  for (f in list.files(dir_landscape, pattern = "\\.csv$")) {
    size <- file.size(file.path(dir_landscape, f))
    message(sprintf("    %-45s %s KB", f, round(size/1024, 1)))
  }
}

# =============================================================================
# L04. COMPLEXITY BY COMPONENT
# From fact_file_complexity — weighted by dim_module_component_map.weight
# to handle multi-mapped modules (e.g. Commerce maps to 4 components).
# Looker use: complexity heatmap, tech debt ranking, violation breakdown.
# =============================================================================
message("\n--- L04 complexity_by_component ---")

complexity_by_component <- dbGetQuery(con, "
  SELECT
    dc.component_name     AS component,
    dc.team_name          AS team,
    COUNT(DISTINCT df.file_id)                                        AS n_files,
    ROUND(AVG(fc.cyclomatic_complexity)::NUMERIC, 1)                  AS avg_cyclomatic,
    ROUND(AVG(fc.cognitive_complexity)::NUMERIC, 1)                   AS avg_cognitive,
    -- Weight LOC and violations to avoid double-counting multi-mapped modules
    ROUND(SUM(fc.lines_of_code          * mcm.weight)::NUMERIC, 0)   AS weighted_loc,
    ROUND(SUM(fc.violation_count        * mcm.weight)::NUMERIC, 0)   AS weighted_violations,
    ROUND(SUM(fc.violation_blocker_count  * mcm.weight)::NUMERIC, 0) AS weighted_blocker_violations,
    ROUND(SUM(fc.violation_critical_count * mcm.weight)::NUMERIC, 0) AS weighted_critical_violations,
    ROUND(SUM(fc.tech_debt_minutes      * mcm.weight) / 60.0, 1)     AS weighted_tech_debt_hours,
    -- Complexity risk score: weighted combination of cyclomatic + violations + debt
    ROUND((
      0.4 * PERCENT_RANK() OVER (ORDER BY AVG(fc.cyclomatic_complexity)) +
      0.3 * PERCENT_RANK() OVER (ORDER BY SUM(fc.violation_count * mcm.weight)) +
      0.3 * PERCENT_RANK() OVER (ORDER BY SUM(fc.tech_debt_minutes * mcm.weight))
    )::NUMERIC * 100, 1)                                              AS complexity_risk_pct,
    MAX(fc.snapshot_date)                                             AS snapshot_date
  FROM fact_file_complexity fc
  JOIN dim_file df ON df.file_id = fc.file_id
  JOIN dim_module_component_map mcm
    ON mcm.module_path = REGEXP_REPLACE(
         df.file_path, '^(modules/[^/]+/[^/]+).*', '\\1')
  JOIN dim_component dc ON dc.component_id = mcm.component_id
  WHERE df.file_path LIKE 'modules/%'
  GROUP BY dc.component_name, dc.team_name
  ORDER BY weighted_tech_debt_hours DESC
")

write_export(complexity_by_component, dir_landscape, "L04_complexity_by_component.csv")

# Team-level rollup
complexity_by_team <- complexity_by_component %>%
  filter(!is.na(team)) %>%
  group_by(team) %>%
  summarise(
    n_components              = n(),
    total_files               = sum(n_files,                    na.rm = TRUE),
    avg_cyclomatic            = round(mean(avg_cyclomatic,      na.rm = TRUE), 1),
    avg_cognitive             = round(mean(avg_cognitive,       na.rm = TRUE), 1),
    total_loc                 = sum(weighted_loc,               na.rm = TRUE),
    total_violations          = sum(weighted_violations,        na.rm = TRUE),
    total_blocker_violations  = sum(weighted_blocker_violations,na.rm = TRUE),
    total_critical_violations = sum(weighted_critical_violations,na.rm=TRUE),
    total_tech_debt_hours     = round(sum(weighted_tech_debt_hours, na.rm=TRUE), 1),
    avg_complexity_risk       = round(mean(complexity_risk_pct, na.rm = TRUE), 1),
    .groups = "drop"
  ) %>%
  arrange(desc(total_tech_debt_hours))

write_export(complexity_by_team, dir_landscape, "L04_complexity_by_team.csv")

# =============================================================================
# SUMMARY
# =============================================================================
message("\n=== EXPORT COMPLETE ===")
message(sprintf("  Situation Deck CSVs: %s", dir_situation))
message("  Files:")
for (f in list.files(dir_situation, pattern = "\\.csv$")) {
  size <- file.size(file.path(dir_situation, f))
  message(sprintf("    %-45s %s KB", f, round(size/1024, 1)))
}

message("\n  Next steps:")
message("  1. Open your Google Sheet")
message("  2. For each CSV: File > Import > Upload > Insert new sheet")
message("  3. Name each sheet to match the filename (minus the number prefix)")
message("  4. Connect each sheet as a data source in Looker Studio")
message("  5. Join on 'component' or 'team' as needed")
message(sprintf("  Landscape CSVs: %s", dir_landscape))
message("\n✅ export_looker.R complete")
