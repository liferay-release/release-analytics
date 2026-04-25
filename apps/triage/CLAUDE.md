# Triage — Claude Code Workflow

Classifies Testray PASSED→FAILED/BLOCKED/UNTESTED regressions as
BUG / NEEDS_REVIEW / FALSE_POSITIVE and writes results to
`fact_triage_results`.

**Two modes, one bundle.** `prepare.py` produces a classifier-agnostic
run bundle. From there:

- **Claude Code mode (this doc)** — default for local dev. A developer
  classifies by reading `prompt.md` in their session and writing
  `results.json` by hand. No SDK install, no API key.
- **API mode** — `apps.triage.classify_api` sends the same bundle to
  the Anthropic API with prompt caching + batching and writes the same
  `results.json`. Used for Jenkins / headless environments where a
  Claude Code session isn't available. Requires
  `pip install -r apps/triage/requirements-api.txt` and
  `ANTHROPIC_API_KEY`. Label persisted as `api:claude-opus-4-7` so
  runs are comparable against Claude Code mode on the same build pair.

The rest of this doc covers Claude Code mode. For API mode
operational details (batching, prompt caching, cost), see
`apps/triage/README.md` and `apps/triage/classify_api.py`.

Load `.claude/skills/triage.skill` at the start of any session for the
full rubric, schema, and file contracts.

## Session shape — prepare → classify → submit

Each side (baseline, target) independently chooses a source: `db`
(testray_analytical), `csv` (Testray CSV export), or `api` (Testray REST,
OAuth2 client_credentials). Same flag pattern on both sides.

```
python3 -m apps.triage.prepare \
    --baseline-source {db,csv,api} --baseline-build-id <A> \
        [--baseline-csv path/to/case_results.csv] \
        [--baseline-hash <sha>] [--baseline-name <str>] \
    --target-source   {db,csv,api} --target-build-id   <B> \
        [--target-csv   path/to/case_results.csv] \
        [--target-hash   <sha>] [--target-name   <str>]
```

Per-source arg rules:
- `db` → nothing beyond `--{side}-build-id`; hash/name/routine from `dim_build`.
- `csv` → `--{side}-csv` + `--{side}-hash` required (exports carry no
  sha); optional `--{side}-name`.
- `api` → build-id required; `--{side}-hash` optional, falls back to
  `dim_build`.

**Combo not supported today:** `csv × api` (either direction). CSV carries
`(case_name, component_name)` but no `case_id`; API carries `case_id` but
no names — no common join key. `prepare` hard-errors with a PoC note
pointing at enrichment backlog. All other combos work, including fully
detached `api × api` (no local DB needed).

```
      ↓
runs/r_<ts>_<A>_<B>/
   ├── run.yml              (metadata: builds, hashes, routine, classifier)
   ├── diff_list.csv        (one row per non-duplicate case, with
   │                         component/team + pre_classification)
   ├── hunks.txt            (git diff filtered to files matching failing tests)
   ├── git_diff_full.diff   (unfiltered diff — fallback when hunks.txt is too narrow)
   ├── test_fragments.txt   (fragments fed to extract_relevant_hunks)
   ├── prompt.md            (instructions for THIS session)
   └── results.schema.json  (JSON schema for results.json)
      ↓
[YOU read prompt.md, classify, write results.json]
      ↓
python3 -m apps.triage.submit apps/triage/runs/r_<ts>_<A>_<B>
```

Add `--no-upsert` to `submit.py` to validate + print the summary without
writing to `fact_triage_results` / `triage_run_log`. Useful on dev
laptops where the DB is an ephemeral local copy.

## Before starting

1. Confirm the routine ID and build pair (ask if not given). For the
   release PoC pair, baseline is **451312408** (pre-April 17, 2026 5pm
   Pacific — in the dump), target is typically a newer build supplied
   via CSV/API (future input modes) or also in the DB.
2. Check `fact_triage_results` for existing rows on this build pair AND
   the classifier you intend to use. The unique key is
   `(build_id_b, testray_case_id, classifier)` — re-running the same
   classifier on the same pair **overwrites** prior rows, which is fine
   for iteration but not what you want if you're trying to compare runs.
3. Confirm `config/config.yml` has valid DB credentials + a working
   `git.repo_path` pointing at a local liferay-portal checkout.
4. **Verify the baseline actually passed.** The tool only surfaces
   PASSED→FAILED transitions. Any test already failing in Build A is
   invisible — it will not appear in `diff_list.csv` or `results.json`.
   For Stable specifically, this is critical: Stable is all-or-nothing,
   so multiple consecutive failed builds can accumulate. If the baseline
   is a build that had *any* failures, those persistent regressions have
   no triage record under this run and the output will silently
   undercount real bugs. If you're unsure whether the baseline was a
   clean pass, check before classifying — do not assume.

