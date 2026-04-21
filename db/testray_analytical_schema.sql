-- =============================================================================
-- testray_analytical_schema.sql
-- Runs INSIDE testray_analytical. Pulls data directly from testray_working_db
-- via postgres_fdw — no intermediate materialization in working_db, no
-- pg_dump/pg_restore step. One copy of the denormalized data on disk.
--
-- Run via: bash db/testray_analytical_bootstrap.sh
-- (the bootstrap script handles DROP/CREATE DATABASE before this runs)
--
-- Scope filter (unchanged from previous setup.sql):
--   Projects 135537960, 3020904, 456316917 → all history
--   Project 35392                          → builds with duedate_ >= 2026-01-01
--
-- Errors column:
--   errors           = LEFT(cr.errors_, 1000)  — truncated for shareable DB
--   errors_truncated = LENGTH(cr.errors_) > 1000
--
-- Indexes are built AFTER bulk load (much faster than loading into an indexed
-- table). ANALYZE runs at the end so the planner has good stats.
--
-- Auth note:
--   postgres_fdw connects to testray_working_db via the Unix socket (peer
--   auth), not TCP, so no password is required as long as the postgres
--   server process can reach /var/run/postgresql. The bootstrap script runs
--   this file under `sudo -u postgres`, which gives psql peer auth too.
-- =============================================================================

\timing on
\echo ''
\echo '=== [1/6] FDW setup ==='

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- host = Unix socket directory (not 'localhost'). This routes FDW through
-- the socket where pg_hba.conf applies peer auth (OS postgres → DB postgres),
-- so no password is needed. TCP to localhost would hit scram-sha-256.
-- If the socket is in a non-standard location, edit the host option below.
CREATE SERVER working_db_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (
        host '/var/run/postgresql',
        port '5432',
        dbname 'testray_working_db',
        use_remote_estimate 'true',
        fetch_size '10000'
    );

CREATE USER MAPPING FOR CURRENT_USER
    SERVER working_db_server
    OPTIONS (user 'postgres');

CREATE SCHEMA fdw_src;

IMPORT FOREIGN SCHEMA public
    LIMIT TO (
        o_22235989312226_caseresult,
        o_22235989312226_build,
        o_22235989312226_routine,
        o_22235989312226_project,
        o_22235989312226_run,
        o_22235989312226_case,
        o_22235989312226_casetype,
        o_22235989312226_component,
        o_22235989312226_team
    )
    FROM SERVER working_db_server INTO fdw_src;

\echo ''
\echo '=== [2/6] Dimension tables ==='

CREATE TABLE dim_project AS
SELECT
    c_projectid_ AS project_id,
    name_        AS project_name
FROM fdw_src.o_22235989312226_project
WHERE c_projectid_ IN (135537960, 3020904, 456316917, 35392);

ALTER TABLE dim_project ADD PRIMARY KEY (project_id);

CREATE TABLE dim_routine AS
SELECT
    r.c_routineid_                     AS routine_id,
    r.name_                            AS routine_name,
    r.r_routinetoprojects_c_projectid  AS project_id,
    p.name_                            AS project_name
FROM fdw_src.o_22235989312226_routine r
JOIN fdw_src.o_22235989312226_project p
    ON p.c_projectid_ = r.r_routinetoprojects_c_projectid
WHERE r.r_routinetoprojects_c_projectid IN (135537960, 3020904, 456316917, 35392);

ALTER TABLE dim_routine ADD PRIMARY KEY (routine_id);
CREATE INDEX idx_dim_routine_project ON dim_routine (project_id);

CREATE TABLE dim_case_type AS
SELECT
    c_casetypeid_ AS case_type_id,
    name_         AS case_type_name
FROM fdw_src.o_22235989312226_casetype;

ALTER TABLE dim_case_type ADD PRIMARY KEY (case_type_id);

CREATE TABLE dim_team AS
SELECT DISTINCT
    c_teamid_ AS team_id,
    name_     AS team_name
FROM fdw_src.o_22235989312226_team;

ALTER TABLE dim_team ADD PRIMARY KEY (team_id);

CREATE TABLE dim_component AS
SELECT DISTINCT
    c_componentid_ AS component_id,
    name_          AS component_name
FROM fdw_src.o_22235989312226_component;

ALTER TABLE dim_component ADD PRIMARY KEY (component_id);

\echo ''
\echo '=== [3/6] caseresult_analytical (the long step — 45-90 min) ==='

