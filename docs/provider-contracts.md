# Provider contracts

This document records the narrow external contract used by AI Usage. It is
intentionally limited to quota windows that can be fetched from credentials
the supported tools already store locally.

The reference implementation was OpenUsage `v0.7.6`, plus provider updates
through commit `9d2bf09f10e21f769494a525a9d65c84d7aeb1df`. These are
undocumented provider endpoints and may change; fixture tests protect the
currently known behavior.

## Claude Code

Credential source order:

1. macOS Keychain current-user item
2. macOS Keychain legacy service-only item
3. `$CLAUDE_CONFIG_DIR/.credentials.json`, otherwise
   `~/.claude/.credentials.json`

The production Keychain service is `Claude Code-credentials`. With
`CLAUDE_CONFIG_DIR`, the app first tries the service suffixed with the first
eight lowercase SHA-256 characters of the normalized directory, then the
production service.

`CLAUDE_CODE_OAUTH_TOKEN` is not a live-usage credential and is never selected.
A stored non-empty `scopes` array must contain `user:profile`; absent or empty
scope metadata is treated as unknown and allowed.

Usage request:

- `GET https://api.anthropic.com/api/oauth/usage`
- `Authorization: Bearer <access token>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent: claude-code/2.1.69`

Mapped fields:

| JSON field | UI row |
| --- | --- |
| `five_hour.utilization` | Session |
| `seven_day.utilization` | Weekly |
| `seven_day_sonnet.utilization` | Sonnet |
| `limits[kind=weekly_scoped, scope.model.display_name=Fable].percent` | Fable |

Every row reads `resets_at`, accepting ISO-8601 with variable fractions and no
timezone (assumed UTC), epoch seconds, or epoch milliseconds.

Refresh request:

- `POST https://platform.claude.com/v1/oauth/token`
- JSON body with `grant_type`, `refresh_token`, `client_id`, and `scope`
- client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- scope string:
  `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`

The access token is refreshed within five minutes of `expiresAt` (epoch
milliseconds). A usage `401` or `403` causes at most one refresh and one retry.
`invalid_grant` means the session expired. A `429` honors `Retry-After`
(seconds or HTTP date) and otherwise starts a five-minute cooldown, including
manual refreshes.

The display plan is title-cased `subscriptionType`, plus an `Nx` fragment
extracted from `rateLimitTier`.

## Codex

Credential source order:

1. `$CODEX_HOME/auth.json`, when `CODEX_HOME` is set
2. otherwise `~/.config/codex/auth.json`
3. then `~/.codex/auth.json`
4. macOS Keychain service `Codex Auth`

An auth document uses `tokens.access_token`, `refresh_token`, `id_token`, and
`account_id`, plus top-level `last_refresh`. A document containing only
`OPENAI_API_KEY` produces “Usage not available for API key.”

Usage request:

- `GET https://chatgpt.com/backend-api/wham/usage`
- `Authorization: Bearer <access token>`
- optional `ChatGPT-Account-Id`

The main `rate_limit.primary_window` and `secondary_window` objects use
`used_percent`. Response headers `x-codex-primary-used-percent` and
`x-codex-secondary-used-percent` are fallbacks.

Windows are classified by `limit_window_seconds`:

- `18000`: Session
- `604800`: Weekly
- unknown or missing duration: primary/secondary slot fallback

The first `additional_rate_limits` entry whose `limit_name` or
`metered_feature` contains `spark` case-insensitively is mapped through the
same classifier to Spark and Spark Weekly.

Reset time uses epoch-seconds `reset_at`, then relative
`reset_after_seconds`. The display plan maps `prolite` to `Pro 5x`, `pro` to
`Pro 20x`, and title-cases other underscore-separated values.

Refresh request:

- `POST https://auth.openai.com/oauth/token`
- `application/x-www-form-urlencoded`
- client ID `app_EMoamEEZ73f0CkXaXp7hrann`

JWT `exp` is the primary refresh clock with five minutes of slack. Only when
`exp` cannot be decoded does `last_refresh` older than eight days trigger a
refresh. With neither value, no proactive refresh occurs. Before proactive
refresh, the exact credential source is re-read so a token already rotated by
the Codex CLI is adopted.

The recognized refresh failures are `refresh_token_expired`,
`refresh_token_reused`, and `refresh_token_invalidated`. A usage `401` or `403`
causes at most one refresh and one retry.

## Additional providers

| Provider | Local credential source | First-party usage contract | Mapped metrics |
| --- | --- | --- | --- |
| Cursor | Cursor state SQLite database, then `cursor-access-token` and `cursor-refresh-token` Keychain items | `api2.cursor.sh` DashboardService Connect RPCs | Total, Auto, API |
| Antigravity | Keychain service `gemini`, account `antigravity` | Google Cloud Code quota-summary API, with model-quota fallback | Gemini session/weekly, Claude session/weekly |
| GitHub Copilot | Copilot editor config, GitHub CLI config, then `gh:github.com` Keychain item | `api.github.com/copilot_internal/user` | Credits, Chat, Completions |
| Devin | `~/.local/share/devin/credentials.toml`, then Devin state SQLite database | Codeium SeatManagement Connect RPC | Daily, Weekly |
| Grok | `~/.grok/auth.json` | Grok CLI billing and settings APIs | Weekly |
| DeepSeek | `deepseek` entry in `~/.local/share/opencode/auth.json`, then `~/.config/opencode/auth.json`, then `DEEPSEEK_API_KEY` | `api.deepseek.com/user/balance` | Balance |
| QwenCloud personal Token Plan | Existing Chromium browser console session | QwenCloud console gateway | 5-Hour, Weekly, Monthly |

