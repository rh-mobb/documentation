const SCENARIOS = ["min", "max"];

const TIER_CONFIG = [
  { key: "onDemand", field: "onDemandMonthly" },
  { key: "oneYear", field: "oneYearMonthly" },
  { key: "threeYear", field: "threeYearMonthly" }
];

function createScenarioTotals() {
  return { min: 0, max: 0 };
}

export function calculateScenarioTotals(estimate, regionPricing) {
  const byTier = {
    onDemand: createScenarioTotals(),
    oneYear: createScenarioTotals(),
    threeYear: createScenarioTotals()
  };

  for (const set of estimate.sets ?? []) {
    const price = regionPricing?.byInstanceType?.[set.instanceType];
    if (!price) {
      throw new Error(`Missing pricing for instance type ${set.instanceType}`);
    }

    const nodesByScenario = {
      min: 0,
      max: 0
    };

    for (const pool of set.pools ?? []) {
      nodesByScenario.min += Number(pool.min) || 0;
      nodesByScenario.max += Number(pool.max) || 0;
    }

    for (const { key, field } of TIER_CONFIG) {
      for (const scenario of SCENARIOS) {
        byTier[key][scenario] += nodesByScenario[scenario] * (Number(price[field]) || 0);
      }
    }
  }

  return {
    ...byTier,
    byScenario: {
      min: {
        onDemand: byTier.onDemand.min,
        oneYear: byTier.oneYear.min,
        threeYear: byTier.threeYear.min
      },
      max: {
        onDemand: byTier.onDemand.max,
        oneYear: byTier.oneYear.max,
        threeYear: byTier.threeYear.max
      }
    }
  };
}
