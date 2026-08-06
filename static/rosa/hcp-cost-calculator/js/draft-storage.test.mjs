import test from "node:test";
import assert from "node:assert/strict";
import {
  DRAFT_STORAGE_KEY,
  DEFAULT_STEP_OPEN,
  buildDraftPayload,
  parseDraftPayload,
  loadDraft,
  saveDraft,
  clearDraft
} from "./draft-storage.mjs";

function memoryStorage(seed = {}) {
  const map = new Map(Object.entries(seed));
  return {
    getItem(key) {
      return map.has(key) ? map.get(key) : null;
    },
    setItem(key, value) {
      map.set(key, String(value));
    },
    removeItem(key) {
      map.delete(key);
    }
  };
}

test("buildDraftPayload and parseDraftPayload round-trip mode and clusters", () => {
  const payload = buildDraftPayload({
    mode: "expert",
    basicState: {
      clusterCount: 2,
      region: "us-east-1",
      selections: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 3 }]
    },
    expertState: {
      clusters: [
        {
          id: "c1",
          name: "Prod",
          region: "eu-west-1",
          filters: {
            architecture: "graviton",
            category: "general-purpose",
            family: "m7g",
            instanceType: "m7g.xlarge",
            threeAz: true
          },
          pools: [
            { id: "p1", name: "workers", instanceType: "m7g.xlarge", az: "eu-west-1a", count: 2 }
          ]
        }
      ]
    },
    discounting: {
      ec2SavingsPlanDiscountPercent: 15,
      rhContractTier: "oneYear",
      summaryPriceUnit: "monthly"
    },
    instanceFilters: {
      architecture: "x86-intel",
      category: "general-purpose",
      family: "m7i"
    },
    stepOpen: {
      "step-1-cluster-sizing": false,
      "step-2-discounting": true,
      "step-3-results": true,
      "step-4-compare": true
    }
  });

  const parsed = parseDraftPayload(JSON.stringify(payload));
  assert.equal(parsed.mode, "expert");
  assert.equal(parsed.basic.clusterCount, 2);
  assert.equal(parsed.expert.clusters[0].name, "Prod");
  assert.equal(parsed.expert.clusters[0].filters.threeAz, true);
  assert.equal(parsed.discounting.rhContractTier, "oneYear");
  assert.equal(parsed.instanceFilters.family, "m7i");
  assert.equal(parsed.eksExtendedSupport, undefined);
  assert.deepEqual(parsed.stepOpen, {
    "step-1-cluster-sizing": false,
    "step-2-discounting": true,
    "step-3-results": true,
    "step-4-compare": true
  });
});

test("stepOpen defaults when missing from draft", () => {
  const payload = buildDraftPayload({
    mode: "basic",
    basicState: {
      clusterCount: 1,
      region: "us-east-1",
      selections: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 1 }]
    },
    expertState: { clusters: [] }
  });
  assert.deepEqual(payload.stepOpen, DEFAULT_STEP_OPEN);
  const parsed = parseDraftPayload(JSON.stringify({ ...payload, stepOpen: undefined }));
  assert.deepEqual(parsed.stepOpen, DEFAULT_STEP_OPEN);
});

test("parseDraftPayload rejects invalid or empty drafts", () => {
  assert.equal(parseDraftPayload(null), null);
  assert.equal(parseDraftPayload("{}"), null);
  assert.equal(parseDraftPayload({ v: 1, mode: "basic", basic: {}, expert: {} }), null);
});

test("saveDraft, loadDraft, and clearDraft use storage key", () => {
  const storage = memoryStorage();
  const payload = buildDraftPayload({
    mode: "basic",
    basicState: {
      clusterCount: 1,
      region: "us-west-2",
      selections: [{ instanceType: "m7i.large", region: "us-west-2", count: 1 }]
    },
    expertState: {
      clusters: [
        {
          name: "Cluster 1",
          region: "us-west-2",
          pools: [{ name: "workers", instanceType: "m7i.large", az: "us-west-2a", count: 1 }]
        }
      ]
    }
  });

  assert.equal(saveDraft(payload, storage), true);
  assert.ok(storage.getItem(DRAFT_STORAGE_KEY));
  const loaded = loadDraft(storage);
  assert.equal(loaded.mode, "basic");
  assert.equal(loaded.basic.region, "us-west-2");
  clearDraft(storage);
  assert.equal(loadDraft(storage), null);
});
