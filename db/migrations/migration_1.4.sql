-- =============================================================================
-- Schema Version 1.4 — Forecast Input Layer
--
-- Adds:
--   - dim_component               component identity + team
--   - dim_module_component_map    module path → component (many-to-many, weighted)
--   - fact_forecast_input         assembled training/forecast dataset per component+quarter
--   - v_forecast_input            view used by dashboard Rmd
--
-- Extends:
--   - dim_release                 adds is_major_release + quarter_label columns
--                                 months_in_field is computed live from release_date
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extend dim_release
--
-- is_major_release: set TRUE when inserting quarterly GA releases (Q1, Q2, Q3, Q4).
--                   FALSE for internal milestones (U14x, etc.).
--                   You set this explicitly at insert time — you know which it is.
--
-- quarter_label:    the label used in fact_forecast_input.quarter for joining.
--                   For quarterly GAs this is e.g. '2025Q1'.
--                   For internal milestones this is e.g. 'U147'.
--                   Duplicates release_label in simple cases but allows the two
--                   to diverge (e.g. U147 quarter_label = '2026Q1' if needed).
-- -----------------------------------------------------------------------------

ALTER TABLE dim_release
    ADD COLUMN IF NOT EXISTS is_major_release        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS is_lts                  BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS release_status          VARCHAR(20) NOT NULL DEFAULT 'RELEASED',
    ADD COLUMN IF NOT EXISTS git_tag                 VARCHAR(60),
    ADD COLUMN IF NOT EXISTS quarter_label           VARCHAR(20);

-- Back-fill quarter_label = release_label for any existing rows
UPDATE dim_release
SET quarter_label = release_label
WHERE quarter_label IS NULL;

COMMENT ON COLUMN dim_release.is_major_release IS
    'TRUE = this U release was promoted to an external quarterly GA (Q1/Q2/Q3/Q4).';
COMMENT ON COLUMN dim_release.is_lts IS
    'TRUE = Q1 Long Term Support release. Customers stay on LTS longer so bug counts accumulate over a longer window.';
COMMENT ON COLUMN dim_release.release_status IS
    'IN_DEVELOPMENT | BRANCH_CUT | RELEASED — updated via releases.yml + sync_releases.R';
COMMENT ON COLUMN dim_release.quarter_label IS
    'Label used in fact_forecast_input.quarter. Matches release_label for most releases.';
COMMENT ON COLUMN dim_release.git_tag IS
    'Git release tag e.g. 7.4.3.147-ga147. hash_from derived from prior release tag at query time.';
COMMENT ON COLUMN dim_release.release_date IS
    'Ship date. Used to compute months_in_field dynamically in v_forecast_input.';

