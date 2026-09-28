# Claude Desktop, Claude Code and Anthropic's API, as csw sees them

csw drives parts of Claude it does not own: Desktop's data directory, Claude Code's CLI, and Anthropic's OAuth-backed endpoints. None of this is a documented contract. Each fact below was observed on macOS in September 2026 (Claude Code 2.1.28x, Desktop 2.99xx); re-check it when behavior changes.

## Logins

- Each profile's Claude Code login is JSON under `claudeAiOauth` in the Keychain: `Claude Code-credentials` for the active profile, `csw-code-<profile>` for saved ones. It carries `accessToken`, `refreshToken`, `expiresAt` (ms), and `refreshTokenExpiresAt`.
- Saved access tokens expire within hours, so reading an inactive profile's usage means refreshing first: `POST https://platform.claude.com/v1/oauth/token` with `{"grant_type":"refresh_token","refresh_token":…,"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`. `console.anthropic.com/v1/oauth/token` returns 404.
- The token endpoint sits behind Cloudflare, which rejects curl's and Python's default user agents with `error code: 1010`. Send a CLI-style `User-Agent` (`src/http.zig` owns it).
- **A refresh rotates the refresh token.** The new login must be written back before anything else uses it (`keychain.update`, in place with `-U`), and any other copy of the old token is dead. Two tools refreshing the same saved login invalidate each other: running `claude-swap` alongside csw left both overflow profiles answering `invalid_grant` ("Refresh token not found or invalid"). The only recovery is signing in again: `csw use <p>`, `claude auth login --email <addr>`, `csw save <p>`.

## Endpoints (Bearer = the profile's access token)

- Usage: `GET https://api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`. Returns `five_hour` and `seven_day` blocks with `utilization` (percent) and `resets_at` (ISO 8601 with fractional seconds and offset); either block can be `null`.
- Cloud sessions: `GET https://api.anthropic.com/v1/sessions?limit=50`, headers `anthropic-beta: ccr-byoc-2025-07-29`, `anthropic-version: 2023-06-01`, `x-organization-uuid: <org>`. Pages with `has_more` / `last_id`; the next page is `&after_id=<last_id>`. `environment_kind` is `anthropic_cloud` for cloud sessions and `bridge` for local sessions served over Remote Control. `session_status` is `running`, `idle`, `requires_action` or `archived`. The repo is in `session_context.sources[].url` (type `git_repository`) and the branch in `external_metadata.current_branches`.

## Claude Desktop's local Code sessions

- One JSON record per session at `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<organizationUuid>/local_*.json`. The two ids come from `oauthAccount` in the profile's `~/.claude.<profile>.json`. Records hold `sessionId`, `cliSessionId`, `cwd`, `title`, `isArchived`, `createdAt`, `lastActivityAt`.
- Desktop reads the records only at launch; a record written while it runs appears after a restart. A record written from outside with a matching history file is listed and continues from that history.
- History: `~/.claude.<profile>/projects/<slug>/<cliSessionId>.jsonl` plus a same-named directory (subagents, tool results). `<slug>` is the `cwd` with every non-alphanumeric character replaced by `-`.
- Each running session is a separate process `…/Application Support/Claude/claude-code/<ver>/claude.app/Contents/MacOS/claude … --resume=<cliSessionId>`. `pkill -x Claude` (what `csw use` does) does not end them, so anything copying history after a quit waits for these first (`src/sessions.zig`).

## Claude Code CLI, unattended

- `claude -p --resume <id> --fork-session` loads a local session's full history into a headless copy without touching the original.
- `claude -p --teleport <session_id>` downloads a cloud session headlessly; run it in a throwaway clone of the session's repo, never a real checkout, because it checks out the branch.
- `claude --cloud "<title>"` refuses `--print`. Under `script -q /dev/null` it creates the session and prints `claude.ai/code/session_…`; `claude -p "<msg>" --cloud <id>` then sends to it headlessly.
- Sessions started from the CLI do not appear in Desktop's sidebar.
- Headless runs inside a cloned repo load that repo's `.claude/` settings, hooks and `.mcp.json` unless given `--setting-sources user --strict-mcp-config`.

## launchd

- A `StartCalendarInterval` job missed while the Mac sleeps runs on wake. A job that must only act at night checks the clock itself (`src/handoff.zig`, night window).
- launchd's `PATH` is minimal: the agent's plist sets it to include `claude`'s directory, Homebrew and system paths so `git` and its credential helper work.
