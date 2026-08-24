import assert from "node:assert/strict";
import test from "node:test";
import {
  disableHeadroom,
  enableHeadroom,
  isHeadroomEnabled,
} from "../lib/config-transform.mjs";

const SAMPLE = `model = "gpt-5.2"
model_provider = "openai"
personality = "pragmatic"
approval_policy = "on-request"
`;

test("enable writes wrap-equivalent Codex keys and keeps other settings", () => {
  const on = enableHeadroom(SAMPLE, 8787);
  assert.match(on, /openai_base_url = "http:\/\/127\.0\.0\.1:8787\/v1"/);
  assert.match(on, /model_provider = "headroom"/);
  assert.match(on, /supports_websockets = true/);
  assert.match(on, /requires_openai_auth = true/);
  assert.match(on, /\[mcp_servers\.headroom\]/);
  assert.match(on, /personality = "pragmatic"/);
  assert.match(on, /approval_policy = "on-request"/);
  assert.equal(isHeadroomEnabled(on, 8787), true);
});

test("disable restores the previous provider and leaves other settings", () => {
  const on = enableHeadroom(SAMPLE, 8787);
  const off = disableHeadroom(on, "openai");
  assert.doesNotMatch(off, /openai_base_url/);
  assert.doesNotMatch(off, /model_providers\.headroom/);
  assert.doesNotMatch(off, /mcp_servers\.headroom/);
  assert.match(off, /model_provider = "openai"/);
  assert.match(off, /personality = "pragmatic"/);
  assert.equal(isHeadroomEnabled(off, 8787), false);
});
