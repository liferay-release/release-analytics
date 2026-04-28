-- =============================================================================
-- Migration 2.0 — Add subtask_id to fact_triage_results
--
-- Changes:
--   - Adds subtask_id BIGINT NULL on fact_triage_results
--   - Adds index on subtask_id for cluster-rollup queries
--   - Existing rows leave the column NULL (per-test classifier output)
--
-- Why:
--   Subtask-aware triage (--by-subtask) classifies once per Testray Subtask
--   and fans the verdict out to N case-rows in fact_triage_results. The new
--   column lets us re-collapse those rows by subtask for cluster-level
--   reporting and for the future MERGE-suggestion workflow (subtasks whose
--   classifications name overlapping culprit_files are candidates for a
--   single Jira ticket).
--
--   subtask_id is populated whenever the Testray testflow grouped the case
--   (read from r_subtaskToCaseResults_c_subtaskId on the caseresult object),
--   regardless of classifier mode. NULL when:
--     - the target build had no testflow / no subtask link, OR
--     - the run pre-dates this migration (existing rows), OR
--     - the target source was db/csv/tar (subtask field is api-only).
--
-- Run before: prepare.py with --by-subtask + the new submit.py fan-out path.
-- =============================================================================

-- fact_triage_results -------------------------------------------------------

ALTER TABLE fact_triage_results
  ADD COLUMN IF NOT EXISTS subtask_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_triage_subtask_id
  ON fact_triage_results (subtask_id)
  WHERE subtask_id IS NOT NULL;

-- Schema version -----------------------------------------------------------

INSERT INTO schema_version (version, notes) VALUES
  ('2.0', 'fact_triage_results — added nullable subtask_id BIGINT for testflow-aware triage (--by-subtask). NULL for per-test rows; populated when a Testray Subtask grouped the failure.')
ON CONFLICT (version) DO NOTHING;
