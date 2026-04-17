# ops/utils — liferay_utils Python Package

Shared Python package used by the Jira automation scripts in
[`../release_jira/`](../release_jira/README.md). Provides a Jira
connection factory, encrypted credential storage, Jira helpers
(sub-task creation, issue enumeration), and a Google Sheets / testmap
client.

**Original author:** David Gutierrez Mesa. Distributed under the MIT
license — see [`LICENSE`](LICENSE). Keep the license file in place if
vendoring elsewhere.

## Install

Not a standalone install target — it is pulled in transitively by
scripts that depend on it:

```bash
# From ops/release_jira/requirements.txt:
-r ../utils/requirements.txt
gitpython>=3.1.41
```

Running `pip install -r ops/release_jira/requirements.txt` installs
both sets.

Direct install (for new consumers):

```bash
pip install -r ops/utils/requirements.txt
```

## Layout

```
liferay_utils/
├── __init__.py
├── file_helpers.py               Write-to-file / recursive-search helpers
├── manageCredentialsCrypto.py    Encrypted ~/.jira_user/ storage; entry point to reset creds
├── jira_utils/
│   ├── __init__.py
│   ├── jira_constants.py         Instance URL, CustomField IDs, Status/Transition names, Strings
│   ├── jira_helpers.py           get_all_issues, sub-task scaffolds, patch-release helpers
│   └── jira_liferay.py           get_jira_connection() factory
└── sheets/
    ├── __init__.py
    ├── sheets_constants.py       Google Sheet URL + OAuth scopes
    ├── sheets_helpers.py         Grouping / batch-update helpers over Sheets v4 API
    ├── sheets_liferay.py         Field extractors bridging Jira stories → Sheet rows
    └── testmap_helpers.py        Test coverage matrix helpers (testmap workflow)
```

## Credentials

`manageCredentialsCrypto.py` manages Jira auth:

- On first run, prompts for email + API token and encrypts with an
  RSA-2048 / PKCS1_OAEP keypair generated on the spot.
- Stores three files in `~/.jira_user/`: `user`, `credentials`, `keys`.
- Subsequent runs decrypt silently.

Reset by deleting `~/.jira_user/` or running the module directly:

```bash
python -m liferay_utils.manageCredentialsCrypto
```

Google Sheets auth uses a separate flow — it reads
`~/.testmap_user/credentials.json` (OAuth client secret) and writes
`../token.json` after consent.

## Jira connection pattern

```python
from liferay_utils.jira_utils.jira_liferay import get_jira_connection
from liferay_utils.jira_utils.jira_helpers import get_all_issues

jira = get_jira_connection()                # Cloud instance, from jira_constants.Instance
issues = get_all_issues(jira, jql="...", fields=["key", "status"])
```

`Instance.Jira_URL = "https://liferay.atlassian.net"` is hardcoded in
`jira_constants.py`. Change there if pointing at a staging instance.

## Sheets helpers

`sheets_liferay.py` assumes the consuming script has already established
a testmap connection via `get_testmap_connection()` in
`testmap_helpers.py`. The helpers translate Jira story objects into
row-shaped data using `CustomField` IDs from `jira_constants.py`.

The `CustomField` IDs are Liferay-Cloud-specific (`customfield_10211`
Fix Priority, `customfield_10227` QA Engineer, etc.). Different Jira
instances will assign different IDs — treat this file as a mapping
layer, not a constant.

## Caveats

- **`pycryptodome`, not `pycrypto`.** `from Crypto.PublicKey import RSA`
  works with either, but `pycrypto` is unmaintained and will break on
  Python 3.12+. Stick with `pycryptodome==3.15.0` as pinned.
- **Relative import pattern.** Scripts in `../release_jira/` use
  `sys.path.append(os.path.join(sys.path[0], '..', 'utils'))` to find
  this package. Do not move the directory without updating every
  caller.
- **No unit tests.** Changes here affect every `release_jira/` script
  — validate against a non-production Jira project (or dry-run against
  Liferay Cloud with a low-impact ticket) before landing.

## Dependencies

See [`requirements.txt`](requirements.txt). Pins Google API clients at
pre-2.67 versions — bumping these requires testing against the testmap
sheets workflow.
