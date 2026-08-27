export const DEFAULT_PORT = 8787;

export function anthropicBaseUrl(port = DEFAULT_PORT) {
  return `http://127.0.0.1:${port}`;
}

function parseJson(text) {
  const raw = (text ?? "").trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function stringify(obj) {
  return `${JSON.stringify(obj, null, 2)}\n`;
}

export function isClaudeEnabled(settingsText, port = DEFAULT_PORT) {
  try {
    const obj = parseJson(settingsText);
    const url = obj?.env?.ANTHROPIC_BASE_URL;
    return typeof url === "string" && url.includes(`127.0.0.1:${port}`);
  } catch {
    return false;
  }
}

export function enableClaudeSettings(settingsText, port = DEFAULT_PORT) {
  let obj;
  try {
    obj = parseJson(settingsText);
  } catch {
    obj = {};
  }
  if (!obj.env || typeof obj.env !== "object") obj.env = {};
  const previous = obj.env.ANTHROPIC_BASE_URL ?? null;
  obj.env.ANTHROPIC_BASE_URL = anthropicBaseUrl(port);
  return { text: stringify(obj), previous };
}

export function disableClaudeSettings(settingsText, previous) {
  let obj;
  try {
    obj = parseJson(settingsText);
  } catch {
    obj = {};
  }
  if (!obj.env || typeof obj.env !== "object") obj.env = {};
  if (previous && !String(previous).includes("127.0.0.1:")) {
    obj.env.ANTHROPIC_BASE_URL = previous;
  } else {
    delete obj.env.ANTHROPIC_BASE_URL;
  }
  if (obj.env && Object.keys(obj.env).length === 0) delete obj.env;
  return stringify(obj);
}

export function enableClaudeDesktop(configText, command = "headroom") {
  let obj;
  try {
    obj = parseJson(configText);
  } catch {
    obj = {};
  }
  if (!obj.mcpServers || typeof obj.mcpServers !== "object") obj.mcpServers = {};
  obj.mcpServers.headroom = {
    command,
    args: ["mcp", "serve"],
  };
  return stringify(obj);
}

export function disableClaudeDesktop(configText) {
  let obj;
  try {
    obj = parseJson(configText);
  } catch {
    obj = {};
  }
  if (obj.mcpServers && typeof obj.mcpServers === "object") {
    delete obj.mcpServers.headroom;
    if (Object.keys(obj.mcpServers).length === 0) delete obj.mcpServers;
  }
  return stringify(obj);
}