Cursor, Antigravity, and Grok refresh expiring access tokens using the refresh
credential already stored by the corresponding tool. Refreshed tokens are
persisted only where necessary; Antigravity's derived access token is cached
privately by AI Usage and bound to a hash of the current refresh credential.

The OpenCode Zen/Go subscription provider has been removed. OpenCode CLI auth
files remain a credential source for DeepSeek, MiniMax, and GLM, each of which
queries its own service. OpenRouter remains unsupported.

## Persistence and failure policy

Rotated credentials are persisted only to the source from which they were
loaded. Claude compares the complete ordered credential generation before
writing and again before publishing usage. Codex compares the exact source
before writing. This prevents an in-flight refresh from overwriting a new CLI
login.

Temporary network failures, `429`, server errors, and invalid response shapes
preserve the last-good in-memory snapshot and mark it stale. Authentication and
storage failures clear that provider's snapshot.


## Kimi membership usage

Kimi uses the existing CLI login; no separate API key or browser session is
required. The new CLI stores OAuth credentials in
`~/.kimi-code/credentials/kimi-code.json`. Legacy file-based CLI credentials in
`~/.kimi/credentials/kimi-code.json` are also supported. `KIMI_CODE_HOME` and
`KIMI_SHARE_DIR` override these directories. Managed provider configuration
selects the credential slot and official regional endpoint:
`https://api.kimi.com/coding/v1` or `https://api.kimi.ai/coding/v1`.

- `GET /usages` supplies quota ratios and reset timestamps.
- `GET /me` supplies the actual membership badge through `user_level_name`.
- `POST /api/oauth/token` on the matching `auth.kimi.com` or `auth.kimi.ai`
  host refreshes expired OAuth credentials. Rotated credentials are saved
  atomically with private permissions; a detected concurrent CLI login is
  preserved instead of overwritten.

The current quota contract exposes `usages.limit_5h`, `limit_7d`,
`limit_month_total`. The `limit_month_code` attribution is not displayed as a quota. Only returned, valid quotas are
shown. The Plus account verified during implementation returns 5-hour,
monthly total, and monthly code quotas; it does not return a weekly quota.
The monthly total is selected by default for the menu bar. Monthly code is a
separate selectable metric. Older counter-based responses are also supported.
Missing or invalid limits are never interpreted as zero usage.

If present, the `BOOSTER` wallet balance is displayed in its currency. Wallet
amounts use fixed-point millionths of a cent, independently of membership
quota percentages. Profile failures do not hide valid usage readings.

These are read-only membership requests; they do not generate model usage.
To connect an account, run `kimi login`. Existing installations automatically
add Kimi once while preserving subsequent tracking opt-outs.

