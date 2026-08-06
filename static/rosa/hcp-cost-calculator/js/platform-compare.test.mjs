import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT,
  EKS_AUTO_MODE_FEE_FRACTION,
  EKS_CLUSTER_FEE_HOURLY,
  EKS_EXTENDED_CLUSTER_FEE_HOURLY,
  HCP_CLUSTER_FEE_HOURLY,
  HOURS_PER_MONTH,
  MONTHS_PER_YEAR,
  PLATFORM_CAPABILITY_ROWS,
  PLATFORM_LIFECYCLE_ROWS,
  PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_BASE,
  PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_CAP,
  PLATFORM_OPS_USD_PER_FTE_YEAR,
  ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT,
  ROSA_PAYGO_USD_PER_CORE_PAIR_YEAR,
  ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT,
  awsBusinessSupportMonthly,
  buildPlatformCompare,
  capabilityStatusMeta,
  corePairsFromVcpu,
  deltaVsRosa,
  getEksClusterFeeHourly,
  platformComponentsYearly,
  platformOpsFteForClusters,
  rosaWorkerNodeFeeMonthly
} from "./platform-compare.mjs";

const pricingByRegion = {
  "us-east-1": {
    byInstanceType: {
      "m7i.xlarge": { onDemandMonthly: 100 },
      "m7i.2xlarge": { onDemandMonthly: 200 }
    }
  },
  "eu-west-1": {
    byInstanceType: {
      "m7i.xlarge": { onDemandMonthly: 110 }
    }
  }
};

const catalogByType = {
  "m7i.xlarge": { vcpus: 4 },
  "m7i.2xlarge": { vcpus: 8 }
};

test("corePairsFromVcpu rounds up to 4-vCPU blocks", () => {
  assert.equal(corePairsFromVcpu(0), 0);
  assert.equal(corePairsFromVcpu(4), 1);
  assert.equal(corePairsFromVcpu(5), 2);
  assert.equal(corePairsFromVcpu(12), 3);
});

test("buildPlatformCompare computes list-to-list ROSA and EKS totals", () => {
  const compare = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 3 }],
    clusterCount: 1,
    pricingByRegion,
    catalogByType
  });

  assert.equal(compare.totalWorkerVcpu, 12);
  assert.equal(compare.corePairs, 3);
  assert.equal(compare.selfManaged, undefined);
  assert.equal(compare.rosa.workerEc2Monthly, 300);
  assert.equal(compare.rosa.platformFeeMonthly, HCP_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH);
  assert.equal(compare.rosa.softwarePrivateOfferDiscount, ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT);
  assert.equal(
    compare.rosa.softwareMonthly,
    rosaWorkerNodeFeeMonthly(3, ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT)
  );
  assert.equal(
    compare.rosa.softwareMonthly,
    ((3 * ROSA_PAYGO_USD_PER_CORE_PAIR_YEAR) / MONTHS_PER_YEAR) * (1 - 0.33)
  );
  assert.equal(compare.rosa.platformOpsMonthly, undefined);
  assert.equal(
    compare.rosa.totalMonthly,
    compare.rosa.workerEc2Monthly +
      compare.rosa.platformFeeMonthly +
      compare.rosa.softwareMonthly
  );

  assert.equal(compare.eks.platformFeeMonthly, EKS_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH);
  assert.equal(compare.eks.autoModeFeeMonthly, 300 * EKS_AUTO_MODE_FEE_FRACTION);
  const eksAwsSpend =
    300 + compare.eks.platformFeeMonthly + compare.eks.autoModeFeeMonthly;
  assert.equal(
    compare.eks.awsSupportMonthly,
    awsBusinessSupportMonthly(eksAwsSpend, DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT)
  );
  assert.equal(compare.rosa.awsSupportMonthly, null);
  assert.equal(
    compare.eks.totalMonthly,
    eksAwsSpend + compare.eks.awsSupportMonthly
  );

  const delta = deltaVsRosa(compare.eks.totalMonthly, compare.rosa.totalMonthly);
  assert.ok(Number.isFinite(delta.absoluteMonthly));
  assert.ok(Number.isFinite(delta.percent));
});

