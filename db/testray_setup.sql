-- =============================================================================
-- testray_setup.sql
-- Creates the denormalized working table from a raw Testray PostgreSQL backup.
--
-- Context:
--   Testray stores data using Liferay's object storage schema, with table names
--   prefixed by the object definition ID (o_22235989312226_*). This script
--   joins the raw tables into a flat, query-friendly working table.
--
-- Full restore flow (run in order):
--
--   1. Drop and recreate clean database:
--        psql -U postgres -h localhost -c "DROP DATABASE IF EXISTS testray_working_db;"
--        psql -U postgres -h localhost -c "CREATE DATABASE testray_working_db;"
--
--   2. Restore from gzipped SQL dump:
--        zcat backup-db-testray2-prd2-YYYYMMDD0050.gz | \
--          psql -U postgres -d testray_working_db -h localhost
--        (takes ~30-60 min for full 150GB backup)
--
--   3. Run this script to create caseresult_working:
--        psql -U postgres -h localhost -d testray_working_db -f db/testray_setup.sql
--
--   4. Grant SELECT to analytics user:
--        psql -U postgres -h localhost -d testray_working_db \
--          -c "GRANT SELECT ON caseresult_working TO <analytics_user>;"
--
--   config.yml does not need to change — databases.testray.dbname is always
--   testray_working_db regardless of which backup date was restored.
--
-- Filters applied:
--   - proj.c_projectid_ = 35392  — DXP project only
--   - NOT r.c_routineid_ = 45357 — excludes EE Pull Request Tester
--
-- Output: caseresult_working (~80M rows for full backup)
--   Columns: case_result_id, build_id, build_name, routine_id, routine_name,
--            run_id, case_id, case_name, case_type, status, errors, jira_issue,
--            start_date, component_id, component_name, team_id, team_name,
--            proj_id, proj_name
--
-- Downstream:
--   transform/transform_cofailure.R reads from this table via config.yml
--   databases.testray connection block.
-- =============================================================================

DROP TABLE IF EXISTS caseresult_working;

CREATE TABLE caseresult_working AS
SELECT
    c.c_caseresultid_                           AS case_result_id,
    c.r_buildtocaseresult_c_buildid             AS build_id,
    b.name_                                     AS build_name,
    b.r_routinetobuilds_c_routineid             AS routine_id,
    r.name_                                     AS routine_name,
    c.r_runtocaseresult_c_runid                 AS run_id,
    c.r_casetocaseresult_c_caseid               AS case_id,
    ca.name_                                    AS case_name,
    ct.name_                                    AS case_type,
    c.duestatus_                                AS status,
    c.errors_                                   AS errors,
    c.issues_                                   AS jira_issue,
    c.startdate_                                AS start_date,
    c.r_componenttocaseresult_c_componentid     AS component_id,
    comp.name_                                  AS component_name,
    c.r_teamtocaseresult_c_teamid               AS team_id,
    t.name_                                     AS team_name,
    proj.c_projectid_                           AS proj_id,
    proj.name_                                  AS proj_name
FROM o_22235989312226_caseresult c
LEFT JOIN public.o_22235989312226_build b
    ON c.r_buildtocaseresult_c_buildid = b.c_buildid_
LEFT JOIN o_22235989312226_routine r
    ON b.r_routinetobuilds_c_routineid = r.c_routineid_
LEFT JOIN public.o_22235989312226_case ca
    ON c.r_casetocaseresult_c_caseid = ca.c_caseid_
LEFT JOIN public.o_22235989312226_casetype ct
    ON ca.r_casetypetocases_c_casetypeid = ct.c_casetypeid_
LEFT JOIN public.o_22235989312226_team t
    ON c.r_teamtocaseresult_c_teamid = t.c_teamid_
LEFT JOIN public.o_22235989312226_component comp
    ON c.r_componenttocaseresult_c_componentid = comp.c_componentid_
LEFT JOIN public.o_22235989312226_project proj
    ON t.r_projecttoteams_c_projectid = proj.c_projectid_
WHERE
    proj.c_projectid_ = 35392       -- DXP project
    AND NOT r.c_routineid_ = 45357; -- excluded routine (document reason above)

-- -----------------------------------------------------------------------------
-- Post-creation: recommended indexes for query performance
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_caseresult_build_id
    ON caseresult_working (build_id);

CREATE INDEX IF NOT EXISTS idx_caseresult_routine_name
    ON caseresult_working (routine_name);

CREATE INDEX IF NOT EXISTS idx_caseresult_status
    ON caseresult_working (status);

CREATE INDEX IF NOT EXISTS idx_caseresult_component_name
    ON caseresult_working (component_name);

CREATE INDEX IF NOT EXISTS idx_caseresult_case_type
    ON caseresult_working (case_type);

CREATE INDEX IF NOT EXISTS idx_caseresult_start_date
    ON caseresult_working (start_date);

-- -----------------------------------------------------------------------------
-- Grant access to analytics user
-- -----------------------------------------------------------------------------
-- GRANT SELECT ON caseresult_working TO <analytics_user>;
-- (Uncomment and replace <analytics_user> with your config.yml db user)