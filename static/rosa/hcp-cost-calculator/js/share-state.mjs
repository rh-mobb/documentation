export const SHARE_FORMAT = "hcp";
export const SHARE_VERSION = 1;

const VALID_RH_TIERS = new Set(["onDemand", "oneYear", "threeYear"]);
const VALID_UNITS = new Set(["hourly", "monthly", "yearly"]);
const VALID_MODES = new Set(["basic", "expert"]);

export function toBase64Url(obj) {
  const json = JSON.stringify(obj);
  const bytes = new TextEncoder().encode(json);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(str) {
  let b64 = String(str ?? "")
    .trim()
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  while (b64.length % 4) {
    b64 += "=";
  }
  const binary = atob(b64);
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

function packDiscounts(scenario) {
  return {
    ed: Number(scenario?.ec2SavingsPlanDiscountPercent ?? 0),
    rt: scenario?.rhContractTier ?? "onDemand",
    pu: scenario?.summaryPriceUnit ?? "yearly"
  };
}

function unpackDiscounts(packed) {
  let ec2SavingsPlanDiscountPercent = Number(packed.ed ?? 0);
  if (!Number.isFinite(ec2SavingsPlanDiscountPercent)) {
    ec2SavingsPlanDiscountPercent = 0;
  }
  ec2SavingsPlanDiscountPercent = Math.min(100, Math.max(0, ec2SavingsPlanDiscountPercent));
  return {
    ec2SavingsPlanDiscountPercent,
    rhContractTier: VALID_RH_TIERS.has(packed.rt) ? packed.rt : "onDemand",
    summaryPriceUnit: VALID_UNITS.has(packed.pu) ? packed.pu : "yearly"
  };
}

/**
 * @param {object} scenario
 * @param {"basic"|"expert"} [scenario.mode]
 * @param {number} [scenario.clusterCount]
 * @param {number} scenario.ec2SavingsPlanDiscountPercent
 * @param {string} scenario.rhContractTier
 * @param {string} scenario.summaryPriceUnit
 * @param {Array<{instanceType:string, region:string, count:number}>} [scenario.instances]
 * @param {Array<{name:string, region:string, pools:Array<{name:string, instanceType:string, az:string, count:number}>}>} [scenario.clusters]
 */
export function encodeShareState(scenario) {
  const mode = VALID_MODES.has(scenario?.mode) ? scenario.mode : "basic";
  const discounts = packDiscounts(scenario);

  if (mode === "expert") {
    const clusters = (scenario?.clusters ?? [])
      .map((cluster) => {
        const pools = (cluster.pools ?? [])
          .map((pool) => [
            String(pool.name ?? "workers").trim(),
            String(pool.instanceType ?? "").trim(),
            String(pool.az ?? "").trim(),
            Math.max(0, Number.parseInt(pool.count, 10) || 0)
          ])
          .filter((row) => row[1] && row[2]);
        return [String(cluster.name ?? "Cluster").trim(), String(cluster.region ?? "").trim(), pools];
      })
      .filter((row) => row[1]);

    return toBase64Url({
      v: SHARE_VERSION,
      t: SHARE_FORMAT,
      c: {
        m: "expert",
        ...discounts,
        cl: clusters
      }
    });
  }

  const instances = (scenario?.instances ?? [])
    .map((entry) => [
      String(entry.instanceType ?? "").trim(),
      String(entry.region ?? "").trim(),
      Math.max(1, Number.parseInt(entry.count, 10) || 1)
    ])
    .filter(([type, region]) => type && region);

  return toBase64Url({
    v: SHARE_VERSION,
    t: SHARE_FORMAT,
    c: {
      m: "basic",
      cc: Math.max(1, Number.parseInt(scenario?.clusterCount, 10) || 1),
      ...discounts,
      i: instances
    }
  });
}

export function decodeShareState(code) {
  const payload = fromBase64Url(code);
  if (!payload || payload.v !== SHARE_VERSION || payload.t !== SHARE_FORMAT || !payload.c) {
    throw new Error("Unsupported or invalid HCP calculator share code.");
  }

  const packed = payload.c;
  const mode = VALID_MODES.has(packed.m) ? packed.m : "basic";
  const discounts = unpackDiscounts(packed);

  if (mode === "expert") {
    const clusters = [];
    for (const row of packed.cl ?? []) {
      if (!Array.isArray(row) || row.length < 3) {
        continue;
      }
      const name = String(row[0] ?? "Cluster").trim() || "Cluster";
      const region = String(row[1] ?? "").trim();
      if (!region) {
        continue;
      }
      const pools = [];
      for (const poolRow of row[2] ?? []) {
        if (!Array.isArray(poolRow) || poolRow.length < 4) {
          continue;
        }
        const poolName = String(poolRow[0] ?? "workers").trim() || "workers";
        const instanceType = String(poolRow[1] ?? "").trim();
        const az = String(poolRow[2] ?? "").trim();
        const count = Number.parseInt(poolRow[3], 10);
        if (!instanceType || !az || !Number.isFinite(count) || count < 0) {
          continue;
        }
        pools.push({ name: poolName, instanceType, az, count });
      }
      clusters.push({ name, region, pools });
    }
    if (!clusters.length) {
      throw new Error("Share code has no valid expert clusters.");
    }
    return {
      mode: "expert",
      ...discounts,
      clusters
    };
  }

  let clusterCount = Number.parseInt(packed.cc, 10);
  if (!Number.isFinite(clusterCount) || clusterCount < 1) {
    clusterCount = 1;
  }

  const instances = [];
  for (const row of packed.i ?? []) {
    if (!Array.isArray(row) || row.length < 3) {
      continue;
    }
    const instanceType = String(row[0] ?? "").trim();
    const region = String(row[1] ?? "").trim();
    const count = Number.parseInt(row[2], 10);
    if (!instanceType || !region || !Number.isFinite(count) || count < 1) {
      continue;
    }
    instances.push({ instanceType, region, count });
  }

  if (!instances.length) {
    throw new Error("Share code has no valid instance rows.");
  }

  return {
    mode: "basic",
    clusterCount,
    ...discounts,
    instances
  };
}

export function extractShareCode(input) {
  const text = String(input ?? "").trim();
  if (!text) {
    return "";
  }
  try {
    const url = new URL(text);
    if (url.hash.startsWith("#s=")) {
      return url.hash.slice(3);
    }
    const queryCode = url.searchParams.get("s");
    if (queryCode) {
      return queryCode;
    }
  } catch {
    /* not a URL */
  }
  if (text.startsWith("#s=")) {
    return text.slice(3);
  }
  return text;
}

export function shareCodeFromLocation(locationLike = globalThis.location) {
  if (!locationLike) {
    return "";
  }
  const hash = locationLike.hash ?? "";
  if (hash.startsWith("#s=")) {
    return hash.slice(3);
  }
  try {
    return new URLSearchParams(locationLike.search ?? "").get("s") || "";
  } catch {
    return "";
  }
}

export function buildShareUrl(code, { origin, pathname } = {}) {
  const baseOrigin = origin ?? globalThis.location?.origin ?? "";
  const basePath = pathname ?? globalThis.location?.pathname ?? "/experts/rosa/hcp-cost-calculator/";
  return `${baseOrigin}${basePath}#s=${code}`;
}
