# Headroom Switch

One-click Headroom on/off for **ChatGPT Codex** and **Claude (experimental)** on Windows.

This is not Headroom. It is a small WinForms lamp that writes the config your
app actually reads, then starts `headroom proxy`.

<p>
  <a href="https://github.com/simonchai-tw/headroom-switch/actions/workflows/ci.yml"><img src="https://github.com/simonchai-tw/headroom-switch/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/windows-PowerShell%205.1-0078D4?style=flat-square" alt="Windows PowerShell 5.1">
  <img src="https://img.shields.io/badge/companion-headroomlabs--ai%2Fheadroom-7f9a86?style=flat-square" alt="Headroom companion">
</p>

[Why](#why-this-exists) ·
[How it works](#how-it-works) ·
[Get started](#get-started) ·
[Profiles](#profiles) ·
[Credits](#credits)

---

## Why this exists

Headroom compresses agent context before it hits the model. Codex GUI (ChatGPT
desktop) does not pick up `headroom wrap` the same way the CLI does.

Pointing only `model_provider` at localhost is not enough. ChatGPT desktop
keeps using the built-in OpenAI provider and WebSocket path, so the proxy
sees `GET /v1/models` and nothing else.

Headroom Switch writes the same keys `headroom wrap codex` injects, including
`openai_base_url`.

Claude Desktop / Cowork is **experimental**. The lamp writes
`ANTHROPIC_BASE_URL` in `%USERPROFILE%\.claude\settings.json` and adds a
Headroom MCP server to `claude_desktop_config.json`. Cowork may still ignore
env and talk to `api.anthropic.com` — use **Dashboard** after a turn to see if
any requests arrived.

## How it works

### Codex (supported)

On:

- `openai_base_url = "http://127.0.0.1:8787/v1"`
- `model_provider = "headroom"`
- `[model_providers.headroom]` with `supports_websockets = true` and `requires_openai_auth = true`
- `[mcp_servers.headroom]` → `headroom mcp serve`
- start `headroom proxy --port 8787 --mode token` (balanced)

Off:

- restore the previous `model_provider` / `openai_base_url`
- remove the Headroom blocks
- stop the proxy

### Claude (experimental)

On:

- `env.ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"` in `~\.claude\settings.json`
- `mcpServers.headroom` in `%APPDATA%\Claude\claude_desktop_config.json` (and the MSIX copy if present)
- same local proxy

Off:

- restore the previous `ANTHROPIC_BASE_URL` (or drop the key)
- remove the Headroom MCP entry
- stop the proxy

Other settings are left alone. Files are written as UTF-8 without BOM.

The lamp is the on/off control. X follows Settings (default: quit and stop the
proxy). Tray **Exit** always stops the proxy and quits. There is no “quit GUI,
leave proxy running” path.

## Get started

1. Install [Headroom](https://github.com/headroomlabs-ai/headroom): `pip install "headroom-ai[all]"`
2. Clone this repo (or copy the files in the root)
3. Double-click `HeadroomSwitch.bat`  
   (`HeadroomSwitch.vbs` if you do not want a console flash)
4. Pick **Codex** or **Claude**, turn the lamp on with **balanced**
5. Fully quit the target app from the system tray, then open it again
6. Click **Dashboard** (`http://127.0.0.1:8787/dashboard`)  
   For Codex you want `/v1/responses` or `codex_ws.units_total > 0`, not only `GET /v1/models`  
   For Claude you want Anthropic `/v1/messages` traffic. Zero requests means the GUI ignored env.

Optional: double-click `Build-Exe.ps1` once to compile `HeadroomSwitch.exe`.

If the switch cannot find `headroom.exe` (common when launched from Explorer),
open **Settings** and pick the path. Typical locations: Python `Scripts`, or uv tools.

## Profiles

| Profile | Proxy command | Meaning |
| --- | --- | --- |
| `speed` | `--mode cache` | Cache-first. Almost no compression. |
| `balanced` (default) | `--mode token` | Actual compression. Use this. |
| `maximum` | `--mode token --no-ccr` | Most savings. May drop detail. |

Changing profile restarts the proxy. You do not need to restart the app for that.

## Credits

Compression is done by [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom)
(Apache-2.0, Headroom Contributors). Install it separately. This repository only
toggles app config and starts/stops the local proxy.

See [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
