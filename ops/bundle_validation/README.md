# Bundle Validation

Post-release smoke test for an unzipped Liferay DXP bundle. Runs a set
of pass/fail checks and appends results to `<version>validation.txt` in
the current working directory.

## Usage

Run from **inside the directory containing the unzipped `liferay-dxp/`
folder**:

```bash
cd ~/releases/liferay-dxp-tomcat-2026.q1.1-lts
bash /path/to/liferay-release-analytics/ops/bundle_validation/validationScript.sh 2026.Q1.1-lts
```

### Arguments

| Argument | Required | Description |
|---|---|---|
| `version` | yes | Release version (e.g. `130`, `2025.Q3.3`, `2026.Q1.1-lts`). The script aborts if Q1 is passed without the `-lts` suffix for 2025+ releases. |

## What it checks

Each check writes one `PASSED:` / `FAILED:` line into
`<version>validation.txt`:

| Check | Looks at |
|---|---|
| LTS version tag | Folder name contains `-lts` when version does |
| `.liferay-home` | File exists in `liferay-dxp/` |
| `.githash` | File non-empty in `liferay-dxp/` |
| Copyright | `liferay-dxp/license/copyright.txt` matches expected LGPL-2.1 / Liferay EULA header (year hardcoded — update annually) |
| `deploy/` | Directory empty |
| `logs/` | Directory empty |
| `osgi/state/` | Contains `org.eclipse.osgi` as subdirectory |
| `osgi/marketplace/override/` | Contains only a single `README.md` / `README.markdown` |
| `osgi/modules/` | Directory empty |
| `osgi/portal/` | Five canary jars present: `users.admin.web`, `site.initializer.welcome`, `portal.search`, `content.dashboard.web`, `commerce.frontend.impl` |
| `mysql.jar` | **Not** present in `tomcat/lib/` (licensing — cannot ship) |
| `patching-tool/` | Six expected entries: `lib/`, `logs/`, `patches/`, `default.properties`, `patching-tool.bat`, `patching-tool.sh` |
| Startup | Runs `catalina.sh run` for 45s, then greps `tomcat/bin/out.log` for portal version banner matching `"Liferay Digital Experience Platform ${version} (${current_month}, ${current_year})"` |
| Startup errors | No `ERROR` lines in `out.log` (log deleted on pass) |

## Output

- `<version>validation.txt` — appended to on every run. **Rename or
  delete between runs** if you want clean results.
- `liferay-dxp/tomcat/bin/out.log` — kept on failure, deleted on pass.

## Caveats

- The copyright year is **hardcoded** in the script (`2026` currently).
  Update `check_copyright` each January.
- The startup check assumes the current month's release date. Running
  against an older bundle will fail the "release date" assertion —
  expected.
- The script calls `pkill -f 'catalina'` at the end. Don't run if you
  have another Tomcat on the machine you care about.
- `check_lts_version` writes results using `${1}` as the filename —
  which is the version string, not a normalized path. Every check ends
  up in a file named literally after the version (e.g.
  `2026.Q1.1-ltsvalidation.txt`). This is pre-existing behavior; don't
  "fix" without checking downstream consumers.

## Dependencies

- Bash 4+
- `docker` is **not** required
- `curl` (used by `get_release_url`, which is currently unused in
  `main` but preserved as a helper)
- A Java runtime on `PATH` so Tomcat can start