test("buildPlatformCompare scales platform fees with cluster count", () => {
  const compare = buildPlatformCompare({
    workers: [
      { instanceType: "m7i.xlarge", region: "us-east-1", count: 1 },
      { instanceType: "m7i.xlarge", region: "eu-west-1", count: 1 }
    ],
    clusterCount: 2,
    pricingByRegion,
    catalogByType
  });

  assert.equal(compare.rosa.platformFeeMonthly, HCP_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH * 2);
  assert.equal(compare.eks.platformFeeMonthly, EKS_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH * 2);
});

test("buildPlatformCompare marks unavailable when pricing missing", () => {
  const compare = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "ap-south-1", count: 1 }],
    clusterCount: 1,
    pricingByRegion,
    catalogByType
  });
  assert.equal(compare.rosa.available, false);
  assert.equal(compare.rosa.totalMonthly, null);
  assert.equal(compare.eks.available, false);
});

test("base compare always uses EKS standard $0.10/hr (extended is not toggled)", () => {
  assert.equal(getEksClusterFeeHourly(false), EKS_CLUSTER_FEE_HOURLY);
  assert.equal(getEksClusterFeeHourly(true), EKS_EXTENDED_CLUSTER_FEE_HOURLY);

  const compare = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 1 }],
    clusterCount: 1,
    pricingByRegion,
    catalogByType
  });

  assert.equal(compare.eks.platformFeeMonthly, EKS_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH);
  assert.equal(compare.eksClusterFeeHourly, EKS_CLUSTER_FEE_HOURLY);
  assert.equal(compare.eksExtendedSupport, undefined);
  assert.ok(PLATFORM_LIFECYCLE_ROWS.length >= 2);
  assert.match(PLATFORM_LIFECYCLE_ROWS[0].rosa, /EUS Term 1/);
  assert.match(PLATFORM_LIFECYCLE_ROWS[1].eks, /Potential additional cost/);
  assert.equal("selfManaged" in PLATFORM_LIFECYCLE_ROWS[0], false);
});

test("capability rows use status marks and a short note", () => {
  assert.deepEqual(
    PLATFORM_CAPABILITY_ROWS.map((row) => row.id),
    [
      "gitops",
      "observability",
      "service-mesh",
      "dev-spaces",
      "image-builds",
      "production-support",
      "hardened-images",
      "developer-console",
      "cluster-idp",
      "stateful-batch"
    ]
  );
  for (const row of PLATFORM_CAPABILITY_ROWS) {
    assert.ok(["yes", "no", "partial"].includes(row.rosaStatus));
    assert.ok(["yes", "no", "partial"].includes(row.eksStatus));
    assert.ok(row.note);
    assert.ok(row.note.length < 120);
    assert.ok(capabilityStatusMeta(row.rosaStatus).symbol);
    assert.ok(capabilityStatusMeta(row.eksStatus).symbol);
  }
  const support = PLATFORM_CAPABILITY_ROWS.find((row) => row.id === "production-support");
  assert.equal(support.rosaStatus, "yes");
  assert.equal(support.eksStatus, "partial");
});

test("AWS Business Support is always 10% of EKS AWS spend", () => {
  const compare = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 1 }],
    clusterCount: 1,
    pricingByRegion,
    catalogByType
  });
  const eksAwsSpend =
    compare.eks.workerEc2Monthly +
    compare.eks.platformFeeMonthly +
    compare.eks.autoModeFeeMonthly;

  assert.equal(compare.awsBusinessSupportPercent, 10);
  assert.equal(compare.eks.awsSupportMonthly, eksAwsSpend * 0.1);
  assert.equal(compare.rosa.awsSupportMonthly, null);
  assert.equal(awsBusinessSupportMonthly(1000, 10), 100);
});

