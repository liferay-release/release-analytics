# Release Jira Automation

Python scripts that drive the **PUBLIC - Liferay Product Delivery**
Jira project during a release cycle — finding the right parent task,
enumerating tickets between two git hashes, creating sub-tasks, and
transitioning status.

All scripts share the same credential and Jira connection pattern via
`ops/utils/liferay_utils/` (see [`../utils/README.md`](../utils/README.md)).

## Setup

```bash
cd ops/release_jira
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`requirements.txt` pulls `../utils/requirements.txt` via `-r`, so both
sets of dependencies install in one step.

On first run you will be prompted for your Liferay email + Jira API
token. These are encrypted (RSA-2048 + PKCS1_OAEP) and stored in
`~/.jira_user/`. Delete that folder to reset credentials.

## Scripts

### `fillQaAnalysisJiraTask.py`

Locates the "QA Analysis" parent task for a release, attaches the list
of LPS/LPD tickets that appear between two git hashes, assigns
`bahar.turk` (release lead) as owner, and transitions the task to
**In Progress**.

```bash
python fillQaAnalysisJiraTask.py <repo_path> <start_hash> <end_hash> [<release_version>]
```

Writes the parent task key to `PARENT_TASK.txt` in the working
directory for downstream scripts to pick up.

### `getLpsFromLocalRepo.py`

Walks `git log <start>..<end>` in `<repo_path>`, extracts the leading
`LPS-NNNN` / `LPD-NNNN` token from each commit subject, filters to Bug
issue types via Jira lookup, and optionally creates a sub-task on the
parent LPD ticket for each story found.

```bash
python getLpsFromLocalRepo.py <repo_path> <start_hash> <end_hash> [<release>] [<lpd_parent>]
```

Prints three categorized lists: stories, reverted commits, and
non-bug issues. When `<lpd_parent>` is given, each story becomes a
Jira sub-task related to the parent with a `relates` link.

### `getAllTicketsFromLocalRepo.py`

Simpler variant of the above — prints every unique ticket-shaped token
from commit messages between two hashes. No Jira mutations. Useful for
quick audits.

```bash
python getAllTicketsFromLocalRepo.py <repo_path> <start_hash> <end_hash>
```

### `updateBuildSubTask.py`

Locates the "Build" parent task for a release, assigns the release
lead, posts a comment with the release candidate URL, and transitions
to **In Progress**.

```bash
python updateBuildSubTask.py <release_candidate_url> <release_version>
```

### `release_constants.py`

Static config:

- `Filter.QA_Analysis_for_release` / `Filter.Build_for_release` — JQL
  templates, parameterized on `{release_version}`
- `Roles.Release_lead = 'bahar.turk'` — hardcoded assignee
- `URLs.Liferay_repo_URL = 'https://github.com/liferay/liferay-portal-ee/'`
- `FileName.Parent_task_file_name = 'PARENT_TASK.txt'`

## Caveats

- **Release lead is hardcoded** as `bahar.turk` in `release_constants.py`.
  Update if ownership transfers — every script uses this.
- The scripts `sys.path.append('../utils')` to import `liferay_utils`.
  Run them from their own directory, not from the project root, or the
  relative import will break.
- `getLpsFromLocalRepo.py` mutates Jira (creates sub-tasks, transitions
  issues) when `<lpd_parent>` is passed. Double-check the parent key
  before running — there is no dry-run flag.
- Jira transition names (`Selected for Development`, `In Progress`) are
  looked up from `Transition` in `../utils/liferay_utils/jira_utils/jira_constants.py`.
  If Liferay's Jira workflow is renamed, update that file.

## Dependencies

- Python 3.8+
- `jira==3.5.0`, `gitpython>=3.1.41`, `pycryptodome==3.15.0`, plus
  Google API libs pulled in by the shared `../utils/requirements.txt`
- A local `liferay-portal` / `liferay-portal-ee` checkout (any branch)
- Jira API token scoped to the LPD / LPS / PUBLIC projects
