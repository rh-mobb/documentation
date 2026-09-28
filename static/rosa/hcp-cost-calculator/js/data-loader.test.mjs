import assert from "node:assert/strict";
import test from "node:test";

import { getRegionPricing, loadSnapshotData } from "./data-loader.mjs";

test("getRegionPricing returns matching region payload", () => {
  const pricingByRegion = {
    "us-east-1": {
      byInstanceType: {
        "m7i.xlarge": {
          onDemandMonthly: 100,
          oneYearMonthly: 80,
          threeYearMonthly: 60
        }
      }
    }
  };

  assert.deepEqual(getRegionPricing(pricingByRegion, "us-east-1"), pricingByRegion["us-east-1"]);
});

test("getRegionPricing throws useful error for missing region", () => {
  const pricingByRegion = {
    "us-east-1": { byInstanceType: {} }
  };

  assert.throws(() => getRegionPricing(pricingByRegion, "eu-west-1"), /Missing pricing for region eu-west-1/);
});

test("loadSnapshotData filters out regions with missing pricing files", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (url.endsWith("/hcp-regions-snapshot.json")) {
      return {
        ok: true,
        json: async () => ({
          regions: [{ code: "us-east-1", zones: ["us-east-1a"] }, { code: "eu-west-1", zones: ["eu-west-1a"] }]
        })
      };
    }
    if (url.endsWith("/hcp-instance-catalog.json")) {
      return { ok: true, json: async () => ({ instances: [{ type: "m7i.xlarge" }] }) };
    }
    if (url.endsWith("/snapshot-manifest.json")) {
      return {
        ok: true,
        json: async () => ({
          regions: ["us-east-1", "eu-west-1"],
          files: {
            regions: "hcp-regions-snapshot.json",
            instance_catalog: "hcp-instance-catalog.json"
          }
        })
      };
    }
    if (url.endsWith("/pricing/us-east-1.json")) {
      return { ok: true, json: async () => ({ region: "us-east-1", byInstanceType: { "m7i.xlarge": {} } }) };
    }
    if (url.endsWith("/pricing/eu-west-1.json")) {
      return { ok: false, status: 404, statusText: "Not Found" };
    }
    throw new Error(`Unexpected URL ${url}`);
  };

  try {
    const loaded = await loadSnapshotData("/experts/rosa/hcp-cost-calculator/data");
    assert.deepEqual(Object.keys(loaded.pricingByRegion), ["us-east-1"]);
    assert.deepEqual(
      loaded.regions.regions.map((region) => region.code),
      ["us-east-1"]
    );
    assert.deepEqual(loaded.manifest.regions, ["us-east-1"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("loadSnapshotData uses manifest regions_detail when regions file is blocked", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (url.endsWith("/hcp-regions-snapshot.json") || url.endsWith("/regions.json")) {
      return { ok: false, status: 403, statusText: "Forbidden" };
    }
    if (url.endsWith("/hcp-instance-catalog.json")) {
      return { ok: true, json: async () => ({ instances: [{ type: "m7i.xlarge" }] }) };
    }
    if (url.endsWith("/snapshot-manifest.json")) {
      return {
        ok: true,
        json: async () => ({
          regions: ["us-east-1"],
          regions_detail: [{ code: "us-east-1", zones: ["us-east-1a", "us-east-1b"] }],
          files: {
            regions: "hcp-regions-snapshot.json",
            instance_catalog: "hcp-instance-catalog.json"
          }
        })
      };
    }
    if (url.endsWith("/pricing/us-east-1.json")) {
      return { ok: true, json: async () => ({ region: "us-east-1", byInstanceType: { "m7i.xlarge": {} } }) };
    }
    throw new Error(`Unexpected URL ${url}`);
  };

  try {
    const loaded = await loadSnapshotData("/experts/rosa/hcp-cost-calculator/data");
    assert.deepEqual(loaded.regions.regions, [{ code: "us-east-1", zones: ["us-east-1a", "us-east-1b"] }]);
    assert.deepEqual(loaded.catalog.instances, [{ type: "m7i.xlarge" }]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("loadSnapshotData throws if no region pricing can be loaded", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (url.endsWith("/hcp-regions-snapshot.json")) {
      return { ok: true, json: async () => ({ regions: [{ code: "us-east-1", zones: ["us-east-1a"] }] }) };
    }
    if (url.endsWith("/hcp-instance-catalog.json")) {
      return { ok: true, json: async () => ({ instances: [{ type: "m7i.xlarge" }] }) };
    }
    if (url.endsWith("/snapshot-manifest.json")) {
      return {
        ok: true,
        json: async () => ({
          regions: ["us-east-1"],
          files: {
            regions: "hcp-regions-snapshot.json",
            instance_catalog: "hcp-instance-catalog.json"
          }
        })
      };
    }
    if (url.endsWith("/pricing/us-east-1.json")) {
      return { ok: false, status: 404, statusText: "Not Found" };
    }
    throw new Error(`Unexpected URL ${url}`);
  };

  try {
    await assert.rejects(
      () => loadSnapshotData("/experts/rosa/hcp-cost-calculator/data"),
      /No region pricing files could be loaded/
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});