## The classification loop

`prepare.py` has already done the heavy lifting: pulled the failure set
from `caseresult_analytical`, looked up git hashes from `dim_build`, run
`git diff` with release-noise exclusions, extracted hunks matching test
fragments, and pre-classified obvious env/infra failures.

For each **non-flaky, non-pre-classified** row in `diff_list.csv`:

1. Read `error_message`. Check for classic flake patterns:
   `TEST_SETUP_ERROR`, Selenium/Poshi element-not-found timeouts,
   Playwright visibility timeouts, concurrent-thread assertion errors,
   performance tolerance-exceeded-by-a-few-ms. These are almost always
   FALSE_POSITIVE.
2. Look at `hunks.txt` for files with paths containing tokens from
   `component_name` or `test_case`. The prompt.md already embeds the
   heuristically-matched hunks per failure — start there.
3. Evidence evaluation:
   - Hunk plausibly causes the error → **BUG**, name `culprit_file` =
     the specific path from the diff.
   - Thematically related but indirect → **NEEDS_REVIEW**.
   - No relevant hunk + classic flake pattern → **FALSE_POSITIVE**.
4. If a linked Jira ticket is present in `linked_issues`, read the
   summary — it often confirms BUG vs flake.
5. When the filtered `hunks.txt` looks too narrow (most of the diff was
   thrown away but the error names a module you can't find),
   `grep` through `git_diff_full.diff` before giving up.

Write one object per classified case to `results.json`:

```json
{
  "run_id":     "r_…",
  "classifier": "agent:claude-opus-4-7",
  "results": [
    {
      "testray_case_id": 12345,
      "classification":  "BUG",
      "confidence":      "high",
      "culprit_file":    "modules/apps/.../Foo.java",
      "specific_change": "Foo.java:42 removed null check in bar()",
      "reason":          "…"
    }
  ]
}
```

Pre-classified rows (`BUILD_FAILURE`, `ENV_*`, `NO_ERROR`) and flaky
rows (`known_flaky=True`) **must not** appear in `results.json` —
`submit.py` handles them automatically (auto → `AUTO_CLASSIFIED`; flaky
→ dropped).

## When to stop and ask the user

Do not guess — escalate when:

- Two pieces of evidence contradict each other (hunk suggests BUG, Jira
  says closed-as-env).
- The diff for a single case exceeds ~500 relevant lines (hunk
  extraction may be misconfigured).
- Confidence is low AND the component is outside the top 15 by LPD
  volume AND no Jira is linked.
- Reaching a confident classification would require more than 5
  additional tool calls.

## What not to do

- Do not classify `BUG` without naming a `culprit_file`. `submit.py`
  will reject the row. Downstream `pr_outcomes` training needs the
  labels.
- Do not re-classify a case already in `fact_triage_results` for this
  `(build_id_b, classifier)` without explicit user confirmation — the
  upsert will overwrite prior rows.
- Do not invoke `classify_api.py` from inside a Claude Code session.
  If you're reading this file, you are the classifier — running the
  API path here just duplicates work and burns credits. API mode is
  for Jenkins / headless environments.
- Do not write rows for pre-classified / flaky cases into
  `results.json`.
- Do not assume schema — see the root `CLAUDE.md` and
  `.claude/skills/triage.skill` for authoritative column names and
  join keys.
- Do not reference SonarQube — retired; lizard is the complexity source.

## API mode prompt-context strategies

Background: API mode (`classify_api.py`) sends only `prompt.md` to
Anthropic — the model has no filesystem access. Without help, the
per-failure hunk-matching heuristic in `prepare.py` is too narrow when
the real culprit is one transitive hop away (test → importer →
modified file). The api×api source case was hit hardest because
caseresults don't carry test names.

**Motivating case (build pair 468135639 → 468172457, 2026-04-25):**
Claude Code mode found `BundleSiteInitializerTest` was caused by an
LPD-86505 refactor of `LayoutsImporterImpl` — the test imports
`LayoutsImporter`, but the test class itself wasn't in the diff so
per-failure matching missed it. Original API mode classified
FALSE_POSITIVE.

### What's currently shipped (Path 2.1 — 2026-04-25)

`prepare.py` and `classify_api.py` together implement options
**E + A + B + rubric tightening**:

- **E. case_name enrichment for `api` source.**
  `prepare.py::fetch_case_metadata` looks up each failing case_id via
  Testray's `/o/c/cases/{id}` and backfills `test_case` + `known_flaky`.
  Without this, api×api had blank test names and the matcher had no
  anchor.
- **A + B. Manifest + commit cluster sections** baked into every
  `prompt.md` via `prepare.py::write_prompt`:
  - `## All changed files in this diff` — every changed file grouped
    by module folder, with line counts. Lets the model spot transitive
    candidates by path.
  - `## Commits in this range` — clustered by LPD/LPP/LPS ticket.
    Multi-commit clusters under one ticket often represent a single
    refactor; explicit candidate root causes for transitive failures.
- **Rubric tightening** in `PROMPT_HEADER` (and mirrored in
  `classify_api.py::_SYSTEM_INSTRUCTIONS`):
  - **Confidence-gated BUG.** BUG requires `high` confidence; medium
    confidence on a transitive theory → NEEDS_REVIEW.
  - **Multi-cause rule.** When 2+ ticket clusters in the diff plausibly
    affect the failing test's space, classify NEEDS_REVIEW (even at
    high confidence) with all candidates listed in `specific_change`
    separated by `; `.
  - **Transitive-dep section.** Explicit guidance not to dismiss
    failures because the test's name doesn't match a changed file path
    — a test class can fail because a file it imports changed.