Sources: [Kimi Code CLI](https://github.com/MoonshotAI/kimi-code),
[legacy CLI usage implementation](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/ui/shell/usage.py),
and [membership benefits](https://www.kimi.ai/help/kimi-code/benefits).
The monochrome Kimi icon follows the official documentation favicon.


## MiniMax Token Plan

MiniMax reads the existing Subscription Key from OpenCode's auth file:
`~/.local/share/opencode/auth.json`, or `~/.config/opencode/auth.json`.
`XDG_DATA_HOME` overrides the first directory. Recognized entries are
`minimax-coding-plan` and `minimax-cn-coding-plan`. Generic `minimax` entries
are accepted only when the key has the Subscription Key prefix `sk-cp`;
ordinary pay-as-you-go keys are not treated as Token Plan credentials.
`MINIMAX_API_KEY` and `MINIMAX_CN_API_KEY` may also supply a Subscription Key.
Only installations with a matching credential are considered available.

The global endpoint is `https://www.minimax.io`; the China endpoint is
`https://www.minimax.cn`. Both requests are read-only and use Bearer auth:

- `GET /v1/token_plan/remains` supplies quota percentages and reset times.
- `GET /v1/api/openplatform/charge/combo/cycle_audio_resource_package`, with
  `biz_line=2`, `cycle_type=1`, and `resource_package_type=7`, is the console's
  subscription query. Its `current_subscribe.current_subscribe_title` supplies
  the badge. Current subscription data takes priority over advertised packages.

The current unified `general` bucket maps to 5-hour and weekly bars. Remaining
percentages are authoritative even when absolute counters are zero. Used
percentage is `100 - remaining_percent`; millisecond end timestamps are
converted to dates. Countdown fields are never treated as consumed quota.
Legacy responses without percentages use remaining-count semantics, matching
MiniMax's CLI. Duplicate legacy model quotas retain the most consumed reading.
Buckets marked not included, such as the Plus response's video row, are omitted.
A monthly billing cycle is not interpreted as a monthly quota window.

A successful HTTP response still requires `base_resp.status_code == 0`.
Authentication, rate-limit, unavailable-service, missing-subscription, and
malformed-data failures remain distinct. Missing quota data is never reported
as zero usage. A failed subscription lookup preserves usable quota readings
and falls back to the neutral badge `Token Plan`, without guessing a tier.

MiniMax is added to existing tracking preferences once, persisted across
restarts, and respects subsequent opt-outs. Weekly is the default menu bar
metric; 5-hour usage can also be selected. The API does not require OpenCode
to be running and these queries do not generate model usage.

Sources: [official Token Plan FAQ](https://platform.minimax.io/docs/token-plan/faq),
[official CLI quota semantics](https://github.com/MiniMax-AI/cli/blob/main/src/utils/quota.ts),
and the subscription page's first-party console client. The MiniMax icon is
sourced from [models.dev](https://github.com/anomalyco/models.dev/blob/dev/providers/minimax/logo.svg).


## GLM Coding Plan (Z.ai)

GLM reads the `zai-coding-plan` API credential from OpenCode's
`$XDG_DATA_HOME/opencode/auth.json` (default `~/.local/share/opencode/auth.json`),
with `~/.config/opencode/auth.json` as a fallback. `ZAI_API_KEY` takes precedence.
Generic pay-as-you-go `zai` credentials are not automatically selected.
Availability requires a matching key; OpenCode need not be running.

The read-only `GET https://api.z.ai/api/monitor/usage/quota/limit` uses the raw API
key in `Authorization`, following the official Z.ai usage plugin. Both HTTP
status and the API envelope (`code: 200`, `success: true`) must indicate success.
HTTP or API 401/403 responses are authentication failures. HTTP 429 and server
errors retain the last successful snapshot under the existing stale-data rules.

`data.level` supplies the plan badge, including `lite` → `Lite`. A missing level
uses `Coding Plan`, without guessing the subscription from quota limits.
`data.limits` supports `CREDIT_LIMIT` and legacy `TOKENS_LIMIT`: unit 3/number 5
is the 5-hour window, and unit 6/number 1 is weekly. `TIME_LIMIT` unit 5/number 1
is shown separately as `MCP Monthly` when supplied. Only returned, valid windows
are displayed; monthly model usage is not inferred.

`percentage` is consumed usage on a 0–100 scale. The service can round this value
independently of its credit counters, so the reported percentage is authoritative.
`nextResetTime` is a Unix timestamp in milliseconds. Unknown quota types and
missing or invalid percentages never become zero-consumption readings.
Duplicate windows retain the most consumed reading.

GLM tracking is enabled once for existing installations and persisted immediately;
subsequent user opt-out is preserved. Tests cover credentials, the current Lite
response, legacy tokens, MCP separation, errors, request authentication, settings,
and preference migration. The installed OpenCode account was also verified with
a temporary read-only integration test; no credentials are stored in the project.

Sources: [official usage query documentation](https://docs.z.ai/devpack/extension/usage-query-plugin),
[official query script](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs),
and the live quota response. The icon comes from
[models.dev](https://github.com/anomalyco/models.dev/blob/dev/providers/zai/logo.svg).


## Kimi overlapping five-hour formats

Some current responses contain both named ratio windows and absolute `limits`
counters. A live response reported `limit_5h.used_ratio: 0` alongside a 300-minute
counter with `used: 100` and `limit: 100`. Both describe supported five-hour
limits. The mapper now considers absolute counters even when named ratios exist
and retains the most consumed five-hour reading, including its reset timestamp.
Monthly named windows remain independent, and a legacy weekly summary is only
used when named windows are absent. Regression tests cover contradictory ratios,
exhaustion, reset selection, and retaining a higher ratio.


## Kimi monthly Code Share semantics

The official installed Kimi Code CLI 2.1.1 parses `limit_month_total` and
`limit_month_code`, but renders them as a single monthly pool with a breakdown.
Its `monthlyBreakdown` function calculates `codeRatio` from `monthCode.usedRatio`
and `kimiRatio` from `monthTotal.usedRatio - codeRatio`. Thus the code value is
consumption attributed to Code, not an independent remaining allowance.

The app displays only actionable quota windows: five-hour, monthly total, and
weekly for legacy accounts. Code attribution is omitted from cards and menu-bar
choices. Old `codeMonthly` selections are filtered without removing the user's
other selections; the enum identifier is retained only for decoding old preferences.

A live response reported 100/100 five-hour requests, 0.0621 monthly total usage,
and 0 code share. The app displays the service's zero contribution without
asserting why attribution is zero or estimating a minimum 1% from request counts.
The server may have separate attribution/accounting behavior; no reliable local
conversion between requests and monthly token-based credits is available.

Sources: the installed official CLI's `parseQuotaUsages`, `quotaUsageRows`, and
`monthlyBreakdown` functions, plus the
[official shared-credit rules](https://www.kimi.com/en/help/membership/membership-update-rules)
and [monthly quota documentation](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html).
