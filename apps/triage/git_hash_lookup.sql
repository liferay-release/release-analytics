-- apps/triage/git_hash_lookup.sql
--
-- Fetch git hashes and metadata for Build A and Build B.
--
-- Parameters:
--   %(build_id_a)s
--   %(build_id_b)s

SELECT
    c_buildid_                          AS build_id,
    name_                               AS build_name,
    githash_                            AS git_hash,
    duestatus_                          AS build_status,
    r_routinetobuilds_c_routineid       AS routine_id,
    r_projecttobuilds_c_projectid       AS project_id
FROM o_22235989312226_build
WHERE c_buildid_ IN (%(build_id_a)s, %(build_id_b)s)
ORDER BY c_buildid_;
