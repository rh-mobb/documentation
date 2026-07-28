export const SHARE_FORMAT = "hcp";
export const SHARE_VERSION = 1;

const VALID_RH_TIERS = new Set(["onDemand", "oneYear", "threeYear"]);
const VALID_UNITS = new Set(["hourly", "monthly", "yearly"]);

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

/**
 * @param {object} scenario
 * @param {number} scenario.clusterCount
 * @param {number} scenario.ec2SavingsPlanDiscountPercent
 * @param {string} scenario.rhContractTier
 * @param {string} scenario.summaryPriceUnit
 * @param {Array<{instanceType:string, region:string, count:number}>} scenario.instances
 */
export function encodeShareState(scenario) {
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
      cc: Math.max(1, Number.parseInt(scenario?.clusterCount, 10) || 1),
      ed: Number(scenario?.ec2SavingsPlanDiscountPercent ?? 0),
      rt: scenario?.rhContractTier ?? "onDemand",
      pu: scenario?.summaryPriceUnit ?? "yearly",
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
  let clusterCount = Number.parseInt(packed.cc, 10);
  if (!Number.isFinite(clusterCount) || clusterCount < 1) {
    clusterCount = 1;
  }

  let ec2SavingsPlanDiscountPercent = Number(packed.ed ?? 0);
  if (!Number.isFinite(ec2SavingsPlanDiscountPercent)) {
    ec2SavingsPlanDiscountPercent = 0;
  }
  ec2SavingsPlanDiscountPercent = Math.min(100, Math.max(0, ec2SavingsPlanDiscountPercent));

  const rhContractTier = VALID_RH_TIERS.has(packed.rt) ? packed.rt : "onDemand";
  const summaryPriceUnit = VALID_UNITS.has(packed.pu) ? packed.pu : "yearly";

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
    clusterCount,
    ec2SavingsPlanDiscountPercent,
    rhContractTier,
    summaryPriceUnit,
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
