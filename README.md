# Headroom Switch

One-click Headroom on/off for ChatGPT Codex on Windows, with Claude support experimental.

Headroom Switch is a small WinForms companion for Headroom. It starts and stops the local Headroom proxy and updates only the configuration it owns, so you can switch between direct routing and local context compression without hand-editing config files.

<p>
  <a href="https://github.com/simonchai-tw/headroom-switch/actions/workflows/ci.yml"><img src="https://github.com/simonchai-tw/headroom-switch/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/windows-PowerShell%205.1-0078D4?style=flat-square" alt="Windows PowerShell 5.1">
  <img src="https://img.shields.io/badge/companion-headroomlabs--ai%2Fheadroom-7f9a86?style=flat-square" alt="Headroom companion">
</p>

[Download](#get-started) ·
[Get started](#get-started) ·
[Why](#why-this-exists) ·
[How it works](#how-it-works) ·
[Profiles](#profiles) ·
[Claude](#claude-experimental) ·
[Credits](#credits)

---

## Get started

### Recommended: use the EXE

1. Install Headroom:
   `pip install "headroom-ai[all]"`
2. Download and open `HeadroomSwitch.exe`.
3. Pick Codex (or Claude, experimental).
4. Fully quit ChatGPT or Claude from the system tray.
5. Leave the profile on **balanced** and click the lamp to turn Headroom on.
6. Wait for the proxy/config status to become ready, then reopen the target app.
7. Open **Dashboard** to confirm traffic is reaching Headroom.

For Codex, look for `/v1/responses` traffic or `codex_ws.units_total > 0`, not only `GET /v1/models`.

For Claude, look for Anthropic `/v1/messages` traffic. Zero requests means the GUI did not route through the proxy.

If the switch cannot find `headroom.exe` (common when launched from Explorer), open **Settings** and choose it manually. Typical locations include Python `Scripts` and uv tools.

### Run or build from source

Clone this repository or use GitHub’s Source code download from a Release.

- Double-click `HeadroomSwitch.bat` to run from source.
- Use `HeadroomSwitch.vbs` instead if you do not want a console flash.
- Double-click `Build-Exe.bat` to compile `HeadroomSwitch.exe`.

Do not run `Build-Exe.ps1` by itself; the Windows FileVersion is generated as a numeric version such as `0.3.0.0` by the build wrapper.

## Why this exists

Headroom compresses agent context before it reaches the model. The Codex CLI can be wrapped directly, but ChatGPT desktop does not pick up `headroom wrap` in the same way.

Pointing only `model_provider` at localhost is not enough for ChatGPT desktop: it can continue using the built-in OpenAI provider and WebSocket path, leaving the proxy with only `GET /v1/models` traffic.

Headroom Switch handles the desktop-specific configuration and proxy lifecycle for you.

## How it works

The lamp is the on/off control.

When you turn it on, Headroom Switch starts `headroom proxy`, verifies that the expected local listener is ready, and only then writes the routing configuration. When you turn it off, it restores the previous routing, removes the entries it owns, and stops the proxy.

Configuration changes are ownership-scoped. Unrelated settings are left alone, existing values are preserved for restoration, and config files are backed up before normal writes. If safe restoration cannot be confirmed, the switch keeps the proxy running rather than leaving an app pointed at a dead localhost endpoint.

### Codex (supported)

When on, the switch configures:

- `openai_base_url = "http://127.0.0.1:8787/v1"`
- `model_provider = "headroom"`
- a Headroom model-provider entry with Responses/WebSocket support
- `[mcp_servers.headroom]` → `headroom mcp serve`
- the local Headroom proxy on the selected profile

When off, the previous `model_provider` and `openai_base_url` are restored (or removed if none existed), Switch-owned MCP/state entries are removed, and the proxy is stopped. A compatibility Headroom provider entry is kept without a localhost `base_url` so older Codex threads can still resume.

### App switching and exit behavior

If the target app is running, the lamp will not turn on or off; fully quit the app from its tray first. Switching Codex ↔ Claude is also blocked while the lamp is on or either app is running.

By default, closing the window quits Headroom Switch and stops the proxy. You can change X to **Minimize to tray** in Settings. If the target app is still actively using Headroom, exit is blocked rather than killing the proxy underneath it.

The **Updated** chip checks the installed Headroom version against PyPI at launch. **Updated** means current, **Update** means a newer Headroom build is available, and **Retry** means the check failed. ChatGPT, Claude, or a live proxy blocks an upgrade.

## Profiles

| Profile | Proxy command | Meaning |
| --- | --- | --- |
| `speed` | `--mode cache` | Cache-first; almost no compression. |
| `balanced` (default) | `--mode token` | Normal token compression. Recommended. |
| `maximum` | `--mode token --no-ccr` | More aggressive token mode; may drop detail. |

Changing profile restarts the proxy. The target app itself does not need to be restarted just for a profile change.

## Claude (experimental)

Claude Desktop / Cowork support is experimental.

When enabled, the switch writes `ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"` in `~/.claude/settings.json` and adds a Headroom MCP server to `claude_desktop_config.json` (including the MSIX copy when present). On disable, the previous base URL is restored and the Switch-owned MCP entry is removed.

Cowork may still ignore the environment setting and connect directly to `api.anthropic.com`. Use Dashboard after a turn to verify that requests actually reached Headroom.

Tools that rewrite Claude proxy or configuration settings can overwrite `~/.claude/settings.json` or remove `ANTHROPIC_BASE_URL`. Configuration switchers such as [cc-switch](https://github.com/farion1231/cc-switch) are one example. Upstream Headroom can reconcile this kind of overwrite at runtime with `HEADROOM_CC_SWITCH_RECONCILE=1` (off by default).

## Local proxy

The proxy listens on `127.0.0.1` and Headroom Switch does not add caller authentication. Other processes on the same Windows machine can therefore talk to the local proxy. Do not expose the proxy port beyond localhost, and use it only on a machine you trust.

## Credits

Compression is provided by [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom) (Apache-2.0, Headroom Contributors) and is installed separately. Headroom Switch only manages the desktop configuration and local proxy lifecycle.

Headroom™ is referenced only to identify the upstream project. Headroom Switch is not affiliated with, endorsed by, or sponsored by Headroom Labs.

See [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
