# Changelog

## 0.2.2 — 2026-08-29

### Fixed
- Refuse to write Claude JSON if it fails to parse (was silently wiping the file)
- Atomic config writes with timestamped `.bak`, keeping 5
- Backup stamps use milliseconds + guid suffix, so enable→disable can no longer
  clobber the clean copy
- Kill the stored proxy PID only if the process still looks like headroom
- Remove whole `[model_providers.headroom]` / `[mcp_servers.headroom]` tables
  (unknown keys are no longer orphaned)
- Port match is `8787`, not `87870`; invalid port in Settings is now rejected
- Settings port change restarts the proxy
- `Kill-Headroom.ps1` no longer kills unrelated python on 8787
- Cached `headroom.exe` lookup (was spawning 3 python processes every 4 seconds)

### Changed
- Window / tray / dialogs titled **Headroom Switch** (was bare "Headroom")
- State file moved to `%LOCALAPPDATA%\HeadroomSwitch\state.json`,
  with migration from the legacy `.codex\` location
- `state.json` is not backed up; config files still are
- Removed unused `$HadProviderLine`

### Added
- `$script:AppVersion = '0.2.2'` (tray tooltip)
- `verify-fix.ps1` + a `windows-latest` CI job that runs the shipped `.ps1`
  on Windows PowerShell 5.1

## 0.2.0 — 2026-08-27

- English-only UI
- Title is **Headroom**. Lamp is the on/off control (no track switch)
- Codex / Claude (exp.) sit in one frame, aligned with speed / balanced / maximum
- Lamp is unframed; its center lines up with **speed**
- **Dashboard** opens `http://127.0.0.1:8787/dashboard`
- X follows Settings. Default is **Quit** (stop proxy if running). Tray is opt-in
- Tray **Exit** always stops the proxy and quits
- No proxy console window
- Claude (experimental): writes `ANTHROPIC_BASE_URL` + Headroom MCP so Cowork can be tried

## 0.1.0 — 2026-08-24

First public release.

- WinForms toggle for ChatGPT Codex on Windows
- Writes wrap-equivalent keys: `openai_base_url`, `model_provider`, websocket flags, Headroom MCP
- Starts / stops `headroom proxy` with speed / balanced / maximum
- Restores the previous provider on off
- Companion for [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom); not a fork