-- -----------------------------------------------------------------------------
-- dim_component
-- One row per Jira component name. team_name is denormalized here for
-- dashboard simplicity; if teams ever need their own dimension, promote it.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_component (
    component_id    SERIAL PRIMARY KEY,
    component_name  VARCHAR(200) NOT NULL UNIQUE,
    team_name       VARCHAR(100),               -- nullable until team map is loaded
    created_at      TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dim_component_name ON dim_component(component_name);

-- -----------------------------------------------------------------------------
-- dim_module_component_map
-- Many-to-many: one module path can belong to multiple components.
-- weight = 1/n where n = number of components for that module path.
-- Churn signals are multiplied by weight before aggregating to component grain.
-- Blank-component rows from the CSV are excluded at load time.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_module_component_map (
    map_id          SERIAL PRIMARY KEY,
    module_path     VARCHAR(500) NOT NULL,      -- e.g. 'modules/apps/commerce'
    component_id    INT NOT NULL REFERENCES dim_component(component_id),
    weight          NUMERIC(6,4) NOT NULL DEFAULT 1.0,  -- 1/n split
    created_at      TIMESTAMP DEFAULT NOW(),
    UNIQUE (module_path, component_id)
);

CREATE INDEX IF NOT EXISTS idx_mcm_module_path   ON dim_module_component_map(module_path);
CREATE INDEX IF NOT EXISTS idx_mcm_component_id  ON dim_module_component_map(component_id);

-- -----------------------------------------------------------------------------
-- fact_forecast_input
-- One row per (component, quarter). This is the assembled training dataset
-- that transform_forecast_input.R writes and the dashboard Rmd reads.
-- Churn columns mirror the churn_by_module.sh output, aggregated + weighted.
-- Bug counts come from raw_jira_issues.rds rolled up to component+quarter.
-- Stories come from extract_stories.R once implemented.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_forecast_input (
    forecast_input_id       SERIAL PRIMARY KEY,
    component_id            INT NOT NULL REFERENCES dim_component(component_id),
    quarter                 VARCHAR(20) NOT NULL,   -- e.g. '2025Q1', 'U147'
    release_id              INT REFERENCES dim_release(release_id),

    -- Bug counts (outcome variables)
    lpp_count               INT NOT NULL DEFAULT 0,
    lpd_count               INT NOT NULL DEFAULT 0,

    -- Workload signal
    story_count             INT NOT NULL DEFAULT 0,

    -- Release blockers (LPD tickets labeled release-blocker)
    blocker_count           INT NOT NULL DEFAULT 0,

    -- Breaking changes (weighted sum across modules)
    -- Defaulted to 0 — populated once breaking_changes script is integrated
    breaking_changes        NUMERIC(10,2) DEFAULT 0,

    -- Churn signals (weighted sum across modules in this component)
    -- Java
    java_file_count         NUMERIC(10,2) DEFAULT 0,
    java_lines_of_code      NUMERIC(10,2) DEFAULT 0,
    java_modified_files     NUMERIC(10,2) DEFAULT 0,
    java_insertions         NUMERIC(10,2) DEFAULT 0,
    java_deletions          NUMERIC(10,2) DEFAULT 0,

    -- JavaScript
    js_file_count           NUMERIC(10,2) DEFAULT 0,
    js_lines_of_code        NUMERIC(10,2) DEFAULT 0,
    js_modified_files       NUMERIC(10,2) DEFAULT 0,
    js_insertions           NUMERIC(10,2) DEFAULT 0,
    js_deletions            NUMERIC(10,2) DEFAULT 0,

    -- JSP
    jsp_file_count          NUMERIC(10,2) DEFAULT 0,
    jsp_lines_of_code       NUMERIC(10,2) DEFAULT 0,
    jsp_modified_files      NUMERIC(10,2) DEFAULT 0,
    jsp_insertions          NUMERIC(10,2) DEFAULT 0,
    jsp_deletions           NUMERIC(10,2) DEFAULT 0,

    -- TypeScript
    ts_file_count           NUMERIC(10,2) DEFAULT 0,
    ts_lines_of_code        NUMERIC(10,2) DEFAULT 0,
    ts_modified_files       NUMERIC(10,2) DEFAULT 0,
    ts_insertions           NUMERIC(10,2) DEFAULT 0,
    ts_deletions            NUMERIC(10,2) DEFAULT 0,

    -- TSX
    tsx_file_count          NUMERIC(10,2) DEFAULT 0,
    tsx_lines_of_code       NUMERIC(10,2) DEFAULT 0,
    tsx_modified_files      NUMERIC(10,2) DEFAULT 0,
    tsx_insertions          NUMERIC(10,2) DEFAULT 0,
    tsx_deletions           NUMERIC(10,2) DEFAULT 0,

    -- CSS / SCSS
    css_insertions          NUMERIC(10,2) DEFAULT 0,
    css_deletions           NUMERIC(10,2) DEFAULT 0,
    scss_insertions         NUMERIC(10,2) DEFAULT 0,
    scss_deletions          NUMERIC(10,2) DEFAULT 0,

    -- Derived totals (computed by transform_forecast_input.R, stored for query speed)
    backend_changes         NUMERIC(10,2) DEFAULT 0,   -- java ins+del
    frontend_changes        NUMERIC(10,2) DEFAULT 0,   -- tsx+scss+js ins+del
    total_churn             NUMERIC(10,2) DEFAULT 0,   -- all ins+del

    -- Metadata
    is_forecast_row         BOOLEAN DEFAULT FALSE,     -- TRUE = current release being predicted
    calculated_at           TIMESTAMP DEFAULT NOW(),

    UNIQUE (component_id, quarter)
);

CREATE INDEX IF NOT EXISTS idx_ffi_component  ON fact_forecast_input(component_id);
CREATE INDEX IF NOT EXISTS idx_ffi_quarter    ON fact_forecast_input(quarter);
CREATE INDEX IF NOT EXISTS idx_ffi_release    ON fact_forecast_input(release_id);

-- -----------------------------------------------------------------------------
-- v_forecast_input
-- The single query the dashboard Rmd calls. Joins component name + team,
-- derives months_in_field live from dim_release.release_date so it never
-- goes stale, and reads is_major_release directly from dim_release.
--
-- months_in_field: rounded months between release_date and today.
--   Falls back to 3 if no dim_release row exists for that quarter yet
--   (safe default for a release still in development).
--
-- is_major_release: comes from dim_release.is_major_release, which you set
--   explicitly when inserting a release row. No inference from label patterns.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_forecast_input AS
SELECT
    fi.forecast_input_id,
    dc.component_name                               AS component,
    dc.team_name                                    AS team,
    fi.quarter,
    fi.release_id,

    -- months_in_field: live calculation — always current, never stale
    COALESCE(
        ROUND(
            (CURRENT_DATE - dr.release_date) / 30.0
        )::INT,
        3   -- fallback for releases not yet in dim_release (in-flight)
    )                                               AS months_in_field,

    -- is_major_release and is_lts: explicit flags set at dim_release insert time
    COALESCE(dr.is_major_release, FALSE)::INT       AS is_major_release,
    COALESCE(dr.is_lts,           FALSE)::INT       AS is_lts,

    -- Outcomes
    fi.lpp_count                                    AS lpp,
    fi.lpd_count                                    AS lpd,
    fi.story_count                                  AS stories,
    fi.blocker_count,

    -- Churn signals
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
    fi.backend_changes,
    fi.frontend_changes,
    fi.total_churn,

    -- File inventory
    fi.java_file_count,
    fi.java_lines_of_code,
    fi.tsx_file_count,
    fi.tsx_lines_of_code,
    fi.js_file_count,
    fi.ts_file_count,

    fi.is_forecast_row,
    dr.release_date,
    fi.calculated_at

FROM fact_forecast_input       fi
JOIN dim_component             dc ON dc.component_id  = fi.component_id
-- Join on quarter_label so both '2025Q1' and 'U147' style labels resolve
LEFT JOIN dim_release          dr ON dr.quarter_label = fi.quarter
ORDER BY COALESCE(dr.release_date, '9999-12-31'), dc.component_name;

-- -----------------------------------------------------------------------------
-- Schema version
-- -----------------------------------------------------------------------------

INSERT INTO schema_version (version, notes) VALUES
  ('1.4', 'Forecast input layer — dim_component, dim_module_component_map, fact_forecast_input, v_forecast_input, git_tag replaces hash_from/hash_to')
ON CONFLICT (version) DO NOTHING;
