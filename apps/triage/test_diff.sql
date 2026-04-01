-- apps/triage/test_diff.sql
--
-- Returns test cases that PASSED in Build A and are
-- FAILED, BLOCKED, or UNTESTED in Build B.
--
-- Parameters (pass via psycopg2 or pgAdmin variable substitution):
--   %(build_id_a)s  — older build (baseline)
--   %(build_id_b)s  — newer build (target)
--
-- ⚠️  Re-verify table prefix after DB restore.
--     Run: SELECT table_name FROM information_schema.tables
--          WHERE table_catalog = 'testray_working_db'
--          AND table_name LIKE 'o\_%' ORDER BY table_name;

WITH build_a AS (
    SELECT
        cr.r_casetocaseresult_c_caseid  AS case_id,
        cr.duestatus_                   AS status_a,
        cr.errors_                      AS error_a,
        cr.issues_                      AS issues_a
    FROM o_22235989312226_caseresult cr
    WHERE cr.r_buildtocaseresult_c_buildid = %(build_id_a)s
),
build_b AS (
    SELECT
        cr.r_casetocaseresult_c_caseid  AS case_id,
        cr.duestatus_                   AS status_b,
        cr.errors_                      AS error_b,
        cr.issues_                      AS issues_b
    FROM o_22235989312226_caseresult cr
    WHERE cr.r_buildtocaseresult_c_buildid = %(build_id_b)s
)
SELECT
    c.c_caseid_                         AS testray_case_id,
    c.name_                             AS test_case,
    c.flaky_                            AS known_flaky,
    comp.name_                          AS testray_component_name,
    ba.status_a,
    bb.status_b,
    bb.error_b                          AS error_message,
    bb.issues_b                         AS linked_issues
FROM build_a ba
JOIN build_b bb   ON bb.case_id  = ba.case_id
JOIN o_22235989312226_case      c    ON c.c_caseid_  = ba.case_id
LEFT JOIN o_22235989312226_component comp ON comp.c_componentid_ = c.r_componenttocases_c_componentid
WHERE ba.status_a = 'PASSED'
  AND bb.status_b IN ('FAILED', 'BLOCKED', 'UNTESTED')
ORDER BY
    c.flaky_,
    comp.name_,
    c.name_;
