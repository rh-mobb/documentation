import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCostExplorerConfig,
  buildCostExplorerUrl,
  classifyFleetProfile,
  encodeCostExplorerShare,
  isGravitonInstance
} from "./cost-explorer-bridge.mjs";

test("classifyFleetProfile maps instance families", () => {
  assert.equal(classifyFleetProfile("m7i.xlarge"), "general");
  assert.equal(classifyFleetProfile("r7i.2xlarge"), "memory");
  assert.equal(classifyFleetProfile("c7i.large"), "compute");
});

test("isGravitonInstance detects arm families", () => {
  assert.equal(isGravitonInstance("m7g.xlarge"), true);
  assert.equal(isGravitonInstance("m7i.xlarge"), false);
  assert.equal(isGravitonInstance("m7i.xlarge", "arm64"), true);
});

test("buildCostExplorerConfig aggregates HCP pools into fleet fields", () => {
  const estimate = {
    region: "us-east-1",
    sets: [
      {
        instanceType: "m7i.xlarge",
        region: "us-east-1",
        pools: [{ min: 3, max: 3, az: "us-east-1a" }]
      },
      {
        instanceType: "r7g.2xlarge",
        region: "us-west-2",
        pools: [{ min: 2, max: 4, az: "us-west-2a" }]
      }
    ]
  };
  const catalogByType = new Map([
    ["m7i.xlarge", { type: "m7i.xlarge", vcpus: 4, architecture: "amd64" }],
    ["r7g.2xlarge", { type: "r7g.2xlarge", vcpus: 8, architecture: "arm64" }]
  ]);
  const pricingByRegion = {
    "us-east-1": {
      byInstanceType: {
        "m7i.xlarge": { onDemandMonthly: 146 }
      }
    },
    "us-west-2": {
      byInstanceType: {
        "r7g.2xlarge": { onDemandMonthly: 292 }
      }
    }
  };

  const cfg = buildCostExplorerConfig({
    estimate,
    clusterCount: 2,
    rhContractTier: "oneYear",
    ec2DiscountPercent: 15,
    catalogByType,
    pricingByRegion
  });

  assert.equal(cfg.singleAZClusters, 0);
  assert.equal(cfg.multiAZClusters, 0);
  assert.equal(cfg.hcpClusters, 2);
  assert.equal(cfg.generalVCPU, 12);
  assert.equal(cfg.memoryVCPU, 16);
  assert.equal(cfg.computeVCPU, 0);
  assert.equal(cfg.burstVCPU, 16);
  assert.equal(cfg.burstProfile, "memory");
  assert.equal(cfg.rosaContract, "1yr");
  assert.equal(cfg.awsDiscountPct, 15);
  assert.equal(cfg.avgVCPUPerNode, 6);
  assert.equal(cfg.armPct, 57);
  assert.ok(cfg.rateGeneral > 0);
  assert.ok(cfg.rateMemory > 0);
});

test("buildCostExplorerUrl encodes a loadable share hash", () => {
  const cfg = buildCostExplorerConfig({
    estimate: {
      region: "us-east-1",
      sets: [
        {
          instanceType: "m7i.xlarge",
          region: "us-east-1",
          pools: [{ min: 3, max: 3 }]
        }
      ]
    },
    clusterCount: 1,
    catalogByType: new Map([["m7i.xlarge", { vcpus: 4 }]]),
    pricingByRegion: {
      "us-east-1": { byInstanceType: { "m7i.xlarge": { onDemandMonthly: 146 } } }
    }
  });
  const url = buildCostExplorerUrl(cfg);
  assert.match(url, /^\/experts\/rosa\/cost-explorer\/#s=/);
  const code = url.split("#s=")[1];
  assert.equal(typeof encodeCostExplorerShare(cfg), "string");
  assert.ok(code.length > 20);
});
