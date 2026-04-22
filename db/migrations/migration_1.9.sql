-- =============================================================================
-- Migration 1.9 — Add classifier column to fact_triage_results
--
-- Changes:
--   - Adds classifier VARCHAR(64) NOT NULL DEFAULT 'batch:v1'
--   - Backfills existing rows as 'batch:v1' (the original Anthropic-API batch)
--   - Drops unique constraint on (build_id_b, testray_case_id)
--   - Adds unique constraint on (build_id_b, testray_case_id, classifier)
--   - Enables head-to-head comparison between classifiers on the same build pair
--     (e.g. batch:v1 vs agent:claude-opus-4-7)
--
-- Also extends triage_run_log with classifier so the same comparison is
-- possible at run granularity.
--
-- Run before: submit.py (new) — which writes classifier='agent:*' rows
-- =============================================================================

-- fact_triage_results -------------------------------------------------------

ALTER TABLE fact_triage_results
  ADD COLUMN IF NOT EXISTS classifier VARCHAR(64) NOT NULL DEFAULT 'batch:v1';

ALTER TABLE fact_triage_results
  DROP CONSTRAINT IF EXISTS fact_triage_results_build_id_b_testray_case_id_key;

ALTER TABLE fact_triage_results
  ADD CONSTRAINT fact_triage_results_build_b_case_classifier_key
  UNIQUE (build_id_b, testray_case_id, classifier);

CREATE INDEX IF NOT EXISTS idx_triage_classifier
  ON fact_triage_results (classifier);

-- triage_run_log -----------------------------------------------------------

ALTER TABLE triage_run_log
  ADD COLUMN IF NOT EXISTS classifier VARCHAR(64) NOT NULL DEFAULT 'batch:v1';

CREATE INDEX IF NOT EXISTS idx_triage_run_log_classifier
  ON triage_run_log (classifier);

-- Schema version -----------------------------------------------------------

INSERT INTO schema_version (version, notes) VALUES
  ('1.9', 'fact_triage_results + triage_run_log — added classifier column (batch:v1 default); unique key now (build_id_b, testray_case_id, classifier)')
ON CONFLICT (version) DO NOTHING;
