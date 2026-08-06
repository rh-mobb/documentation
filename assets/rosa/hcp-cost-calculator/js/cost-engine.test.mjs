import assert from "node:assert/strict";
import test from "node:test";

import { calculateScenarioTotals } from "./cost-engine.mjs";

test("calculateScenarioTotals computes min and max per tier", () => {
  const estimate = {
    sets: [
      {
        instanceType: "m7i.xlarge",
        pools: [
          { min: 1, max: 3 },
          { min: 1, max: 3 },
          { min: 1, max: 3 }
        ]
      }
    ]
  };
  const regionPricing = {
    byInstanceType: {
      "m7i.xlarge": {
        onDemandMonthly: 100,
        oneYearMonthly: 80,
        threeYearMonthly: 60
      }
    }
  };

  const result = calculateScenarioTotals(estimate, regionPricing);

  assert.equal(result.onDemand.min, 300);
  assert.equal(result.onDemand.max, 900);
  assert.equal(result.oneYear.min, 240);
  assert.equal(result.oneYear.max, 720);
  assert.equal(result.threeYear.min, 180);
  assert.equal(result.threeYear.max, 540);
});

test("calculateScenarioTotals sums across multiple sets", () => {
  const estimate = {
    sets: [
      {
        instanceType: "m7i.xlarge",
        pools: [
          { min: 1, max: 2 },
          { min: 1, max: 2 },
          { min: 1, max: 2 }
        ]
      },
      {
        instanceType: "m7g.xlarge",
        pools: [
          { min: 0, max: 1 },
          { min: 0, max: 1 },
          { min: 0, max: 1 }
        ]
      }
    ]
  };
  const regionPricing = {
    byInstanceType: {
      "m7i.xlarge": {
        onDemandMonthly: 100,
        oneYearMonthly: 80,
        threeYearMonthly: 60
      },
      "m7g.xlarge": {
        onDemandMonthly: 70,
        oneYearMonthly: 55,
        threeYearMonthly: 40
      }
    }
  };

  const result = calculateScenarioTotals(estimate, regionPricing);

  assert.deepEqual(result.onDemand, { min: 300, max: 810 });
  assert.deepEqual(result.oneYear, { min: 240, max: 645 });
  assert.deepEqual(result.threeYear, { min: 180, max: 480 });
  assert.deepEqual(result.byScenario.min, { onDemand: 300, oneYear: 240, threeYear: 180 });
  assert.deepEqual(result.byScenario.max, { onDemand: 810, oneYear: 645, threeYear: 480 });
});

test("calculateScenarioTotals throws on missing instance pricing", () => {
  const estimate = {
    sets: [
      {
        instanceType: "m7i.xlarge",
        pools: [{ min: 1, max: 1 }]
      }
    ]
  };
  const regionPricing = {
    byInstanceType: {}
  };

  assert.throws(
    () => calculateScenarioTotals(estimate, regionPricing),
    /Missing pricing for instance type m7i\.xlarge/
  );
});
