import test from "node:test";
import assert from "node:assert/strict";
import {
  createDefaultSet,
  createInitialEstimate,
  createInitialExpertState,
  createInitialBasicState,
  createExpertCluster,
  duplicateSet,
  projectExpertStateToEstimate,
  projectBasicSelectionsToEstimate
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

test("createInitialExpertState defaults to one multi-AZ cluster with 3 nodes per AZ", () => {
  const state = createInitialExpertState({
    region: "us-east-1",
    zones: ["us-east-1a", "us-east-1b", "us-east-1c"]
  });
  assert.equal(state.clusters.length, 1);
  assert.equal(state.clusters[0].name, "Cluster 1");
  assert.equal(state.clusters[0].region, "us-east-1");
  assert.equal(state.clusters[0].pools.length, 3);
  assert.deepEqual(
    state.clusters[0].pools.map((pool) => [pool.az, pool.count, pool.instanceType]),
    [
      ["us-east-1a", 3, "m7i.xlarge"],
      ["us-east-1b", 3, "m7i.xlarge"],
      ["us-east-1c", 3, "m7i.xlarge"]
    ]
  );
});

test("createExpertCluster can seed multiple pools or start empty", () => {
  const cluster = createExpertCluster({
    name: "Prod",
    region: "eu-west-1",
    pools: [
      { name: "workers-a", instanceType: "m7i.xlarge", az: "eu-west-1a", count: 2 },
      { name: "workers-b", instanceType: "m7i.xlarge", az: "eu-west-1b", count: 2 }
    ]
  });
  assert.equal(cluster.pools.length, 2);
  assert.equal(cluster.pools[1].az, "eu-west-1b");
  assert.equal(cluster.filters.architecture, "x86-intel");
  assert.equal(cluster.filters.instanceType, "m7i.xlarge");
  assert.equal(cluster.filters.threeAz, false);

  const empty = createExpertCluster({ name: "Cluster 2", region: "us-east-1", pools: [] });
  assert.equal(empty.pools.length, 0);
});

test("projectExpertStateToEstimate flattens pools for pricing", () => {
  const expert = createInitialExpertState({ region: "us-west-2", zones: ["us-west-2a"] });
  assert.equal(expert.clusters[0].pools.length, 3);
  expert.clusters[0].pools[0].count = 4;
  const estimate = projectExpertStateToEstimate(expert);
  assert.equal(estimate.sets.length, 3);
  assert.equal(estimate.sets[0].region, "us-west-2");
  assert.equal(estimate.sets[0].clusterName, "Cluster 1");
  assert.equal(estimate.sets[0].pools[0].min, 4);
  assert.equal(estimate.sets[0].pools[0].max, 4);
});

test("projectBasicSelectionsToEstimate maps rows to single-AZ sets", () => {
  const estimate = projectBasicSelectionsToEstimate(
    [
      { instanceType: "m7i.xlarge", region: "us-east-1", count: 3 },
      { instanceType: "r7g.xlarge", region: "us-west-2", count: 2 }
    ],
    "us-east-1"
  );
  assert.equal(estimate.sets.length, 2);
  assert.equal(estimate.sets[1].instanceType, "r7g.xlarge");
  assert.equal(estimate.sets[1].pools[0].min, 2);
});

test("createInitialBasicState seeds default selection", () => {
  const basic = createInitialBasicState();
  assert.equal(basic.clusterCount, 1);
  assert.equal(basic.selections.length, 1);
  assert.equal(basic.selections[0].count, 3);
});
