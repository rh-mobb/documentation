export const HOURS_PER_MONTH = 730;
export const MONTHS_PER_YEAR = 12;
export const HOURS_PER_YEAR = HOURS_PER_MONTH * MONTHS_PER_YEAR;
export const ROSA_VCPU_BLOCK_SIZE = 4;
export const ROSA_PAYGO_USD_PER_CORE_PAIR_YEAR = 1500;
/** Standard RH Private Offer % off Worker Node Fee PAYGO (not HCP cluster fee, not EC2). */
export const ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT = 0.33;
export const ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT = 0.55;
export const HCP_CLUSTER_FEE_HOURLY = 0.25;
export const EKS_CLUSTER_FEE_HOURLY = 0.1;
export const EKS_EXTENDED_CLUSTER_FEE_HOURLY = 0.6;
export const EKS_AUTO_MODE_FEE_FRACTION = 0.12;
/** Planning approx for AWS Business / Business+ first-tier rate on monthly AWS charges. */
export const DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT = 10;
/** 3-year TCO horizon and EKS version-support months used to match longer ROSA stay. */
export const THREE_YEAR_MONTHS = 36;
export const EKS_STANDARD_SUPPORT_MONTHS = 14;
export const EKS_EXTENDED_SUPPORT_MONTHS = 12;
export const EKS_POST_UPGRADE_STANDARD_MONTHS =
  THREE_YEAR_MONTHS - EKS_STANDARD_SUPPORT_MONTHS - EKS_EXTENDED_SUPPORT_MONTHS;
/**
 * Platform-ops labor planning for 3-year TCO (not user-editable).
 * Steps by cluster count (not node count). ROSA side anchored to field examples
 * (e.g. ~4 FTEs for 30+ HCP clusters); EKS kept at roughly 2x for self-managed platform stack.
 */
export const PLATFORM_OPS_USD_PER_FTE_YEAR = 225_000;
/** Inclusive maxClusters per tier; last tier has maxClusters: Infinity. */
export const PLATFORM_OPS_FTE_TIERS = [
  { maxClusters: 1, rosaFte: 1, eksFte: 2 },
  { maxClusters: 5, rosaFte: 1.5, eksFte: 3 },
  { maxClusters: 15, rosaFte: 2.5, eksFte: 5 },
  { maxClusters: 40, rosaFte: 4, eksFte: 8 },
  { maxClusters: Infinity, rosaFte: 5, eksFte: 10 }
];

export function platformOpsFteForClusters(clusterCount = 1) {
  const clusters = asPositiveInt(clusterCount, 1);
  const tier =
    PLATFORM_OPS_FTE_TIERS.find((entry) => clusters <= entry.maxClusters) ??
    PLATFORM_OPS_FTE_TIERS[PLATFORM_OPS_FTE_TIERS.length - 1];
  return {
    clusterCount: clusters,
    rosaFte: tier.rosaFte,
    eksFte: tier.eksFte,
    usdPerFteYear: PLATFORM_OPS_USD_PER_FTE_YEAR
  };
}

/**
 * Conservative EKS common platform-components planning proxy (TCO-only).
 * Intended to cover typical monitoring + logging + GitOps/CI class costs only.
 * Deliberately excludes service mesh, hardened images, runtime support, registry
 * (rough wash with S3-backed OpenShift registry), and DIY developer portal.
 * Light scale with cluster count, capped so the line stays modest.
 */
export const PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_BASE = 3_600;
export const PLATFORM_COMPONENTS_EKS_USD_PER_EXTRA_CLUSTER_YEAR = 600;
export const PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_CAP = 10_800;

export function platformComponentsYearly(clusterCount = 1) {
  const clusters = asPositiveInt(clusterCount, 1);
  const uncapped =
    PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_BASE +
    Math.max(0, clusters - 1) * PLATFORM_COMPONENTS_EKS_USD_PER_EXTRA_CLUSTER_YEAR;
  const eksYearly = Math.min(PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_CAP, uncapped);
  return {
    clusterCount: clusters,
    rosaYearly: 0,
    eksYearly,
    eksYearlyBase: PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_BASE,
    eksYearlyExtraPerCluster: PLATFORM_COMPONENTS_EKS_USD_PER_EXTRA_CLUSTER_YEAR,
    eksYearlyCap: PLATFORM_COMPONENTS_EKS_USD_PER_YEAR_CAP
  };
}

