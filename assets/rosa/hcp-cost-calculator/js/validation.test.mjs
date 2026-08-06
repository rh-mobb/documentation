import assert from "node:assert/strict";
import test from "node:test";

import { validateEstimate } from "./validation.mjs";

function baseEstimate() {
  return {
    sets: [
      {
        id: "set-1",
        name: "Default Set",
        instanceType: "m7i.xlarge",
        pools: [
          { az: "us-east-1a", min: 1, max: 1 },
          { az: "us-east-1b", min: 1, max: 1 },
          { az: "us-east-1c", min: 1, max: 1 }
        ]
      }
    ]
  };
}

function baseInput() {
  return {
    estimate: baseEstimate(),
    allowedAzs: ["us-east-1a", "us-east-1b", "us-east-1c"],
    supportedTypes: ["m7i.xlarge"]
  };
}

test("validateEstimate reports unsupported instance types", () => {
  const input = baseInput();
  input.estimate.sets[0].instanceType = "m7g.xlarge";

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].code, "UNSUPPORTED_INSTANCE_TYPE");
});

test("validateEstimate reports invalid AZ for region", () => {
  const input = baseInput();
  input.estimate.sets[0].pools[1].az = "us-west-2a";

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].code, "INVALID_AZ_FOR_REGION");
});

test("validateEstimate reports invalid node ordering", () => {
  const input = baseInput();
  input.estimate.sets[0].pools[0] = { az: "us-east-1a", min: 5, max: 4 };

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].code, "INVALID_NODE_ORDER");
});

test("validateEstimate reports invalid numeric values", () => {
  const input = baseInput();
  input.estimate.sets[0].pools[0].max = 1.5;
  input.estimate.sets[0].pools[1].min = -1;

  const result = validateEstimate(input);
  const codes = result.errors.map((issue) => issue.code);

  assert.equal(codes.filter((code) => code === "INVALID_NODE_VALUE").length, 2);
});

test("validateEstimate warns on stale snapshots", () => {
  const input = baseInput();
  input.snapshotAgeDays = 45;
  input.staleSnapshotDaysThreshold = 30;

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 0);
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].code, "STALE_SNAPSHOT");
});

test("validateEstimate warns on large burst spread", () => {
  const input = baseInput();
  input.burstSpreadThreshold = 4;
  input.estimate.sets[0].pools[0].max = 7;

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 0);
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].code, "LARGE_BURST_SPREAD");
});

test("validateEstimate supports optional AZ imbalance warning", () => {
  const input = baseInput();
  input.enableAzImbalanceWarning = true;
  input.azImbalanceThreshold = 2;
  input.estimate.sets[0].pools[0] = { az: "us-east-1a", min: 1, max: 8 };
  input.estimate.sets[0].pools[1] = { az: "us-east-1b", min: 6, max: 8 };
  input.estimate.sets[0].pools[2] = { az: "us-east-1c", min: 1, max: 8 };

  const result = validateEstimate(input);

  assert.equal(result.errors.length, 0);
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].code, "AZ_IMBALANCE");
});
