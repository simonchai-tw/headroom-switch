# Changelog

## 0.3.0 — 2026-09-01

The Windows PowerShell 5.1 readiness tick no longer collides with the read-only, case-insensitive `$PID` automatic variable. Pending starts freeze target, port, binary, process identity, enabled state, and ownership. Rollback reports its real outcome; foreign Headroom routing is never claimed or falsely reported as restored. Port changes abort unless Switch-owned routing is successfully restored first, preserving the old working state on failure.

All proxy/config callers share one pending snapshot. Settings port change, profile restart, and Switch bootstrap use the same 90s Timer. Failure rolls back only Switch-owned config. Pending blocks Settings. Logs report the frozen snapshot and actual rollback result.

## 0.3.0-rc6 — 2026-08-31

Root `model_provider` / `openai_base_url` edits only hit real root assignments (not text inside strings). Trailing comments and indentation are kept. Switch no longer folds blank lines in the whole file. Claude off uses the same snapshot rollback as on, and will not overwrite a user-owned `mcpServers.headroom`. Proxy start waits up to 90s on a timer (UI stays responsive) and says timed out / exited / port busy instead of one generic line.

## 0.3.0-rc5 — 2026-08-31

TOML table split/remove share one scanner. Multiline strings ending in extra quotes no longer swallow the next table. Nested arrays inside a table are removed with the table. Claude enable snapshots every target file and restores them if a later write fails.

## 0.3.0-rc4 — 2026-08-30

Lamp on starts the proxy first and writes config only after the owned listener is up. Failures leave config alone. Lamp off keeps `[model_providers.headroom]` without `base_url` (not localhost, not api.openai.com) so old Codex threads can resume. Nested TOML arrays and multiline strings are no longer treated as tables. Update check failure shows Retry.

## 0.3.0-rc3 — 2026-08-30

Update chip is vertically centered on the title. Build-Exe uses a numeric file version (ps2exe cannot take `-rc3`) and a `.bat` launcher. `pause` is gone — that cmdlet does not exist in PowerShell and was aborting the script.

## 0.3.0-rc2 — 2026-08-30

Lamp-off stops the process that owns the proxy port when its command line has `headroom.exe` and `proxy` (not a bare `headroom` token). Orphan `mcp serve` processes (parent gone) are stopped. The app's own `headroom.exe proxy` shim is stopped. Log "Proxy stopped." only after that.

## 0.3.0-rc1 — 2026-08-30

Release candidate. Intent: intercept model API traffic only; never rewrite config this app did not write; no upgrade dialogs.

## 0.3.0-beta — 2026-08-30

Follows 0.3.0-alpha. Next: rc.

CI now fails if proxy process matching is widened to PowerShell, or if the start-time gate goes back to DMTF conversion.

## 0.3.0-alpha — 2026-08-30

Preview. Not a daily-driver release. Next: rc.

### Upgrade from 0.2.x
Configs written by 0.2.x have no `[headroom_switch]` table. This version will not edit them on lamp-off.

- If `state.json` still has the previous provider, Switch adopts the file on launch and off can restore.
- Otherwise the status row says the config is not owned. Restore a `config.toml.*.bak`, or turn the lamp on once so this version writes the table.

### Added
- Update chip on the home screen: check on launch, upgrade through `uv` when available
- Process guard so Codex / Claude cannot be switched or toggled while the app is open
- Profile buttons use a light hatch when idle so they read apart from the app chips
- Ownership table `[headroom_switch]` in `config.toml`, so previous provider/URL survive without `state.json`

### Changed
- Close-lamp never rewrites Codex or Claude config that this app did not write
- Port changes rewrite the active app config so the lamp and the proxy stay on the same port
- CI fails the Windows job when any `verify-fix` check fails
- Proxy stop matches `headroom.exe` only; a PowerShell window that merely mentions this repo is left alone

### Fixed
- Backup collision, JSON refuse-to-write (including duplicate keys), and TOML table removal (indent, comments, array tables)
- `openai_base_url` under `[profiles.*]` is no longer rewritten on disable
- Official Headroom docs (`name = "OpenAI via Headroom proxy"`) are not treated as written by this app
- Proxy PID reuse check uses process start time as `DateTime`, not DMTF conversion
- Update check no longer reports current when the local version cannot be read
- Hidden `headroom` / `uv` upgrade no longer blocks on a `[Y/n]` prompt or a locked shim

MCP (`headroom_retrieve`) stays wired. The proxy compresses; retrieve is how the model fetches originals.
