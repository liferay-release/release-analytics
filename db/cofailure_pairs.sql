-- =============================================================================
-- Component co-failure pairs — test-case level Jaccard
-- =============================================================================

WITH

-- Step 1 — Filtered failures
failures AS (
  SELECT
    build_id,
    case_id,
    component_name
  FROM caseresult_working
  WHERE routine_name IN (
    'EE Development Acceptance (master)',
    'EE Development (master)',
    'EE Package Tester',
    '[master] ci:test:upstream-dxp'
  )
  AND status = 'FAILED'
  AND start_date >= CURRENT_DATE - INTERVAL '365 days'
  AND case_type NOT IN (
    'Batch',
    'Modules Compile Test',
    'Modules Integration AWS Test',
    'Modules Semantic Versioning Test',
    'Release OSGI State Test',
    'Semantic Versioning Test',
    'LPKG Test'
  )
  AND (
    errors IS NULL
    OR (
      errors NOT ILIKE 'Failed prior to running test%'
      AND errors NOT ILIKE '%Failed to run test on CI%'
      AND errors NOT ILIKE 'The build failed prior to running the test%'
      AND errors NOT ILIKE '%timed out after 2 hours%'
      AND errors NOT ILIKE '%Unable to synchronize with local Git mirror%'
      AND errors NOT ILIKE '%test failed to compile successfully%'
    )
  )
),

-- Step 2 — Total builds in scope
total_builds AS (
  SELECT COUNT(DISTINCT build_id) AS n FROM failures
),

-- Step 3 — Test case failure frequency
-- Grouped by case_id only — a case must have a single global fail count
-- for Jaccard to stay in [0,1]. Grouping by (case_id, component_name) allows
-- a case to appear in multiple components with different counts, which causes
-- fail_a + fail_b - co_fail to go negative and breaks the formula.
case_fail_freq AS (
  SELECT
    case_id,
    COUNT(DISTINCT build_id) AS fail_build_count
  FROM failures
  GROUP BY case_id
),

-- Step 4 — Component failure frequency
component_fail_freq AS (
  SELECT
    component_name,
    COUNT(DISTINCT build_id)                          AS fail_build_count,
    ROUND(COUNT(DISTINCT build_id)::NUMERIC /
      (SELECT n FROM total_builds), 4)                AS fail_rate
  FROM failures
  GROUP BY component_name
),

-- Step 5 — Build-level component pre-filter
-- Only keep component pairs that co-fail in MIN_COFAIL_COUNT+ builds
build_components AS (
  SELECT DISTINCT build_id, component_name FROM failures
),

component_cofail_prefilter AS (
  SELECT
    a.component_name AS component_a,
    b.component_name AS component_b,
    COUNT(DISTINCT a.build_id) AS co_fail_builds
  FROM build_components a
  JOIN build_components b
    ON a.build_id = b.build_id
    AND a.component_name < b.component_name
  GROUP BY a.component_name, b.component_name
  HAVING COUNT(DISTINCT a.build_id) >= 10
),

-- Step 6 — Test-case pairs within qualifying component pairs
test_cofail_raw AS (
  SELECT
    p.component_a,
    p.component_b,
    a.case_id AS case_id_a,
    b.case_id AS case_id_b,
    COUNT(DISTINCT a.build_id) AS co_fail_builds
  FROM component_cofail_prefilter p
  JOIN failures a ON a.component_name = p.component_a
  JOIN failures b ON b.component_name = p.component_b
    AND b.build_id = a.build_id
  GROUP BY p.component_a, p.component_b, a.case_id, b.case_id
  HAVING COUNT(DISTINCT a.build_id) >= 10
),

-- Step 7 — Jaccard per test-case pair
test_cofail_jaccard AS (
  SELECT
    t.component_a,
    t.component_b,
    t.case_id_a,
    t.case_id_b,
    t.co_fail_builds,
    fa.fail_build_count AS fail_a,
    fb.fail_build_count AS fail_b,
    ROUND(
      t.co_fail_builds::NUMERIC /
      NULLIF(fa.fail_build_count + fb.fail_build_count - t.co_fail_builds, 0),
    4) AS jaccard_score
  FROM test_cofail_raw t
  JOIN case_fail_freq fa ON fa.case_id = t.case_id_a
  JOIN case_fail_freq fb ON fb.case_id = t.case_id_b
),

-- Step 8 — Aggregate to component level (simple mean Jaccard)
component_cofail_final AS (
  SELECT
    j.component_a,
    j.component_b,
    p.co_fail_builds,
    ROUND(AVG(j.jaccard_score), 4)  AS jaccard_score,
    SUM(j.co_fail_builds)           AS co_fail_count,
    COUNT(*)                        AS test_pair_count
  FROM test_cofail_jaccard j
  JOIN component_cofail_prefilter p
    ON p.component_a = j.component_a
    AND p.component_b = j.component_b
  GROUP BY j.component_a, j.component_b, p.co_fail_builds
  HAVING COUNT(*) > 4  -- require 5+ independent test pairs for confident signal
)

-- Final output
SELECT
  f.component_a,
  f.component_b,
  f.co_fail_builds,
  f.jaccard_score,
  f.co_fail_count,
  f.test_pair_count,
  ca.fail_build_count  AS fail_count_a,
  cb.fail_build_count  AS fail_count_b,
  ca.fail_rate         AS fail_rate_a,
  cb.fail_rate         AS fail_rate_b,
  ROUND(f.co_fail_builds::NUMERIC / (SELECT n FROM total_builds), 4) AS co_fail_rate
FROM component_cofail_final f
JOIN component_fail_freq ca ON ca.component_name = f.component_a
JOIN component_fail_freq cb ON cb.component_name = f.component_b
ORDER BY f.jaccard_score DESC;
