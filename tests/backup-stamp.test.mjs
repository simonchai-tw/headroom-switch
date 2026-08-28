import assert from "node:assert/strict";
import test from "node:test";

function bakPath(dir, name, stamp, existing) {
  let bak = `${dir}/${name}.${stamp}.bak`;
  if (existing.has(bak)) {
    bak = `${dir}/${name}.${stamp}.abcdef.bak`;
  }
  existing.add(bak);
  return bak;
}

test("same-millisecond writes keep two distinct backup names", () => {
  const existing = new Set();
  const stamp = "20260829-004800123";
  const a = bakPath("/tmp", "collide.json", stamp, existing);
  const b = bakPath("/tmp", "collide.json", stamp, existing);
  assert.notEqual(a, b);
  assert.match(a, /collide\.json\.20260829-004800123\.bak$/);
  assert.match(b, /collide\.json\.20260829-004800123\.[0-9a-f]{6}\.bak$/);
});
