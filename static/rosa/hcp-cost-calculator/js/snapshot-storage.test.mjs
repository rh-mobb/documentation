import assert from "node:assert/strict";
import test from "node:test";

import {
  clearSnapshotStorage,
  readCachedRegionPricing,
  readCachedSnapshotCore,
  writeCachedRegionPricing,
  writeCachedSnapshotCore
} from "./snapshot-storage.mjs";

function withMockSessionStorage(run) {
  const store = new Map();
  const original = globalThis.sessionStorage;
  globalThis.sessionStorage = {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
    key: (index) => Array.from(store.keys())[index] ?? null,
    get length() {
      return store.size;
    },
    clear: () => store.clear()
  };
  try {
    return run(store);
  } finally {
    globalThis.sessionStorage = original;
  }
}

test("writeCachedSnapshotCore round-trips by generated_at version", () => {
  withMockSessionStorage(() => {
    const snapshot = {
      regions: { regions: [{ code: "us-east-1", zones: ["us-east-1a"] }] },
      catalog: { instances: [{ type: "m7i.xlarge" }] },
      manifest: { generated_at: "2026-07-27T00:00:00.000Z" }
    };
    writeCachedSnapshotCore(snapshot);
    assert.equal(readCachedSnapshotCore("2026-07-27T00:00:00.000Z")?.catalog.instances.length, 1);
    assert.equal(readCachedSnapshotCore("2026-07-28T00:00:00.000Z"), null);
  });
});

test("writeCachedRegionPricing round-trips by generated_at version", () => {
  withMockSessionStorage(() => {
    const payload = { region: "us-east-1", byInstanceType: {} };
    writeCachedRegionPricing("us-east-1", "2026-07-27T00:00:00.000Z", payload);
    assert.deepEqual(readCachedRegionPricing("us-east-1", "2026-07-27T00:00:00.000Z"), payload);
    assert.equal(readCachedRegionPricing("us-east-1", "2026-07-28T00:00:00.000Z"), null);
  });
});

test("clearSnapshotStorage removes calculator cache keys", () => {
  withMockSessionStorage((store) => {
    writeCachedSnapshotCore({
      regions: { regions: [] },
      catalog: { instances: [{ type: "m7i.xlarge" }] },
      manifest: { generated_at: "2026-07-27T00:00:00.000Z" }
    });
    writeCachedRegionPricing("us-east-1", "2026-07-27T00:00:00.000Z", { region: "us-east-1" });
    clearSnapshotStorage();
    assert.equal(store.size, 0);
  });
});
