import assert from "node:assert/strict";
import test from "node:test";

import { getRegionPricing } from "./data-loader.mjs";

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