CREATE TABLE caseresult_analytical AS
SELECT
    cr.c_caseresultid_                              AS case_result_id,

    -- Build
    cr.r_buildtocaseresult_c_buildid                AS build_id,
    b.name_                                         AS build_name,
    DATE(b.duedate_)                                AS build_date,
    b.duedate_                                      AS build_datetime,
    b.promoted_                                     AS build_promoted,

    -- Routine
    b.r_routinetobuilds_c_routineid                 AS routine_id,
    r.name_                                         AS routine_name,

    -- Run
    cr.r_runtocaseresult_c_runid                    AS run_id,
    rn.name_                                        AS run_name,

    -- Case
    cr.r_casetocaseresult_c_caseid                  AS case_id,
    ca.name_                                        AS case_name,
    ca.priority_                                    AS case_priority,
    ca.flaky_                                       AS case_flaky,

    -- Case type
    ca.r_casetypetocases_c_casetypeid               AS case_type_id,
    ct.name_                                        AS case_type,

    -- Component
    cr.r_componenttocaseresult_c_componentid        AS component_id,
    comp.name_                                      AS component_name,

    -- Team
    cr.r_teamtocaseresult_c_teamid                  AS team_id,
    t.name_                                         AS team_name,

    -- Project (resolved via routine)
    r.r_routinetoprojects_c_projectid               AS project_id,
    p.name_                                         AS project_name,

    -- Result data
    cr.duestatus_                                   AS status,
    LEFT(cr.errors_, 1000)                          AS errors,
    (LENGTH(cr.errors_) > 1000)                     AS errors_truncated,
    cr.issues_                                      AS jira_issue,
    cr.startdate_                                   AS start_date

FROM      fdw_src.o_22235989312226_caseresult cr
JOIN      fdw_src.o_22235989312226_build     b    ON b.c_buildid_        = cr.r_buildtocaseresult_c_buildid
JOIN      fdw_src.o_22235989312226_routine   r    ON r.c_routineid_      = b.r_routinetobuilds_c_routineid
JOIN      fdw_src.o_22235989312226_project   p    ON p.c_projectid_      = r.r_routinetoprojects_c_projectid
LEFT JOIN fdw_src.o_22235989312226_run       rn   ON rn.c_runid_         = cr.r_runtocaseresult_c_runid
LEFT JOIN fdw_src.o_22235989312226_case      ca   ON ca.c_caseid_        = cr.r_casetocaseresult_c_caseid
LEFT JOIN fdw_src.o_22235989312226_casetype  ct   ON ct.c_casetypeid_    = ca.r_casetypetocases_c_casetypeid
LEFT JOIN fdw_src.o_22235989312226_component comp ON comp.c_componentid_ = cr.r_componenttocaseresult_c_componentid
LEFT JOIN fdw_src.o_22235989312226_team      t    ON t.c_teamid_         = cr.r_teamtocaseresult_c_teamid
WHERE
    r.r_routinetoprojects_c_projectid IN (135537960, 3020904, 456316917)
    OR (
      r.r_routinetoprojects_c_projectid = 35392
      AND b.duedate_ >= '2026-01-01'::timestamp
    );

\echo ''
\echo '=== [4/6] Indexes on caseresult_analytical ==='

CREATE INDEX idx_cra_project_id     ON caseresult_analytical (project_id);
CREATE INDEX idx_cra_routine_id     ON caseresult_analytical (routine_id);
CREATE INDEX idx_cra_build_id       ON caseresult_analytical (build_id);
CREATE INDEX idx_cra_case_id        ON caseresult_analytical (case_id);
CREATE INDEX idx_cra_status         ON caseresult_analytical (status);
CREATE INDEX idx_cra_component_name ON caseresult_analytical (component_name);
CREATE INDEX idx_cra_team_name      ON caseresult_analytical (team_name);
CREATE INDEX idx_cra_case_type      ON caseresult_analytical (case_type);
CREATE INDEX idx_cra_build_date     ON caseresult_analytical (build_date);
CREATE INDEX idx_cra_proj_rout_date ON caseresult_analytical (project_id, routine_id, build_date);

\echo ''
\echo '=== [5/6] ANALYZE + FDW cleanup ==='

ANALYZE caseresult_analytical;
ANALYZE dim_project;
ANALYZE dim_routine;
ANALYZE dim_case_type;
ANALYZE dim_team;
ANALYZE dim_component;

DROP SCHEMA fdw_src CASCADE;
DROP USER MAPPING FOR CURRENT_USER SERVER working_db_server;
DROP SERVER working_db_server;
-- extension kept (tiny, harmless; remove with DROP EXTENSION postgres_fdw if desired)

\echo ''
\echo '=== [6/6] Validation ==='
\echo ''
\echo 'Row counts by project:'
SELECT
    project_id,
    project_name,
    COUNT(*)                   AS rows,
    COUNT(DISTINCT build_id)   AS builds,
    COUNT(DISTINCT routine_id) AS routines,
    MIN(build_date)            AS earliest_build,
    MAX(build_date)            AS latest_build
FROM caseresult_analytical
GROUP BY project_id, project_name
ORDER BY project_id;

\echo ''
\echo 'Dim table row counts:'
SELECT 'dim_project'    AS tbl, COUNT(*) AS n FROM dim_project
UNION ALL SELECT 'dim_routine',   COUNT(*) FROM dim_routine
UNION ALL SELECT 'dim_case_type', COUNT(*) FROM dim_case_type
UNION ALL SELECT 'dim_team',      COUNT(*) FROM dim_team
UNION ALL SELECT 'dim_component', COUNT(*) FROM dim_component;

\echo ''
\echo 'Sample errors_truncated distribution:'
SELECT
    errors_truncated,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM caseresult_analytical
WHERE errors IS NOT NULL AND errors != ''
GROUP BY errors_truncated;
