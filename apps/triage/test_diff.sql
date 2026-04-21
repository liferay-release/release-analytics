-- apps/triage/test_diff.sql
--
-- Returns test cases that PASSED in Build A and are
-- FAILED, BLOCKED, or UNTESTED in Build B.
--
-- Parameters (pass via psycopg2 or pgAdmin variable substitution):
--   %(build_id_a)s  — older build (baseline)
--   %(build_id_b)s  — newer build (target)
--
-- Reads from caseresult_analytical (denormalized; case_name, case_flaky,
-- component_name, errors, jira_issue already inline — no joins needed).

WITH build_a AS (
    SELECT
        case_id,
        case_name,
        case_flaky,
        component_name,
        status  AS status_a
    FROM caseresult_analytical
    WHERE build_id = %(build_id_a)s
),
build_b AS (
    SELECT
        case_id,
        status      AS status_b,
        errors      AS error_b,
        jira_issue  AS issues_b
    FROM caseresult_analytical
    WHERE build_id = %(build_id_b)s
)
SELECT
    ba.case_id            AS testray_case_id,
    ba.case_name          AS test_case,
    ba.case_flaky         AS known_flaky,
    ba.component_name     AS testray_component_name,
    ba.status_a,
    bb.status_b,
    bb.error_b            AS error_message,
    bb.issues_b           AS linked_issues
FROM build_a ba
JOIN build_b bb ON bb.case_id = ba.case_id
WHERE ba.status_a = 'PASSED'
  AND bb.status_b IN ('FAILED', 'BLOCKED', 'UNTESTED')
ORDER BY
    ba.case_flaky,
    ba.component_name,
    ba.case_name;
