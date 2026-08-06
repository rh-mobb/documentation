import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("app contains required estimate-only and non-binding disclaimer text", () => {
  const html = fs.readFileSync("assets/rosa/hcp-cost-calculator/app.html", "utf8");

  assert.match(html, /planning estimates only/i);
  assert.match(html, /not a formal quote|not a quote/i);
  assert.match(html, /non-binding estimates|non-binding/i);
  assert.match(html, /contractual commitment/i);
});
