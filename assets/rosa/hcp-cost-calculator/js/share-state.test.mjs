import assert from "node:assert/strict";
import test from "node:test";

import {
  SHARE_FORMAT,
  buildShareUrl,
  decodeShareState,
  encodeShareState,
  extractShareCode,
  shareCodeFromLocation
} from "./share-state.mjs";

test("encodeShareState and decodeShareState round-trip scenario fields", () => {
  const scenario = {
    clusterCount: 2,
    ec2SavingsPlanDiscountPercent: 12.5,
    rhContractTier: "oneYear",
    summaryPriceUnit: "monthly",
    instances: [
      { instanceType: "m7i.xlarge", region: "us-east-1", count: 16 },
      { instanceType: "r7g.2xlarge", region: "us-west-2", count: 3 }
    ]
  };

  const code = encodeShareState(scenario);
  assert.equal(typeof code, "string");
  assert.ok(code.length > 20);

  const decoded = decodeShareState(code);
  assert.deepEqual(decoded, scenario);
});

test("extractShareCode accepts bare codes and URLs", () => {
  const code = encodeShareState({
    clusterCount: 1,
    ec2SavingsPlanDiscountPercent: 0,
    rhContractTier: "onDemand",
    summaryPriceUnit: "yearly",
    instances: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 3 }]
  });

  assert.equal(extractShareCode(code), code);
  assert.equal(extractShareCode(`https://example.com/experts/rosa/hcp-cost-calculator/#s=${code}`), code);
  assert.equal(extractShareCode(`https://example.com/path?s=${code}`), code);
  assert.equal(extractShareCode(`#s=${code}`), code);
});

test("shareCodeFromLocation and buildShareUrl use #s=", () => {
  const code = "abc123";
  assert.equal(
    shareCodeFromLocation({ hash: `#s=${code}`, search: "" }),
    code
  );
  assert.equal(
    buildShareUrl(code, { origin: "https://example.com", pathname: "/experts/rosa/hcp-cost-calculator/" }),
    `https://example.com/experts/rosa/hcp-cost-calculator/#s=${code}`
  );
});

test("decodeShareState rejects non-HCP payloads", () => {
  const foreign = btoa(JSON.stringify({ v: 1, c: { sa: 1 }, s: 1 }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  assert.throws(() => decodeShareState(foreign), /Unsupported or invalid/);
  assert.equal(SHARE_FORMAT, "hcp");
});
