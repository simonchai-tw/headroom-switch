export const DEFAULT_PORT = 8787;

const PROVIDER_RE = /^model_provider\s*=\s*"([^"]*)"\s*$/m;
const PROVIDER_LINE_RE = /^model_provider\s*=.*$/m;
const OPENAI_BASE_RE = /^openai_base_url\s*=\s*"([^"]*)"\s*$/m;
const OPENAI_BASE_LINE_RE = /^openai_base_url\s*=.*$/m;
const HEADROOM_BLOCK_RE =
  /^\[model_providers\.headroom\][ \t]*\r?\n(?:[ \t]*(?:name|base_url|wire_api|supports_websockets|requires_openai_auth)[ \t]*=.*\r?\n)*/m;
const MCP_BLOCK_RE =
  /^\[mcp_servers\.headroom\][ \t]*\r?\n(?:[ \t]*(?:command|args)[ \t]*=.*\r?\n)*/m;

function tomlString(value) {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export function proxyBaseUrl(port) {
  return `http://127.0.0.1:${port}/v1`;
}

export function headroomBlock(port) {
  return [
    "[model_providers.headroom]",
    'name = "OpenAI via Headroom proxy"',
    `base_url = "${proxyBaseUrl(port)}"`,
    'wire_api = "responses"',
    "supports_websockets = true",
    "requires_openai_auth = true",
  ].join("\n");
}

export function mcpBlock(command = "headroom") {
  return [
    "[mcp_servers.headroom]",
    `command = ${tomlString(command)}`,
    'args = ["mcp", "serve"]',
  ].join("\n");
}

export function readModelProvider(content) {
  const m = content.match(PROVIDER_RE);
  return m?.[1] ?? null;
}

export function readOpenaiBaseUrl(content) {
  const m = content.match(OPENAI_BASE_RE);
  return m?.[1] ?? null;
}

export function isHeadroomEnabled(content, port = DEFAULT_PORT) {
  const base = readOpenaiBaseUrl(content);
  if (base && base.includes(`127.0.0.1:${port}`)) return true;
  return readModelProvider(content) === "headroom";
}

function collapseBlank(s) {
  return s.replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "").replace(/\n*$/, "\n");
}

function setLine(content, lineRe, line) {
  if (lineRe.test(content)) return content.replace(lineRe, line);
  if (!content.trim()) return `${line}\n`;
  return `${line}\n\n${content}`;
}

export function enableHeadroom(content, port, mcpCommand = "headroom") {
  let next = content.replace(HEADROOM_BLOCK_RE, "").replace(MCP_BLOCK_RE, "");
  next = setLine(next, PROVIDER_LINE_RE, 'model_provider = "headroom"');
  next = setLine(next, OPENAI_BASE_LINE_RE, `openai_base_url = "${proxyBaseUrl(port)}"`);
  next = collapseBlank(next);
  const extras = `${headroomBlock(port)}\n\n${mcpBlock(mcpCommand)}\n`;
  next = `${next.replace(/\s*$/, "")}\n\n${extras}`;
  return collapseBlank(next);
}

export function disableHeadroom(content, previousProvider, previousOpenaiBaseUrl) {
  let next = content.replace(HEADROOM_BLOCK_RE, "").replace(MCP_BLOCK_RE, "");
  if (previousProvider && previousProvider !== "headroom") {
    next = setLine(next, PROVIDER_LINE_RE, `model_provider = "${previousProvider}"`);
  } else {
    next = next.replace(/^model_provider\s*=.*\r?\n?/m, "");
  }
  if (previousOpenaiBaseUrl && !previousOpenaiBaseUrl.includes("127.0.0.1:")) {
    next = setLine(
      next,
      OPENAI_BASE_LINE_RE,
      `openai_base_url = "${previousOpenaiBaseUrl}"`,
    );
  } else {
    next = next.replace(/^openai_base_url\s*=.*\r?\n?/m, "");
  }
  return collapseBlank(next);
}