### Future options (not implemented)

Documented for reference if the existing approach proves insufficient.

#### C. Expanded-match hunks

Add full hunks for files whose path matches a broader heuristic than
the test name (e.g. for `BundleSiteInitializer` broaden to
`Initializer | Layout | Importer | site-initializer-extender`). Falls
back to manifest-only when nothing matches.

Cost: variable, bounded by per-failure block cap. Risk: over-broadening
bloats context; under-broadening misses culprits anyway. Try if the
manifest-only signal isn't enough on a future build pair.

#### D. Tool-using API mode

Convert `classify_api.py` from single-shot to an Anthropic SDK
tool-runner loop with `bash`/`grep`/`read` tools scoped to the
liferay-portal repo. The model can then read source files (e.g. import
statements) directly to verify transitive deps — closing the structural
gap that motivates B and C.

Note: this is server-side tool use (Anthropic orchestrates the loop,
your Jenkins-side Python executes the tool calls). It does not require
Claude Code or any local agent — it's still pure HTTP API. Just bigger
to build, more failure modes (tool runaway, latency, cost), and the
SDK's tool runner is in beta.

Try this if Path 2.1 starts missing real bugs that source-file reading
would catch — i.e. the inverse of the over-assertion failure mode
Path 2.1 already addresses.

### Decision log

- **2026-04-25 (initial):** Documented as backlog. User leaning toward C;
  B is the cheaper validation experiment to confirm whether prompt
  augmentation alone closes the gap. If B works, C is the
  productionization. If B doesn't, the gap is deeper (likely
  tool-using API mode — much bigger build).
- **2026-04-25 (Path 2 ship):** Pair 2 experiment confirmed E + B is
  necessary but not sufficient. Without case_name enrichment (E), the
  api×api source has no test names → no anchor for transitive
  inference. Without the manifest+commits augmentation (B), the model
  can't see the offending changed file. With both, the model still
  *dismissively* concluded FALSE_POSITIVE because nothing in the
  rubric pushed back on overconfident dismissal of transitive theories.
  Path 2 = E + B + rubric softening biased toward NEEDS_REVIEW for
  borderline transitive cases. Validation result: Pair 2 case 82626318
  (BundleSiteInitializerTest) → NEEDS_REVIEW with `LayoutsImporterImpl.java`
  named in `specific_change`. Same culprit Claude Code mode found.
  Pair 1 agreement vs original API mode: 82.5% — disagreements mostly
  safe-direction (BUG → NEEDS_REVIEW, FP → NEEDS_REVIEW).
- **2026-04-25 (Path 2.1 tuning):** Pair 3 (468883224 → 469013940)
  comparison vs human triage report revealed Path 2 still over-asserted
  BUG on osb-faro compile failure where the human stayed at
  NEEDS_REVIEW. Two LPD clusters in the diff (LPD-87435 Service Builder
  template regen + a separate TypeScript/Jest rewrite) could plausibly
  explain it. Path 2.1 adds: (1) **confidence-gated classification** —
  BUG requires `high` confidence; medium on transitive → NEEDS_REVIEW;
  (2) **multi-cause rule** — 2+ ticket clusters affecting the failing
  test's space → NEEDS_REVIEW with all candidates listed in
  `specific_change`, even at high confidence. The osb-faro case
  satisfies condition (2) directly (LPD-87435 + separate TypeScript
  cluster).
