-- apps/triage/git_hash_lookup.sql
--
-- Fetch git hashes and metadata for Build A and Build B.
--
-- Parameters:
--   %(build_id_a)s
--   %(build_id_b)s
--
-- Reads from dim_build in testray_analytical.

SELECT
    build_id,
    build_name,
    git_hash,
    build_status,
    routine_id,
    project_id
FROM dim_build
WHERE build_id IN (%(build_id_a)s, %(build_id_b)s)
ORDER BY build_id;