/** Non-monetary lifecycle copy for Step 4 support comparison. */
export const PLATFORM_LIFECYCLE_ROWS = [
  {
    id: "included-window",
    label: "Included version support window",
    rosa:
      "~24 months on even OpenShift minors (Full + Maintenance + EUS Term 1 / Long-Life Additional Term 1, included with Premium-class ROSA)",
    eks: "14 months standard Kubernetes version support at $0.10/hr per cluster"
  },
  {
    id: "stay-longer",
    label: "Stay on the same minor longer",
    rosa: "Optional EUS Term 2 / Term 3 add-ons (toward ~36 / ~48 months)",
    eks: "Potential additional cost: +12 months EKS extended support at $0.60/hr per cluster (6x standard), or upgrade sooner"
  }
];

/** Capability status: yes = ✓, no = ✗, partial = ? */
export const CAPABILITY_STATUS = {
  yes: { symbol: "✓", label: "Included or supported on platform" },
  no: { symbol: "✗", label: "Not included" },
  partial: { symbol: "?", label: "Partial, add-on, or bring-your-own" }
};

/**
 * Compact capability matrix: status marks + short difference note.
 * Status values: "yes" | "no" | "partial"
 */
export const PLATFORM_CAPABILITY_ROWS = [
  {
    id: "gitops",
    label: "GitOps",
    rosaStatus: "yes",
    eksStatus: "partial",
    note: "OpenShift GitOps vs EKS Argo CD Capability or self-managed Argo/Flux."
  },
  {
    id: "observability",
    label: "Observability",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "ROSA includes Prometheus + Observe; EKS uses CloudWatch/AMP/AMG or BYO."
  },
  {
    id: "service-mesh",
    label: "Service Mesh",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "OpenShift Service Mesh vs no managed Istio twin on EKS (BYO/other)."
  },
  {
    id: "dev-spaces",
    label: "Dev Spaces",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "OpenShift Dev Spaces cloud workspaces vs no EKS twin (Codespaces/CodeCatalyst/BYO)."
  },
  {
    id: "image-builds",
    label: "Image builds",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "OpenShift Builds/Pipelines + ImageStreams vs external CI to ECR or BYO Tekton."
  },
  {
    id: "production-support",
    label: "Production support",
    rosaStatus: "yes",
    eksStatus: "partial",
    note: "ROSA includes Red Hat Premium; EKS needs AWS Business Support (~10% of AWS spend) for platform help."
  },
  {
    id: "hardened-images",
    label: "Hardened base images",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "Red Hat UBI / Hardened Images supported with OpenShift vs Chainguard or DIY on EKS."
  },
  {
    id: "developer-console",
    label: "Developer console",
    rosaStatus: "yes",
    eksStatus: "no",
    note: "OpenShift web console vs kubectl/AWS console or DIY developer portal on EKS."
  },
  {
    id: "cluster-idp",
    label: "Cluster IdP / SSO",
    rosaStatus: "yes",
    eksStatus: "partial",
    note: "ROSA in-product OAuth/OIDC/LDAP IdPs; EKS IAM Access Entries plus Cognito/Identity Center/Dex/Okta."
  },
  {
    id: "stateful-batch",
    label: "Stateful apps / long batch",
    rosaStatus: "yes",
    eksStatus: "partial",
    note: "EKS Auto Mode max node life is 21 days; sticky local state and long batch jobs need churn-tolerant design."
  }
];

export function capabilityStatusMeta(status) {
  return CAPABILITY_STATUS[status] ?? CAPABILITY_STATUS.partial;
}

export function getEksClusterFeeHourly(extendedSupport = false) {
  return extendedSupport ? EKS_EXTENDED_CLUSTER_FEE_HOURLY : EKS_CLUSTER_FEE_HOURLY;
}