- **2026-04-25 (Path 2.1 validation):** Re-ran Pair 3 with the new
  rubric — case 322933560 (osb-faro) shifted BUG → NEEDS_REVIEW with
  both LPD candidates listed in `specific_change`, matching the human
  report exactly. Confident BUGs on the same pair (5 compat-module
  + getCMSItemSelectorFilters) held. Pair 4 (468629046 → 468687189)
  spot-check vs second human report: ModulesStructureTest case
  classified BUG with the exact culprit_file (`mcp-server/build.gradle`)
  and ticket (LPD-86164) the human named — exact match. Status:
  **shipped** under classifier `api:claude-opus-4-7-path2.1`. Pair 1's
  88.6% agreement vs path2 includes 7 NR → FP shifts worth a future
  spot-check, but no clear regressions; safe-direction shifts dominate.
- **Side fix (2026-04-25):** `store.py::_safe_str` was truncating the
  `reason` column at 512 chars even though the DB type is TEXT
  (unbounded). Latent bug surfaced because Path 2.1's longer
  multi-cause reasons cross the threshold and clip the appended
  `[culprit_file=…]` suffix → `compare_classifiers.py` falsely reports
  "missing culprit on one side". Bumped `reason` and `specific_change`
  caps to 4000 chars. Existing path2.1 rows are already truncated;
  re-run if comparison fidelity matters for those.

## End of session summary — use this template

After `submit.py` completes, output a session summary in exactly this
shape. It's what stakeholders will read first; a consistent format
makes runs comparable over time.

```
## Triage report — build A (<id>) → B (<id>)  ·  routine <id>

<N> PASSED→FAILED/BLOCKED/UNTESTED transitions → <M> unique cases classified.

| Classification                | Count |
|-------------------------------|------:|
| BUG (caused by diff)          | <x>   |
| NEEDS_REVIEW                  | <y>   |
| FALSE_POSITIVE                | <z>   |
| AUTO_CLASSIFIED (breakdown)   | <w>   |

**Are the failures caused by the diff?** <direct answer: "Mostly no —
only X of M are clearly diff-caused." or "Yes — N of M trace to a single
regression in X.">

### BUG clusters

Group the <x> BUG rows by shared root cause (usually 2–5 clusters).

1. **<one-line cause>** (<count> failures) — culprit: `<file_paths>`.
   Affects: <list of failing tests or test-file shortnames>.
2. ...

### NEEDS_REVIEW worth a human look

<y> cases. One line each — why it's ambiguous and which component /
Jira ticket is worth checking.

- <case_id> <short test name> — <reason>
- ...

### Bundle + metadata

- Bundle: `apps/triage/runs/<run_id>`
- Classifier: `<classifier label>`
- BUG culprit_file coverage: <k>/<x> (<pct>% — target ≥85% during PoC,
  100% long-term)
- Flaky excluded: <n_flaky>
- Hunk-extraction coverage: <note if the filter barely narrowed the
  diff, e.g. "75MB of 83MB — huge window, filter minimally effective">
- Disagreement vs `batch:v1` (if prior rows exist): <pct>% on shared
  cases. Flag this as signal, not error.
```

### Why the "Are the failures caused by the diff?" line matters

That's the *actual question* stakeholders are asking. A breakdown table
without the verdict leaves the reader to do the math. Always follow the
table with a direct yes / no / mostly-no + the key number.

### Cluster rule

Don't just list BUG rows one by one. Group rows that share a culprit
file or a shared upstream cause (e.g. a feature flag flip, a JSP class
removal, a refactor that broke a common selector) into 2–5 clusters.
Each cluster names the culprit file(s) and the affected tests. This is
what converts raw counts into an engineering action plan.

## Classifier values

- `batch:v1` — legacy Sonnet-4 Anthropic-API pipeline, retired April
  2026. Historical rows only.
- `agent:claude-opus-4-7` — current default for in-session Claude Code
  classification. Override via `prepare.py --classifier …` if a
  different model/label is needed (e.g. `agent:claude-sonnet-4-6`).
- `api:claude-opus-4-7` — current default for `classify_api.py`
  (Jenkins / headless). Same model as Claude Code mode so the two
  paths are directly comparable.
- `human` — reserved for manual labels / corrections.
- `smoke:*` — throwaway labels for smoke tests; delete rows after.

Disagreement between classifiers is signal, not error — flag systematic
divergence in the session summary.
