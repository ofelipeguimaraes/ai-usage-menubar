# Fork compatibility and plan-name audit

Reviewed on 2026-09-26 against freshly fetched `origin/main` at
`3df27e9081192bc5c954f932e4e807e097a49c02` (upstream 0.2.1).
The merge base is that same commit: the fork adds changes on top of this upstream
revision rather than diverging from a separate implementation.

## Compatibility

The native SwiftUI/AppKit app, provider protocol, snapshot types, authentication
stores for original providers, existing preference keys, and refresh/store
architecture remain in place. Claude, Codex, Cursor, Copilot, and Devin provider
implementations are unchanged from the fetched upstream. Grok received a small
validation correction during this audit. Existing raw provider/metric identifiers
were preserved; new cases extend the catalog. Tracking migrations run once and
respect subsequent opt-out.

Intentional differences are additional OpenCode, DeepSeek, Qwen, Kimi, MiniMax,
and GLM integrations; authoritative Antigravity local quotas and an account-bound
weekly cache; panel sizing, scrolling and card layouts; and removal of Sparkle.
These touch shared UI and preferences, so upstream changes require normal merge
review. This is source-compatible architecture, not a guarantee that future
upstream commits can always merge without conflicts. The updater is disabled,
Sparkle is not linked, and the remaining dormant update button has been removed.
The bundle identifier remains upstream's: installing one app over the other
replaces the binary and shares preferences. Running both as separate independent
installations is not supported by this fork.

The old release script still required Sparkle tools and upstream signing keys.
It now selects an ad-hoc fork DMG packaging path when Sparkle is absent, preserving
the original path for builds that include it. Shell syntax was checked; the full
release packaging/notarization pipeline was not executed in this audit. No version
bump, tag, or release was created.

## Plan-name provenance

| Provider | Badge source | Scope and limitations |
| --- | --- | --- |
| Claude Code | CLI OAuth `subscriptionType`, optional multiplier from `rateLimitTier` | Local CLI metadata, not a new live subscription query; missing metadata gives no guessed badge. |
| Codex | Usage API `plan_type` | Known service identifiers `prolite`/`pro` are formatted as Pro 5x/20x; other identifiers remain readable. These mappings are inherited unchanged from upstream. |
| Cursor | API `planInfo.planName` | Failed cosmetic lookup leaves the badge unavailable rather than assigning a tier. |
| Antigravity | `loadCodeAssist.paidTier.name`, then `currentTier.name` | Paid tier wins; known names are shortened. Cached fallback is bound to the login credential. CLI quotas support recognized returned buckets only. |
| GitHub Copilot | API `copilot_plan` | Known identifiers are formatted; unknown identifiers retain their title. |
| Devin | API `planInfo.planName` | No user-specific tier. |
| Grok | API `subscription_tier_display` | Returned display name preserved; absent name is not assumed to be SuperGrok. |
| DeepSeek | `API` service label | This is not a subscription tier. The API exposes balance, not a paid plan name. |
| OpenCode | Successful Go-entitlement quota endpoint → `Go` | Zen is pay-as-you-go. The old fixed `Zen` badge and fabricated monthly quota were removed. Structured missing-Go entitlement confirms Zen and shows a normal informational card; unstructured denial never identifies a plan. |
| QwenCloud | Console subscription `specCode` | Missing subscription lookup falls back to `Token Plan`, a service label; personal international console plans only. |
| Kimi | Profile API `user_level_name` | No Plus default; both official API regions and legacy/current CLI credential layouts are supported. |
| GLM (Z.ai) | Quota API `data.level` | No Lite default; unknown nonempty tiers are preserved. Missing level gives `Coding Plan`. Global Z.ai credentials are supported, not arbitrary China/BigModel accounts. |
| MiniMax | Console `current_subscribe.current_subscribe_title` | Known tier words are shortened, unknown titles preserved; missing lookup gives `Token Plan`. Both global/China keys are supported. |

No production provider contains Felipe's home path, email, account ID, or a
subscription assignment based on his identity. Paths use the current user's home,
standard CLI storage, or supported environment overrides. API hostnames, OAuth
client IDs, quota bucket identifiers, and region/commodity codes are service
contracts, not user identifiers. This does not mean every account type, browser,
region, or future API response is supported: Qwen uses supported Chromium browser
sessions, GLM is global-only, and upstream APIs may change. Plan formatting tests
cover multiple known and unknown tiers; they do not substitute for live access to
every possible subscription. Live verification from earlier integrations used
only the available accounts and did not store secrets in the project.

## Corrections and validation

- Removed OpenCode's fixed two-million-token denominator and local SQLite scan.
  Only server-returned Go quotas are shown. API-confirmed Zen accounts use a normal pay-as-you-go card with a console link; no balance or allowance is invented.
- Grok rejects missing/nonfinite percentages instead of showing zero usage.
- DeepSeek supports custom OpenCode data directories and API credential types;
  its environment key is also captured for menu-bar launches from Finder.
- Removed the dormant dashboard update control, retained an inert controller for
  internal API compatibility, and corrected stale updater/provider documentation.
- Added regression tests for official OpenCode quota parsing, credential separation,
  missing Grok usage, DeepSeek paths, and multiple/unknown plan names.

Sources and detailed provider response contracts are recorded in
[provider-contracts.md](provider-contracts.md). The audit verifies implementation
and test behavior, not a contractual compatibility promise from any provider.
