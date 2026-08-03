export const DRAFT_STORAGE_KEY = "rosa_hcp_calc_draft_v1";
export const DRAFT_VERSION = 1;

function asPositiveInt(value, fallback = 1) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.max(1, parsed) : fallback;
}

function asNonNegativeInt(value, fallback = 0) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.max(0, parsed) : fallback;
}

function sanitizeSelection(entry) {
  if (!entry || typeof entry !== "object") {
    return null;
  }
  const instanceType = String(entry.instanceType ?? "").trim();
  const region = String(entry.region ?? "").trim();
  if (!instanceType || !region) {
    return null;
  }
  return {
    instanceType,
    region,
    count: asPositiveInt(entry.count, 1)
  };
}

function sanitizePool(pool) {
  if (!pool || typeof pool !== "object") {
    return null;
  }
  const instanceType = String(pool.instanceType ?? "").trim();
  const az = String(pool.az ?? "").trim();
  if (!instanceType || !az) {
    return null;
  }
  return {
    id: typeof pool.id === "string" ? pool.id : undefined,
    name: String(pool.name ?? "workers").trim() || "workers",
    instanceType,
    az,
    count: asNonNegativeInt(pool.count, 0)
  };
}

function sanitizeFilters(filters) {
  if (!filters || typeof filters !== "object") {
    return undefined;
  }
  return {
    architecture: String(filters.architecture ?? "x86-intel"),
    category: String(filters.category ?? "general-purpose"),
    family: String(filters.family ?? "m7i"),
    instanceType: String(filters.instanceType ?? "m7i.xlarge"),
    threeAz: Boolean(filters.threeAz)
  };
}

function sanitizeCluster(cluster) {
  if (!cluster || typeof cluster !== "object") {
    return null;
  }
  const name = String(cluster.name ?? "Cluster").trim() || "Cluster";
  const region = String(cluster.region ?? "").trim();
  if (!region) {
    return null;
  }
  const pools = (cluster.pools ?? []).map(sanitizePool).filter(Boolean);
  return {
    id: typeof cluster.id === "string" ? cluster.id : undefined,
    name,
    region,
    filters: sanitizeFilters(cluster.filters),
    pools
  };
}

/**
 * Build a JSON-serializable draft from live calculator state.
 */
export function buildDraftPayload({
  mode = "basic",
  basicState,
  expertState,
  discounting = {},
  instanceFilters = null
} = {}) {
  const selections = (basicState?.selections ?? []).map(sanitizeSelection).filter(Boolean);
  const clusters = (expertState?.clusters ?? []).map(sanitizeCluster).filter(Boolean);
  return {
    v: DRAFT_VERSION,
    mode: mode === "expert" ? "expert" : "basic",
    basic: {
      clusterCount: asPositiveInt(basicState?.clusterCount, 1),
      region: String(basicState?.region ?? "us-east-1"),
      selections
    },
    expert: {
      clusters
    },
    discounting: {
      ec2SavingsPlanDiscountPercent: Math.max(
        0,
        Math.min(90, Number(discounting.ec2SavingsPlanDiscountPercent) || 0)
      ),
      rhContractTier: ["onDemand", "oneYear", "threeYear"].includes(discounting.rhContractTier)
        ? discounting.rhContractTier
        : "onDemand",
      summaryPriceUnit: discounting.summaryPriceUnit === "monthly" ? "monthly" : "yearly"
    },
    instanceFilters: instanceFilters
      ? {
          architecture: String(instanceFilters.architecture ?? "x86-intel"),
          category: String(instanceFilters.category ?? "general-purpose"),
          family: String(instanceFilters.family ?? "m7i")
        }
      : undefined
  };
}

/**
 * Parse and validate a stored draft. Returns null when unusable.
 */
export function parseDraftPayload(raw) {
  let data = raw;
  if (typeof raw === "string") {
    try {
      data = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!data || typeof data !== "object" || data.v !== DRAFT_VERSION) {
    return null;
  }
  const payload = buildDraftPayload({
    mode: data.mode,
    basicState: data.basic,
    expertState: data.expert,
    discounting: data.discounting,
    instanceFilters: data.instanceFilters
  });
  if (!payload.basic.selections.length && !payload.expert.clusters.length) {
    return null;
  }
  return payload;
}

export function loadDraft(storage = globalThis.localStorage) {
  if (!storage?.getItem) {
    return null;
  }
  try {
    return parseDraftPayload(storage.getItem(DRAFT_STORAGE_KEY));
  } catch {
    return null;
  }
}

export function saveDraft(payload, storage = globalThis.localStorage) {
  if (!storage?.setItem) {
    return false;
  }
  const normalized = parseDraftPayload(payload);
  if (!normalized) {
    return false;
  }
  try {
    storage.setItem(DRAFT_STORAGE_KEY, JSON.stringify(normalized));
    return true;
  } catch {
    return false;
  }
}

export function clearDraft(storage = globalThis.localStorage) {
  if (!storage?.removeItem) {
    return;
  }
  try {
    storage.removeItem(DRAFT_STORAGE_KEY);
  } catch {
    // ignore quota / privacy mode errors
  }
}