function asPositiveInt(value, fallback = 1) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.max(1, parsed) : fallback;
}

function asNonNegativeNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(0, parsed) : fallback;
}

/**
 * Approximate AWS Business Support monthly fee as a flat % of modeled AWS spend.
 * Real Business / Business+ pricing is tiered; 10% is a common planning first-tier proxy.
 */
export function awsBusinessSupportMonthly(awsSpendMonthly, percent = DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT) {
  const spend = asNonNegativeNumber(awsSpendMonthly, 0);
  const rate = asNonNegativeNumber(percent, DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT) / 100;
  return spend * rate;
}

function getCatalogEntry(catalogByType, instanceType) {
  if (!catalogByType) {
    return null;
  }
  if (typeof catalogByType.get === "function") {
    return catalogByType.get(instanceType) ?? null;
  }
  return catalogByType[instanceType] ?? null;
}

function getOnDemandMonthly(pricingByRegion, region, instanceType) {
  const monthly = pricingByRegion?.[region]?.byInstanceType?.[instanceType]?.onDemandMonthly;
  const parsed = Number(monthly);
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * Sum On-Demand EC2 monthly cost and worker vCPU for worker rows.
 * @param {Array<{instanceType:string, region:string, count:number}>} workers
 * @param {object} pricingByRegion
 * @param {Map|object} catalogByType
 */
export function sumWorkerEc2Monthly(workers, pricingByRegion, catalogByType) {
  let ec2Monthly = 0;
  let totalVcpu = 0;
  let available = true;

  for (const worker of workers ?? []) {
    const count = Math.max(0, Number.parseInt(worker.count, 10) || 0);
    const region = String(worker.region ?? "").trim();
    const instanceType = String(worker.instanceType ?? "").trim();
    if (!count || !region || !instanceType) {
      continue;
    }
    const monthly = getOnDemandMonthly(pricingByRegion, region, instanceType);
    const catalog = getCatalogEntry(catalogByType, instanceType);
    const vcpus = Number(catalog?.vcpus ?? 0);
    if (monthly == null || !(vcpus > 0)) {
      available = false;
      continue;
    }
    ec2Monthly += count * monthly;
    totalVcpu += count * vcpus;
  }

  return { ec2Monthly, totalVcpu, available };
}

export function corePairsFromVcpu(totalVcpu) {
  const vcpu = Math.max(0, Number(totalVcpu) || 0);
  return Math.ceil(vcpu / ROSA_VCPU_BLOCK_SIZE);
}

/** Worker Node Fee monthly USD after a Private Offer discount (cluster fee / EC2 unaffected). */
export function rosaWorkerNodeFeeMonthly(corePairs, privateOfferDiscount = 0) {
  const pairs = Math.max(0, Number(corePairs) || 0);
  const discount = Math.min(1, Math.max(0, Number(privateOfferDiscount) || 0));
  return (pairs * ROSA_PAYGO_USD_PER_CORE_PAIR_YEAR * (1 - discount)) / MONTHS_PER_YEAR;
}

/**
 * Build platform compare model (all values monthly USD).
 * 1-year base: Worker Node Fee at standard 1-year Private Offer (33% off PAYGO).
 * EC2 and HCP cluster fee stay list. EKS uses standard $0.10/hr CP (extended is not toggled).
 */
export function buildPlatformCompare({
  workers = [],
  clusterCount = 1,
  pricingByRegion = {},
  catalogByType = {}
} = {}) {
  const clusters = asPositiveInt(clusterCount, 1);
  const workersSummary = sumWorkerEc2Monthly(workers, pricingByRegion, catalogByType);
  const corePairs = corePairsFromVcpu(workersSummary.totalVcpu);
  const eksClusterFeeHourly = EKS_CLUSTER_FEE_HOURLY;

  const rosaWorkerFeeMonthly = rosaWorkerNodeFeeMonthly(
    corePairs,
    ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT
  );
  const hcpFeeMonthly = HCP_CLUSTER_FEE_HOURLY * HOURS_PER_MONTH * clusters;
  const eksFeeMonthly = eksClusterFeeHourly * HOURS_PER_MONTH * clusters;
  const autoModeMonthly = workersSummary.ec2Monthly * EKS_AUTO_MODE_FEE_FRACTION;

  const eksAwsSpendMonthly =
    workersSummary.ec2Monthly + eksFeeMonthly + autoModeMonthly;
  const eksAwsSupportMonthly = awsBusinessSupportMonthly(
    eksAwsSpendMonthly,
    DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT
  );

  const rosa = {
    workerEc2Monthly: workersSummary.ec2Monthly,
    platformFeeMonthly: hcpFeeMonthly,
    softwareMonthly: rosaWorkerFeeMonthly,
    softwarePrivateOfferDiscount: ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT,
    autoModeFeeMonthly: null,
    awsSupportMonthly: null,
    available: workersSummary.available
  };
  rosa.totalMonthly = rosa.available
    ? rosa.workerEc2Monthly + rosa.platformFeeMonthly + rosa.softwareMonthly
    : null;

  const eks = {
    workerEc2Monthly: workersSummary.ec2Monthly,
    platformFeeMonthly: eksFeeMonthly,
    softwareMonthly: null,
    autoModeFeeMonthly: autoModeMonthly,
    awsSupportMonthly: eksAwsSupportMonthly,
    available: workersSummary.available
  };
  eks.totalMonthly = eks.available
    ? eks.workerEc2Monthly +
      eks.platformFeeMonthly +
      eks.autoModeFeeMonthly +
      eks.awsSupportMonthly
    : null;

  const threeYear = buildThreeYearTco({
    available: workersSummary.available,
    clusterCount: clusters,
    corePairs,
    rosaPlatformFeeMonthly: rosa.platformFeeMonthly,
    eksWorkerEc2Monthly: eks.workerEc2Monthly,
    eksAutoModeFeeMonthly: eks.autoModeFeeMonthly
  });

  return {
    clusterCount: clusters,
    totalWorkerVcpu: workersSummary.totalVcpu,
    corePairs,
    eksClusterFeeHourly,
    awsBusinessSupportPercent: DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT,
    rosaSoftwarePrivateOfferDiscount: ROSA_ONE_YEAR_PRIVATE_OFFER_DISCOUNT,
    platformOps: threeYear.platformOps,
    lifecycleRows: PLATFORM_LIFECYCLE_ROWS,
    capabilityRows: PLATFORM_CAPABILITY_ROWS,
    threeYear,
    rosa,
    eks
  };
}

/**
 * 3-year TCO. ROSA Worker Node Fee uses standard 3-year Private Offer (55% off PAYGO).
 * EC2 and HCP cluster fee stay list. EKS CP blends std + extended + post-upgrade std.
 */
export function buildThreeYearTco({
  available = true,
  clusterCount = 1,
  corePairs = 0,
  rosaPlatformFeeMonthly = 0,
  rosaSoftwareMonthly = null,
  eksWorkerEc2Monthly = 0,
  eksAutoModeFeeMonthly = 0
} = {}) {
  const clusters = asPositiveInt(clusterCount, 1);
  const workerEc2ThreeYear = asNonNegativeNumber(eksWorkerEc2Monthly, 0) * THREE_YEAR_MONTHS;
  const rosaPlatformFeeThreeYear =
    asNonNegativeNumber(rosaPlatformFeeMonthly, 0) * THREE_YEAR_MONTHS;
  const rosaSoftwareMonthlyResolved =
    rosaSoftwareMonthly == null
      ? rosaWorkerNodeFeeMonthly(corePairs, ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT)
      : asNonNegativeNumber(rosaSoftwareMonthly, 0);
  const rosaSoftwareThreeYear = rosaSoftwareMonthlyResolved * THREE_YEAR_MONTHS;
  const platformOps = platformOpsFteForClusters(clusters);
  const platformComponents = platformComponentsYearly(clusters);
  const rosaPlatformOpsThreeYear =
    platformOps.rosaFte *
    PLATFORM_OPS_USD_PER_FTE_YEAR *
    (THREE_YEAR_MONTHS / MONTHS_PER_YEAR);
  const rosaPlatformComponentsThreeYear =
    platformComponents.rosaYearly * (THREE_YEAR_MONTHS / MONTHS_PER_YEAR);
  const rosaTotalThreeYear = available
    ? workerEc2ThreeYear +
      rosaPlatformFeeThreeYear +
      rosaSoftwareThreeYear +
      rosaPlatformComponentsThreeYear +
      rosaPlatformOpsThreeYear
    : null;

  const eksCpThreeYear =
    clusters *
    HOURS_PER_MONTH *
    (EKS_STANDARD_SUPPORT_MONTHS * EKS_CLUSTER_FEE_HOURLY +
      EKS_EXTENDED_SUPPORT_MONTHS * EKS_EXTENDED_CLUSTER_FEE_HOURLY +
      EKS_POST_UPGRADE_STANDARD_MONTHS * EKS_CLUSTER_FEE_HOURLY);
  const eksAutoModeThreeYear =
    asNonNegativeNumber(eksAutoModeFeeMonthly, 0) * THREE_YEAR_MONTHS;
  const eksAwsSpendThreeYear = workerEc2ThreeYear + eksCpThreeYear + eksAutoModeThreeYear;
  const eksAwsSupportThreeYear = awsBusinessSupportMonthly(
    eksAwsSpendThreeYear,
    DEFAULT_AWS_BUSINESS_SUPPORT_PERCENT
  );
  const eksPlatformComponentsThreeYear =
    platformComponents.eksYearly * (THREE_YEAR_MONTHS / MONTHS_PER_YEAR);
  const eksPlatformOpsThreeYear =
    platformOps.eksFte *
    PLATFORM_OPS_USD_PER_FTE_YEAR *
    (THREE_YEAR_MONTHS / MONTHS_PER_YEAR);
  const eksTotalThreeYear = available
    ? eksAwsSpendThreeYear +
      eksAwsSupportThreeYear +
      eksPlatformComponentsThreeYear +
      eksPlatformOpsThreeYear
    : null;

  const rawDelta = deltaVsRosa(eksTotalThreeYear, rosaTotalThreeYear);

  return {
    months: THREE_YEAR_MONTHS,
    eksStandardMonths: EKS_STANDARD_SUPPORT_MONTHS,
    eksExtendedMonths: EKS_EXTENDED_SUPPORT_MONTHS,
    eksPostUpgradeStandardMonths: EKS_POST_UPGRADE_STANDARD_MONTHS,
    platformOps,
    platformComponents,
    rosaSoftwarePrivateOfferDiscount: ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT,
    rosa: {
      workerEc2ThreeYear,
      platformFeeThreeYear: rosaPlatformFeeThreeYear,
      softwareThreeYear: rosaSoftwareThreeYear,
      softwarePrivateOfferDiscount: ROSA_THREE_YEAR_PRIVATE_OFFER_DISCOUNT,
      platformComponentsThreeYear: rosaPlatformComponentsThreeYear,
      platformOpsThreeYear: rosaPlatformOpsThreeYear,
      totalThreeYear: rosaTotalThreeYear
    },
    eks: {
      workerEc2ThreeYear,
      autoModeFeeThreeYear: eksAutoModeThreeYear,
      platformFeeThreeYear: eksCpThreeYear,
      awsSupportThreeYear: eksAwsSupportThreeYear,
      platformComponentsThreeYear: eksPlatformComponentsThreeYear,
      platformOpsThreeYear: eksPlatformOpsThreeYear,
      totalThreeYear: eksTotalThreeYear
    },
    delta: {
      absoluteThreeYear: rawDelta.absoluteMonthly,
      percent: rawDelta.percent
    }
  };
}

export function deltaVsRosa(platformTotalMonthly, rosaTotalMonthly) {
  if (platformTotalMonthly == null || rosaTotalMonthly == null) {
    return { absoluteMonthly: null, percent: null };
  }
  const absoluteMonthly = platformTotalMonthly - rosaTotalMonthly;
  const percent = rosaTotalMonthly === 0 ? null : (absoluteMonthly / rosaTotalMonthly) * 100;
  return { absoluteMonthly, percent };
}
