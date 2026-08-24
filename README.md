# Headroom Switch

One-click Headroom on/off for **ChatGPT Codex on Windows**.

This is not Headroom. It is a small WinForms switch that writes
`%USERPROFILE%\.codex\config.toml` the way [`headroom wrap codex`](https://github.com/headroomlabs-ai/headroom)
does, then starts `headroom proxy`.

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

Headroom compresses Codex context before it hits the model. The Codex GUI
(ChatGPT desktop) does not pick up `headroom wrap` the same way the CLI does.

Pointing only `model_provider` at localhost is not enough. ChatGPT desktop
keeps using the built-in OpenAI provider and WebSocket path, so the proxy
sees `GET /v1/models` and nothing else.

Headroom Switch writes the same keys `headroom wrap codex` injects, including
`openai_base_url`.

## How it works

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

Other Codex settings (`personality`, MCP servers, approval policy) are left
alone. Files are written as UTF-8 without BOM.

## Get started

1. Install [Headroom](https://github.com/headroomlabs-ai/headroom): `pip install "headroom-ai[all]"`
2. Clone this repo (or copy the files in the root)
3. Double-click `HeadroomSwitch.bat`  
   (`HeadroomSwitch.vbs` if you do not want a console flash)
4. Turn the switch on with **balanced**
5. Fully quit ChatGPT from the system tray, then open it again
6. Run a Codex task, then check `http://127.0.0.1:8787/stats`  
   You want `/v1/responses` or `codex_ws.units_total > 0`, not only `GET /v1/models`

Optional: double-click `Build-Exe.ps1` once to compile `HeadroomSwitch.exe`.

If the switch cannot find `headroom.exe` (common when launched from Explorer),
open **設定** and pick the path. Typical locations: Python `Scripts`, or uv tools.

## Profiles

| Profile | Proxy command | Meaning |
| --- | --- | --- |
| `speed` | `--mode cache` | Cache-first. Almost no compression. |
| `balanced` (default) | `--mode token` | Actual compression. Use this. |
| `maximum` | `--mode token --no-ccr` | Most savings. May drop detail. |

Changing profile restarts the proxy. You do not need to restart ChatGPT for that.

## Credits

Compression is done by [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom)
(Apache-2.0, Headroom Contributors). Install it separately. This repository only
toggles Codex config and starts/stops the local proxy.

See [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
