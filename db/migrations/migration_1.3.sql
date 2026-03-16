-- =============================================================================
-- Schema Version 1.3 — Dashboard & Release Intelligence Layer
--
-- Adds:
--   - dim_release
--   - fact_static_diff
--   - fact_release_complexity
--   - fact_lda_topics
--   - fact_bug_forecast
--   - routine_name column to fact_test_failure
-- =============================================================================

-- -----------------------------------------------------------------------------
-- dim_release — release identity, referenced by all dashboard fact tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_release (
    release_id      SERIAL PRIMARY KEY,
    release_label   VARCHAR(20) NOT NULL UNIQUE,  -- e.g. 'U148'
    hash_from       VARCHAR(40) NOT NULL,
    hash_to         VARCHAR(40) NOT NULL,
    release_date    DATE,
    notes           TEXT,
    created_at      TIMESTAMP DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- fact_static_diff — hash-to-hash churn per file, appended each release
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_static_diff (
    diff_id         SERIAL PRIMARY KEY,
    release_id      INT NOT NULL REFERENCES dim_release(release_id),
    file_id         INT REFERENCES dim_file(file_id),
    file_path       VARCHAR(500) NOT NULL,
    module_id       INT REFERENCES dim_module(module_id),
    lines_added     INT DEFAULT 0,
    lines_deleted   INT DEFAULT 0,
    files_changed   INT DEFAULT 0,
    unique_authors  INT DEFAULT 0,
    change_type     VARCHAR(10) CHECK (change_type IN ('MODIFIED', 'ADDED', 'DELETED', 'RENAMED')),
    calculated_at   TIMESTAMP DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- fact_release_complexity — SonarQube snapshot pinned to a release hash
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_release_complexity (
    release_complexity_id       SERIAL PRIMARY KEY,
    release_id                  INT NOT NULL REFERENCES dim_release(release_id),
    file_id                     INT NOT NULL REFERENCES dim_file(file_id),
    module_id                   INT REFERENCES dim_module(module_id),
    cyclomatic_complexity       NUMERIC(10,2) DEFAULT 0,
    cognitive_complexity        NUMERIC(10,2) DEFAULT 0,
    violation_count             INT DEFAULT 0,
    violation_blocker_count     INT DEFAULT 0,
    violation_critical_count    INT DEFAULT 0,
    lines_of_code               INT DEFAULT 0,
    tech_debt_minutes           INT DEFAULT 0,
    calculated_at               TIMESTAMP DEFAULT NOW(),
    UNIQUE (release_id, file_id)
);

-- -----------------------------------------------------------------------------
-- fact_lda_topics — LDA topic output per source per release
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_lda_topics (
    topic_id        SERIAL PRIMARY KEY,
    release_id      INT REFERENCES dim_release(release_id),
    source          VARCHAR(10) NOT NULL CHECK (source IN ('LPP', 'LPD')),
    topic_number    INT NOT NULL,
    topic_label     VARCHAR(100),
    top_terms       TEXT,                   -- comma-separated top N terms
    proportion      NUMERIC(5,4),           -- share of corpus
    bug_count       INT DEFAULT 0,
    calculated_at   TIMESTAMP DEFAULT NOW(),
    UNIQUE (release_id, source, topic_number)
);

-- -----------------------------------------------------------------------------
-- fact_bug_forecast — predicted vs actual per team per release
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_bug_forecast (
    forecast_id         SERIAL PRIMARY KEY,
    release_id          INT NOT NULL REFERENCES dim_release(release_id),
    team_id             INT NOT NULL REFERENCES dim_team(team_id),
    predicted_count     NUMERIC(8,2),
    actual_count        INT,                -- NULL until release closes
    lower_ci            NUMERIC(8,2),       -- lower confidence interval bound
    upper_ci            NUMERIC(8,2),       -- upper confidence interval bound
    model_version       VARCHAR(20),
    r_squared           NUMERIC(5,4),
    calculated_at       TIMESTAMP DEFAULT NOW(),
    UNIQUE (release_id, team_id, model_version)
);

-- -----------------------------------------------------------------------------
-- Add routine_name to fact_test_failure
-- -----------------------------------------------------------------------------

ALTER TABLE fact_test_failure
    ADD COLUMN IF NOT EXISTS routine_name VARCHAR(100);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_static_diff_release      ON fact_static_diff(release_id);
CREATE INDEX IF NOT EXISTS idx_static_diff_module       ON fact_static_diff(module_id);
CREATE INDEX IF NOT EXISTS idx_release_complexity_rel   ON fact_release_complexity(release_id);
CREATE INDEX IF NOT EXISTS idx_release_complexity_file  ON fact_release_complexity(file_id);
CREATE INDEX IF NOT EXISTS idx_lda_topics_release       ON fact_lda_topics(release_id, source);
CREATE INDEX IF NOT EXISTS idx_bug_forecast_release     ON fact_bug_forecast(release_id);
CREATE INDEX IF NOT EXISTS idx_bug_forecast_team        ON fact_bug_forecast(team_id);
CREATE INDEX IF NOT EXISTS idx_test_failure_routine     ON fact_test_failure(routine_name);

-- -----------------------------------------------------------------------------
-- Schema version
-- -----------------------------------------------------------------------------

INSERT INTO schema_version (version, notes) VALUES
  ('1.3', 'Dashboard & release intelligence layer — dim_release, fact_static_diff, fact_release_complexity, fact_lda_topics, fact_bug_forecast, routine_name on fact_test_failure')
ON CONFLICT (version) DO NOTHING;