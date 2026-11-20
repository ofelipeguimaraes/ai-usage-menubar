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

## macOS 27: switches flip back for ad-hoc builds

On macOS 27.2 the per-browser App Data switches for ad-hoc signed builds
revert to off immediately after being enabled (observed live, both by hand
and through accessibility). The same update also started denying the hourly
launchd cookie push of the companion `ai-agents` repo (`PermissionError
[Errno 1] Operation not permitted` on the Brave root): both readers lost
their grants at the update, while terminal-launched reads kept working
because the terminal holds its own grant.

Fix: sign local builds with a stable identity instead of ad-hoc:

    ./scripts/sign-local.sh     # once; creates ~/.config/aiusage-sign
    ./scripts/install.sh        # re-signs automatically afterwards

The grant then keys to the certificate, not the CDHash, and survives
rebuilds.

Validated recovery sequence on macOS 27.2.1 (the switches only stick after
all of it, in order):

1. `./scripts/sign-local.sh` — dedicated keychain + self-signed identity.
2. Trust the certificate for code signing, otherwise the identity stays
   `CSSMERR_TP_NOT_TRUSTED` and grants still revert:
   `security add-trusted-cert -r trustRoot -p codeSign -k ~/.config/aiusage-sign/signing.keychain-db ~/.config/aiusage-sign/cert.pem`
3. `tccutil reset SystemPolicyAppData com.burakgon.aiusage` and the same
   for `SystemPolicyAppDataDetailed` — clears the poisoned denial record
   whose switches flip back off.
4. Re-enable the per-browser switches once; they persist. tccd then logs
   `kTCCServiceSystemPolicyAppDataDetailed … Allowed (User Consent)`.

Do not reset TCC or flip the switches again without need once healthy.

Known pending (separate task): the companion launchd cookie push runs
`/usr/bin/python3`, an xcode-select shim (`com.apple.dt.xcode_select
.tool-shim-public`); its denial is *Service Policy* — Apple binaries cannot
be granted App Data through the UI. Proposed fix: a signed wrapper launcher
between launchd and python so the responsible process is a third-party
identity. Until then the terminal-side `/qwen-cota --force` refreshes the
container session.

## Incident record

2026-11-20: commits `a9810e9` (surface the denial) and `c8821d1` (correct Settings
pane name). Companion operational record in the private `ai-agents` repo:
`docs/openclaw/42-incidente-qwen-cota-app-data.md`.
