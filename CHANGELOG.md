# Changelog

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
