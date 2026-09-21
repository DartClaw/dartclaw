# Search verification follow-up

Date: 2026-09-15
Baseline commit: `a92872b9` (`fix: resolve 0.27 review findings`)
Scope: search verification and causally connected controller/test fixes.

## Result

The final canonical `search-commands` run passed its search and command assertions through network-failure handling, then stopped at the existing accessibility incomplete. A separate focused browser run passed deleted-target handling, network failure and successful subsequent search with the draft retained. The original stuck-search failure is resolved; there is no passing full browser qualification receipt.

The 80-file review checkpoint was committed on `feat/0.27`. All 65 pre-existing staged documents were preserved byte-for-byte. The four tracked follow-up files remain uncommitted: controller, controller tests, browser profile and CHANGELOG.

## Findings and fixes

### SEARCH-ERROR – tokenless HTTP errors leave search pending

- Severity: MEDIUM. Disposition: Fix.
- Location: `packages/dartclaw_runtime/lib/src/static/controllers/dc_conversation_command_controller.js`, `search()`.
- Evidence: a real browser request completed with HTTP 503 and `SEARCH_RESULTS_CHANGED`. Its error envelope had no `request_token`. After ten seconds the current dialog still showed “Searching…”. The combined generation/token guard returned before processing the HTTP error.
- Fix: reject superseded generations first, handle HTTP errors next, and apply the echoed-token check only to successful results. Server errors clear old results and display their message. Successful and failed superseded requests remain unable to change the current UI.
- Verification: the regression failed with `tokenless search failure stayed pending` before the fix; the focused file passed all seven tests afterward. The harness also checks that a stale error cannot clear or overwrite a newer success.

### SEARCH-TRANSPORT – network failures expose browser-specific text

- Severity: MEDIUM. Disposition: Fix.
- Location: the same `search()` error path.
- Evidence: rejected fetch promises supplied their raw message to the dialog, while the browser contract expected the deliberate unavailable state.
- Fix: retain a local generic unavailable message for transport/parse failures; preserve explicit server error-envelope messages. No retries, exception-text matching or server snapshot-policy changes were added.
- Verification: the regression failed with `network failure exposed a raw browser error` before the fix; the focused file passed all seven tests afterward. The browser network-abort probe displayed “Search is unavailable”; removing the fault and issuing a subsequent search returned the expected result without changing the draft.

## Fixture synchronization

Search checks now flush the existing visible-read handler and await its acknowledgement before the initial query and after Back. These reads change conversation revisions and must settle before assertions requiring a stable snapshot. The initial result check waits for the exact expected result element, retaining the three-result count, identity, citation, escaped-highlight and keyboard assertions. The network-failure probe runs before the accessibility audit so that an accessibility hold cannot prevent observing its result.

The final canonical run executed exact search outside the loaded history window, bounded target navigation, Back/query/draft/position restoration, owner/agent aggregation, lifecycle/project filters, superseded searches, announcements, deleted targets, typed commands, native skills, stale native selection, byte-exact unknown slash submission, network failure and focus checks. The focused recovery run additionally verified a successful query after removing the injected network fault.

## Verification and limits

- Full workspace invocation: **12,191 passed, 55 configured skips**, all 15 suites completed.
- Format: **2,095 files, zero changes**. Analyzer: no issues.
- Fitness: **124 tests** plus development-script checks passed. Both canonical binaries built. Final browser shell syntax and whitespace checks passed.
- Architecture: the same two unapproved package-size ceilings fail. No ceilings changed.
- PostgreSQL was not rerun for this controller/profile-only follow-up; the preceding campaign's 104-test result remains historical evidence.
- Independent review found no notable regressions in the follow-up source changes.
- Final canonical browser exit: **1**, solely at the reached accessibility audit: zero violations, one incomplete contrast check on the lifecycle select's gradient background. Subsequent zoom/computed-style and knowledge-tab checks were not executed in this final run. This report does not claim their qualification.
- Earlier failed diagnostic/canonical attempts are retained. The final successful functional assertions do not erase them or imply an all-green integrated receipt.

## Evidence

Paths below are relative to `.agent_temp/reviews/0.27/`:

- `search-recheck-3/browser-eval.log`: real tokenless 503 and persistent searching state.
- `search-fix-gate-status.tsv` and `search-fix-*.log`: repository checks and builds.
- `search-canonical-read-flush.log` and `search-canonical-read-flush/`: final canonical run, screenshots and strict accessibility report.
- `search-recovery-focused.log` and `search-recovery-focused/`: deleted-target 404, injected network failure and successful recovery.
- Focused red/green results were observed directly in the implementing agent's tool outputs; separate red/green log files were not saved.

## Remediation Status

- **SEARCH-ERROR – Fixed.** Regression-proven error handling; stale-response protection retained.
- **SEARCH-TRANSPORT – Fixed.** Regression and actual-browser failure/recovery checks passed.
