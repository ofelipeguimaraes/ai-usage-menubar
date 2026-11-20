# macOS App Data permission (macOS 26+)

Reading a Chromium cookie store means reading another app's data. macOS 26 gates
that behind the TCC **App Data** grant (`kTCCServiceSystemPolicyAppDataDetailed`),
and an unanswered consent prompt is recorded as a silent, permanent denial: macOS
shows a "access to data blocked" notification pointing at Settings instead of an
Allow/Deny dialog, and never re-prompts.

## Symptoms

- Before the fix: `ChromiumCookieReader.session` swallowed the permission error
  (`try?`), so providers reported a missing sign-in ("Sign in at … in Brave, Chrome,
  Arc or Edge.") while the browser session was perfectly valid.
- After the fix: a `ProviderFailure(.permission, …)` surfaces with an actionable
  message, a lock icon in the panel and "Permission needed" in Settings.
- Debugging trap: launched from a terminal the app inherits the terminal's grant
  (responsible process), so the same binary works there and fails when launched
  normally. Compare contexts before suspecting the code.

Evidence lives in the unified log:
`log stream --predicate 'process == "tccd"' --level debug` shows
`Handling access request to kTCCServiceSystemPolicyAppDataDetailed … Denied`.

## Granting the permission

System Settings → Privacy & Security → **Files & Folders** → AI Usage → per-browser
switches (Brave Browser, Google Chrome, Microsoft Edge). There is no Allow button in
this flow; the toggle is the grant.

## Local builds and the CDHash caveat

Ad-hoc signed local builds are identified by CDHash. Every rebuild produces a new
TCC identity and orphans the grant given to the previous binary, so after running
`scripts/install.sh` the permission must be granted again. Signing releases with a
stable identity would remove this; until then, re-grant after each rebuild.

## Regression tests

`AIUsageTests/MapperTests.swift`, `ChromiumCookieReaderTests`:

- `testSurfacesAppDataDenialInsteadOfMissingSession` — an unreadable browser store
  (permission denied) throws `.permission`, not a nil session.
- `testMissingBrowserStoreStaysMissingSession` — an absent browser store still
  returns nil (genuinely signed out).

## Incident record

2026-11-20: commits `a9810e9` (surface the denial) and `c8821d1` (correct Settings
pane name). Companion operational record in the private `ai-agents` repo:
`docs/openclaw/42-incidente-qwen-cota-app-data.md`.
