# Changelog

## 0.2.0 — 2026-08-27

- English-only UI (no i18n)
- Lamp button instead of the oversized track switch
- App target: Codex (supported) / Claude EXP (writes settings + MCP so you can try Cowork)
- X hides to tray by default; Settings can make X quit and stop the proxy
- Tray Exit is a single action: stop saving mode and quit
- Savings opens `http://127.0.0.1:8787/dashboard`
- Removed the proxy console window option (always hidden)

## 0.1.0 — 2026-08-24

First public release.

- WinForms toggle for ChatGPT Codex on Windows
- Writes wrap-equivalent keys: `openai_base_url`, `model_provider`, websocket flags, Headroom MCP
- Starts / stops `headroom proxy` with speed / balanced / maximum
- Restores the previous provider on off
- Companion for [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom); not a fork
