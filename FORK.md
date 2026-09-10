# About this fork

This fork exists for one reason: on some Antigravity accounts, upstream
AI Usage reports quota that is not true.

It tracks [burakgon/ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)
and changes exactly one provider. Everything else — the app, the design, the
other seven providers — is upstream's work, unmodified. See
[LICENSE](LICENSE) and [NOTICE](NOTICE).

Reported upstream as
[issue #5](https://github.com/burakgon/ai-usage-menubar/issues/5).

## The problem

Google's Cloud Code endpoint is not authoritative for every Antigravity
account. Starter tiers answer `retrieveUserQuotaSummary` with
`403 PERMISSION_DENIED`, error `#3501`, while the CLI itself keeps reporting
accurate weekly numbers for the very same account.

Upstream mapped that 403 onto an authentication failure:

```swift
// AntigravityUsageClient.swift
if response.statusCode == 401 || response.statusCode == 403 {
    return .authentication
}
```

That single line caused two separate failures.

**The card claimed the session had expired.** The session was valid. The
OAuth refresh succeeded with HTTP 200 and the `aicode` scope, and
`loadCodeAssist` answered 200 on the same token. Only the quota endpoint
refused.

**It then discarded the last good reading.** An authentication failure does
not preserve state (`ProviderFailure.preservesLastGood`), so the previous
value was thrown away rather than kept.

Falling through to `fetchAvailableModels` was worse than showing the error.
That endpoint answers `remainingFraction: 1` for every model even when the
weekly quota is nearly exhausted, and the legacy mapper labelled all of it as
a *session* window on an account that has no session buckets at all. The
result was a confident, well-rendered lie:

| Card showed | Reality, from the CLI's own Models & Quota screen |
|---|---|
| Session: 100% left, resets in 6d 23h | no session bucket exists |
| Claude: 100% left, resets in 6d 23h | Gemini weekly: 38.7% left |

A usage meter that reads 100% when 61% is gone is worse than no meter.

## What this fork does

Quota is read from the source that is actually authoritative — the running
CLI. `agy` serves the same grouped payload its Models & Quota screen renders,
on a loopback HTTPS listener:

```
POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
Content-Type: application/json
Connect-Protocol-Version: 1

{}
```

Sources, most trusted first:

| Source | Used when |
|---|---|
| Running `agy` on its loopback listener | Whenever the CLI is running |
| Cloud Code summary endpoint | Accounts it does not deny |
| Last authoritative weekly reading | The CLI is closed |
| ~~`fetchAvailableModels`~~ | **Never** — it is not a usage source |

Details that matter:

- The self-signed certificate is accepted **only** for host `127.0.0.1`.
  Every other host keeps the system's default evaluation.
- Port discovery is restricted to the `agy` process. `lsof` ORs its
  selectors unless `-a` is given, and without it the app would probe every
  listening socket on the machine.
- A listener that answers without quota groups — the remote-control daemon
  rejects unauthenticated calls with `missing CSRF token` — is ignored rather
  than treated as data.
- Only the buckets the account actually returns are mapped. No session
  window is invented for a weekly-only account.
- Cached windows whose `resetTime` has passed are dropped, not shown stale.
  A refreshed window is not 100% consumed, and guessing its new value would
  repeat the bug this fork exists to fix.

Verified end to end against a real account: the app reads `gemini-weekly`
and `3p-weekly` and renders values identical to the CLI.

## Where this fork deliberately differs from upstream policy

Upstream states, in `CONTRIBUTING.md`, to avoid *"persistent usage history"*,
and the README lists *"Nothing is cached across launches"* as a property.

**This fork persists one reading anyway**, and the reason is specific rather
than casual. Every other provider can be re-read on demand. This one cannot:
its accurate summary is served by a CLI that is only running some of the
time. Without persistence the card would be empty whenever `agy` is closed,
which is most of the time.

What is stored is one weekly reading — used percentage and reset time — not
a history, and it is only stored when it came from the authoritative source.
Weekly windows span seven days, so a reading taken hours ago still describes
the same window.

The cached value is returned as a normal reading rather than as a failure,
so the panel shows no warning banner and the menu bar shows no stale glyph
while the CLI is closed. A permanent warning about a number that is still
correct trains people to ignore warnings.

Anyone who prefers upstream's policy can drop the last source in
`AntigravityProvider.fetch()`; the rest of the fix stands on its own.

## Build and install

Requires macOS 26+. Upstream asks for Xcode 27; this builds on Xcode 26.6.

```bash
git clone https://github.com/<your-account>/ai-usage-menubar.git
cd ai-usage-menubar
git checkout fix/antigravity-local-quota

xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO build
```

Install the result:

```bash
BUILT=~/Library/Developer/Xcode/DerivedData/AIUsage-*/Build/Products/Release/"AI Usage.app"
osascript -e 'quit app "AI Usage"'
mv "/Applications/AI Usage.app" ~/.Trash/
ditto $BUILT "/Applications/AI Usage.app"
codesign --force --deep --sign - "/Applications/AI Usage.app"
open -a "/Applications/AI Usage.app"
```

That final `codesign` is not optional. The app binary is signed ad-hoc while
the bundled Sparkle.framework keeps its original Developer ID signature, and
macOS refuses to load a bundle whose Team IDs disagree:

```
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
Reason: ... mapping process and mapped file (non-platform) have different Team IDs
```

Run the tests with:

```bash
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage \
  -destination 'platform=macOS'
```

## Limitations

- Live values require `agy` to be running. Otherwise the last weekly reading
  is shown, which stays valid for the rest of the window.
- Local builds are neither Developer ID signed nor notarized. Upstream's
  releases are both; this fork ships no binaries.
- Installing an upstream release replaces this build and removes the fix.
  Sparkle only notifies, it does not install on its own.
- The `agy remote-control` daemon keeps the endpoint alive permanently, which
  would make values always live, but it requires a CSRF token
  (`x-codeium-csrf-token`) held in memory rather than on disk. Not pursued
  here. `ANTIGRAVITY_CSRF_TOKEN` is the starting point for anyone who wants
  to try.

## Relationship to upstream

This is a fix, not a competing project. If upstream adopts it, this fork has
no reason to exist. Credit for AI Usage belongs to
[Burak Gon](https://github.com/burakgon), and the provider-contract research
it builds on belongs to [OpenUsage](https://github.com/robinebers/openusage),
as recorded in [NOTICE](NOTICE).
