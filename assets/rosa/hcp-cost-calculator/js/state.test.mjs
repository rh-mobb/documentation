import test from "node:test";
import assert from "node:assert/strict";
import {
  createDefaultSet,
  createInitialEstimate,
  duplicateSet
} from "./state.mjs";

test("createDefaultSet creates three AZ pools with 1/1 counts", () => {
  const result = createDefaultSet({
    name: "Default",
    instanceType: "m7i.xlarge",
    zones: ["us-east-1a", "us-east-1b", "us-east-1c"]
  });

  assert.equal(typeof result.id, "string");
  assert.equal(result.name, "Default");
  assert.equal(result.instanceType, "m7i.xlarge");
  assert.equal(result.poolBaseName, "workers");
  assert.equal(result.pools.length, 3);
  assert.deepEqual(
    result.pools.map((pool) => [pool.min, pool.max]),
    [
      [1, 1],
      [1, 1],
      [1, 1]
    ]
  );
  assert.deepEqual(
    result.pools.map((pool) => pool.az),
    ["us-east-1a", "us-east-1b", "us-east-1c"]
  );
});

test("createInitialEstimate includes a default set", () => {
  const result = createInitialEstimate({
    region: "us-east-1",
    zones: ["us-east-1a", "us-east-1b", "us-east-1c"]
  });

  assert.equal(result.region, "us-east-1");
  assert.equal(result.sets.length, 1);
  assert.equal(result.sets[0].poolBaseName, "workers");
  assert.equal(result.sets[0].pools.length, 3);
});

test("duplicateSet clones pools and assigns a new id", () => {
  const original = createDefaultSet({
    name: "Workload A",
    instanceType: "m7i.xlarge",
    zones: ["us-east-1a", "us-east-1b", "us-east-1c"]
  });
  const copy = duplicateSet(original);

  assert.notEqual(copy.id, original.id);
  assert.equal(copy.name, "Workload A Copy");
  assert.equal(copy.instanceType, original.instanceType);
  assert.equal(copy.poolBaseName, original.poolBaseName);
  assert.deepEqual(copy.pools, original.pools);
  assert.notEqual(copy.pools, original.pools);
});