test("3-year TCO blends EKS standard + extended control-plane fees", () => {
  const compare = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 1 }],
    clusterCount: 2,
    pricingByRegion,
    catalogByType
  });

  const hours = HOURS_PER_MONTH;
  const expectedCp =
    2 *
    hours *
    (14 * EKS_CLUSTER_FEE_HOURLY + 12 * EKS_EXTENDED_CLUSTER_FEE_HOURLY + 10 * EKS_CLUSTER_FEE_HOURLY);
  assert.equal(compare.threeYear.eks.platformFeeThreeYear, expectedCp);
  assert.equal(
    compare.threeYear.rosa.softwarePrivateOfferDiscount,
    ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT
  );
  assert.equal(
    compare.threeYear.rosa.softwareThreeYear,
    rosaWorkerNodeFeeMonthly(1, ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT) * 36
  );
  assert.equal(compare.threeYear.rosa.platformComponentsThreeYear, 0);
  assert.equal(
    compare.threeYear.eks.platformComponentsThreeYear,
    platformComponentsYearly(2).eksYearly * 3
  );
  assert.equal(
    compare.threeYear.rosa.totalThreeYear,
    compare.threeYear.rosa.workerEc2ThreeYear +
      compare.threeYear.rosa.platformFeeThreeYear +
      compare.threeYear.rosa.softwareThreeYear +
      compare.threeYear.rosa.platformComponentsThreeYear +
      compare.threeYear.rosa.platformOpsThreeYear
  );
  assert.equal(compare.threeYear.platformOps.clusterCount, 2);
  assert.equal(compare.threeYear.platformOps.rosaFte, 1.5);
  assert.equal(compare.threeYear.platformOps.eksFte, 3);
  assert.equal(
    compare.threeYear.rosa.platformOpsThreeYear,
    1.5 * PLATFORM_OPS_USD_PER_FTE_YEAR * 3
  );
  assert.equal(
    compare.threeYear.eks.platformOpsThreeYear,
    3 * PLATFORM_OPS_USD_PER_FTE_YEAR * 3
  );
  assert.equal(
    compare.threeYear.eks.totalThreeYear,
    compare.threeYear.eks.workerEc2ThreeYear +
      compare.threeYear.eks.autoModeFeeThreeYear +
      compare.threeYear.eks.platformFeeThreeYear +
      compare.threeYear.eks.awsSupportThreeYear +
      compare.threeYear.eks.platformComponentsThreeYear +
      compare.threeYear.eks.platformOpsThreeYear
  );
  assert.ok(Number.isFinite(compare.threeYear.delta.absoluteThreeYear));
  assert.ok(Number.isFinite(compare.threeYear.delta.percent));
});

test("platform ops FTE steps by cluster count", () => {
  assert.deepEqual(platformOpsFteForClusters(1), {
    clusterCount: 1,
    rosaFte: 1,
    eksFte: 2,
    usdPerFteYear: PLATFORM_OPS_USD_PER_FTE_YEAR
  });
  assert.equal(platformOpsFteForClusters(5).rosaFte, 1.5);
  assert.equal(platformOpsFteForClusters(6).rosaFte, 2.5);
  assert.equal(platformOpsFteForClusters(30).rosaFte, 4);
  assert.equal(platformOpsFteForClusters(30).eksFte, 8);
  assert.equal(platformOpsFteForClusters(41).rosaFte, 5);
  assert.equal(platformOpsFteForClusters(41).eksFte, 10);

  const fleet = buildPlatformCompare({
    workers: [{ instanceType: "m7i.xlarge", region: "us-east-1", count: 1 }],
    clusterCount: 30,
    pricingByRegion,
    catalogByType
  });
  assert.equal(fleet.threeYear.platformOps.rosaFte, 4);
  assert.equal(fleet.threeYear.platformOps.eksFte, 8);
  assert.equal(
    fleet.threeYear.rosa.platformOpsThreeYear,
    4 * PLATFORM_OPS_USD_PER_FTE_YEAR * 3
  );
});

test("platform components yearly is conservative and capped", () => {
  assert.equal(platformComponentsYearly(1).eksYearly, PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_BASE);
  assert.equal(platformComponentsYearly(1).rosaYearly, 0);
  assert.equal(platformComponentsYearly(2).eksYearly, 4_200);
  assert.equal(platformComponentsYearly(30).eksYearly, PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_CAP);
});
