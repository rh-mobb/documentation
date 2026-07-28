const HOURS_PER_MONTH = 730;

const DEFAULT_RATES = {
  general: 0.048,
  memory: 0.063,
  compute: 0.043
};

const SHARE_PACK = {
  singleAZClusters: "sa",
  multiAZClusters: "ma",
  hcpClusters: "hc",
  generalVCPU: "gv",
  memoryVCPU: "mv",
  computeVCPU: "cv",
  burstVCPU: "bv",
  burstProfile: "bp",
  burstAwsDiscount: "bd",
  burstUsagePct: "bu",
  avgVCPUPerNode: "vn",
  rateGeneral: "rg",
  rateMemory: "rm",
  rateCompute: "rc",
  rosaContract: "rcn",
  awsDiscountPct: "ad",
  hcpMigrated: "hm",
  karpenter: "kp",
  burstSpot: "bs",
  armPct: "ap"
};

const SHARE_BOOL = new Set(["burstAwsDiscount", "hcpMigrated", "karpenter", "burstSpot"]);

const CONTRACT_MAP = {
  onDemand: "paygo",
  oneYear: "1yr",
  threeYear: "3yr"
};

export function classifyFleetProfile(instanceType = "") {
  const prefix = instanceType.split(".")[0].toLowerCase();
  if (/^(c|hpc)/.test(prefix)) {
    return "compute";
  }
  if (/^(r|x|u|z)/.test(prefix)) {
    return "memory";
  }
  return "general";
}

export function isGravitonInstance(instanceType = "", architecture = null) {
  if (architecture === "arm64") {
    return true;
  }
  const family = instanceType.split(".")[0].toLowerCase();
  return /g$/.test(family) || /g\d/.test(family);
}

function packCfg(cfg) {
  const out = {};
  for (const [key, short] of Object.entries(SHARE_PACK)) {
    const val = cfg[key];
    out[short] = SHARE_BOOL.has(key) ? (val ? 1 : 0) : val;
  }
  return out;
}

export function toBase64Url(obj) {
  const json = JSON.stringify(obj);
  const bytes = new TextEncoder().encode(json);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function encodeCostExplorerShare(cfg, { syncEC2 = false } = {}) {
  return toBase64Url({
    v: 1,
    c: packCfg(cfg),
    s: syncEC2 ? 1 : 0
  });
}

/**
 * Build a Fleet Optimizer config from HCP calculator estimate state.
 * @param {object} input
 * @param {object} input.estimate
 * @param {number} input.clusterCount
 * @param {string} input.rhContractTier onDemand|oneYear|threeYear
 * @param {number} input.ec2DiscountPercent
 * @param {object} input.catalogByType Map or object of instance metadata
 * @param {object} input.pricingByRegion
 */
export function buildCostExplorerConfig({
  estimate,
  clusterCount = 1,
  rhContractTier = "onDemand",
  ec2DiscountPercent = 0,
  catalogByType = new Map(),
  pricingByRegion = {}
}) {
  const getCatalog = (type) =>
    catalogByType instanceof Map ? catalogByType.get(type) : catalogByType?.[type];

  const vcpuByProfile = { general: 0, memory: 0, compute: 0 };
  const hourlyByProfile = { general: 0, memory: 0, compute: 0 };
  let burstVCPU = 0;
  let totalNodes = 0;
  let totalVcpu = 0;
  let gravitonVcpu = 0;
  let dominantProfile = "general";
  let dominantVcpu = 0;

  for (const set of estimate?.sets ?? []) {
    const instanceType = set?.instanceType;
    const catalog = getCatalog(instanceType);
    const perNodeVcpu = Number(catalog?.vcpus ?? 0);
    if (!(perNodeVcpu > 0)) {
      continue;
    }

    const profile = classifyFleetProfile(instanceType);
    const regionCode = set?.region ?? estimate?.region;
    const monthly = Number(
      pricingByRegion?.[regionCode]?.byInstanceType?.[instanceType]?.onDemandMonthly ?? 0
    );
    const hourly = monthly > 0 ? monthly / HOURS_PER_MONTH : 0;
    const graviton = isGravitonInstance(instanceType, catalog?.architecture ?? catalog?.arch);

    for (const pool of set?.pools ?? []) {
      const minNodes = Math.max(0, Number(pool?.min ?? 0));
      const maxNodes = Math.max(minNodes, Number(pool?.max ?? minNodes));
      const steadyVcpu = minNodes * perNodeVcpu;
      const burstNodes = Math.max(0, maxNodes - minNodes);

      vcpuByProfile[profile] += steadyVcpu;
      hourlyByProfile[profile] += minNodes * hourly;
      burstVCPU += burstNodes * perNodeVcpu;
      totalNodes += minNodes;
      totalVcpu += steadyVcpu;
      if (graviton) {
        gravitonVcpu += steadyVcpu;
      }
    }

    if (vcpuByProfile[profile] > dominantVcpu) {
      dominantVcpu = vcpuByProfile[profile];
      dominantProfile = profile;
    }
  }

  const rateFor = (profile) => {
    const vcpu = vcpuByProfile[profile];
    if (vcpu > 0 && hourlyByProfile[profile] > 0) {
      return Number((hourlyByProfile[profile] / vcpu).toFixed(4));
    }
    return DEFAULT_RATES[profile];
  };

  const avgVCPUPerNode =
    totalNodes > 0 ? Math.max(1, Math.round(totalVcpu / totalNodes)) : 8;
  const armPct =
    totalVcpu > 0 ? Math.min(100, Math.max(0, Math.round((gravitonVcpu / totalVcpu) * 100))) : 0;
  const discount = Number.isFinite(ec2DiscountPercent)
    ? Math.min(100, Math.max(0, ec2DiscountPercent))
    : 0;

  return {
    singleAZClusters: 0,
    multiAZClusters: 0,
    hcpClusters: Math.max(1, Number(clusterCount) || 1),
    generalVCPU: Math.round(vcpuByProfile.general),
    memoryVCPU: Math.round(vcpuByProfile.memory),
    computeVCPU: Math.round(vcpuByProfile.compute),
    burstVCPU: Math.round(burstVCPU),
    burstProfile: dominantProfile,
    burstAwsDiscount: false,
    burstUsagePct: 20,
    avgVCPUPerNode,
    rateGeneral: rateFor("general"),
    rateMemory: rateFor("memory"),
    rateCompute: rateFor("compute"),
    rosaContract: CONTRACT_MAP[rhContractTier] ?? "paygo",
    awsDiscountPct: discount,
    hcpMigrated: false,
    karpenter: false,
    burstSpot: false,
    armPct
  };
}

export function buildCostExplorerUrl(cfg, { pathname = "/experts/rosa/cost-explorer/" } = {}) {
  const code = encodeCostExplorerShare(cfg, { syncEC2: false });
  return `${pathname}#s=${code}`;
}
