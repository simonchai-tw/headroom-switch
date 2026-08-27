import assert from "node:assert/strict";
import test from "node:test";
import {
  anthropicBaseUrl,
  disableClaudeDesktop,
  disableClaudeSettings,
  enableClaudeDesktop,
  enableClaudeSettings,
  isClaudeEnabled,
} from "../lib/claude-settings.mjs";

const SAMPLE = `{
  "permissions": { "allow": ["Bash"] },
  "env": { "ANTHROPIC_BASE_URL": "https://api.anthropic.com" }
}
`;

test("enable writes ANTHROPIC_BASE_URL and keeps other keys", () => {
  const { text, previous } = enableClaudeSettings(SAMPLE, 8787);
  assert.equal(previous, "https://api.anthropic.com");
  assert.match(text, /"ANTHROPIC_BASE_URL": "http:\/\/127\.0\.0\.1:8787"/);
  assert.match(text, /"allow": \[\s*"Bash"\s*\]/s);
  assert.equal(isClaudeEnabled(text, 8787), true);
});

test("disable restores previous Anthropic URL", () => {
  const { text, previous } = enableClaudeSettings(SAMPLE, 8787);
  const off = disableClaudeSettings(text, previous);
  assert.match(off, /"ANTHROPIC_BASE_URL": "https:\/\/api.anthropic.com"/);
  assert.equal(isClaudeEnabled(off, 8787), false);
});

test("desktop config gets headroom MCP and can be removed", () => {
  const on = enableClaudeDesktop("{}", "C:\\\\Tools\\\\headroom.exe");
  assert.match(on, /"mcpServers"/);
  assert.match(on, /"headroom"/);
  assert.match(on, /"mcp",\s*"serve"/s);
  const off = disableClaudeDesktop(on);
  assert.doesNotMatch(off, /headroom/);
});

test("empty settings still enable", () => {
  const { text } = enableClaudeSettings("", 9000);
  assert.equal(anthropicBaseUrl(9000), "http://127.0.0.1:9000");
  assert.equal(isClaudeEnabled(text, 9000), true);
});
