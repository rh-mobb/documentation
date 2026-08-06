const DEFAULT_INSTANCE_TYPE = "m7i.xlarge";
const DEFAULT_SET_NAME = "Default Set";
const DEFAULT_POOL_BASE_NAME = "workers";
const DEFAULT_CLUSTER_NAME = "Cluster 1";
const FALLBACK_ZONES = ["a", "b", "c"];

function createId(prefix = "id") {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
}

function createSetId() {
  return createId("set");
}

function normalizeZones(zones = []) {
  const selected = zones.slice(0, 3);
  while (selected.length < 3) {
    selected.push(FALLBACK_ZONES[selected.length]);
  }
  return selected;
}

export function createSet({ name, instanceType, poolBaseName, zones, enforceThreeZones = true }) {
  const normalizedZones = enforceThreeZones ? normalizeZones(zones) : zones.slice(0, 3);
  const finalZones = normalizedZones.length ? normalizedZones : [FALLBACK_ZONES[0]];
  return {
    id: createSetId(),
    name: name ?? DEFAULT_SET_NAME,
    instanceType: instanceType ?? DEFAULT_INSTANCE_TYPE,
    poolBaseName: poolBaseName ?? DEFAULT_POOL_BASE_NAME,
    pools: finalZones.map((az) => ({
      az,
      min: 1,
      max: 1
    }))
  };
}

export function createDefaultSet({ name, instanceType, poolBaseName, zones }) {
  return createSet({
    name,
    instanceType,
    poolBaseName: poolBaseName ?? DEFAULT_POOL_BASE_NAME,
    zones,
    enforceThreeZones: true
  });
}

export function createInitialEstimate({ region, zones }) {
  return {
    region,
    sets: [
      createDefaultSet({
        name: DEFAULT_SET_NAME,
        instanceType: DEFAULT_INSTANCE_TYPE,
        zones
      })
    ]
  };
}

export function duplicateSet(set) {
  return {
    ...set,
    id: createSetId(),
    name: `${set.name} Copy`,
    pools: set.pools.map((pool) => ({ ...pool }))
  };
}

export function createExpertPool({
  name = DEFAULT_POOL_BASE_NAME,
  instanceType = DEFAULT_INSTANCE_TYPE,
  az,
  count = 1
} = {}) {
  return {
    id: createId("pool"),
    name,
    instanceType,
    az: az ?? "us-east-1a",
    count: Math.max(0, Number.parseInt(count, 10) || 0)
  };
}

export function createDefaultClusterFilters({
  architecture = "x86-intel",
  category = "general-purpose",
  family = "m7i",
  instanceType = DEFAULT_INSTANCE_TYPE,
  threeAz = false
} = {}) {
  return {
    architecture,
    category,
    family,
    instanceType,
    threeAz: Boolean(threeAz)
  };
}

export function createDefaultMultiAzPools({
  region = "us-east-1",
  zones = [],
  instanceType = DEFAULT_INSTANCE_TYPE,
  count = 3
} = {}) {
  const azs =
    Array.isArray(zones) && zones.length >= 3
      ? zones.slice(0, 3)
      : [`${region}a`, `${region}b`, `${region}c`];
  const nodeCount = Math.max(0, Number.parseInt(count, 10) || 0);
  return azs.map((az, index) =>
    createExpertPool({
      name: `${DEFAULT_POOL_BASE_NAME}-${String(az).slice(-1) || index + 1}`,
      instanceType,
      az,
      count: nodeCount
    })
  );
}

export function createExpertCluster({
  name = DEFAULT_CLUSTER_NAME,
  region = "us-east-1",
  pools,
  filters
} = {}) {
  return {
    id: createId("cluster"),
    name,
    region,
    filters: createDefaultClusterFilters(filters),
    // Explicit pools (including []) win; omit pools only when callers pass them.
    pools: Array.isArray(pools) ? pools.map((pool) => createExpertPool(pool)) : []
  };
}

export function createInitialExpertState({ region = "us-east-1", zones = [] } = {}) {
  return {
    clusters: [
      createExpertCluster({
        name: DEFAULT_CLUSTER_NAME,
        region,
        pools: createDefaultMultiAzPools({ region, zones, count: 3 })
      })
    ]
  };
}

export function createInitialBasicState({
  region = "us-east-1",
  instanceType = DEFAULT_INSTANCE_TYPE,
  count = 3,
  clusterCount = 1
} = {}) {
  return {
    clusterCount: Math.max(1, Number.parseInt(clusterCount, 10) || 1),
    region,
    selections: [{ instanceType, region, count: Math.max(1, Number.parseInt(count, 10) || 1) }]
  };
}

/**
 * Project expert clusters into the legacy estimate.sets shape used by pricing helpers.
 * Each pool becomes one set with a single AZ pool (min=max=count).
 */
export function projectExpertStateToEstimate(expertState) {
  const clusters = expertState?.clusters ?? [];
  const sets = [];
  for (const cluster of clusters) {
    const region = cluster.region ?? "us-east-1";
    for (const pool of cluster.pools ?? []) {
      const count = Math.max(0, Number.parseInt(pool.count, 10) || 0);
      sets.push({
        id: pool.id ?? createId("set"),
        name: `${cluster.name ?? "Cluster"} / ${pool.name ?? "pool"}`,
        clusterName: cluster.name ?? "Cluster",
        instanceType: pool.instanceType ?? DEFAULT_INSTANCE_TYPE,
        region,
        poolBaseName: pool.name ?? DEFAULT_POOL_BASE_NAME,
        pools: [
          {
            az: pool.az ?? `${region}a`,
            min: count,
            max: count
          }
        ]
      });
    }
  }
  return {
    region: clusters[0]?.region ?? "us-east-1",
    sets
  };
}

/**
 * Project basic selections into the legacy estimate.sets shape.
 */
export function projectBasicSelectionsToEstimate(selections, fallbackRegion = "us-east-1") {
  const rows = selections ?? [];
  const sets = rows.map((entry, index) => {
    const region = entry.region ?? fallbackRegion;
    const count = Math.max(1, Number.parseInt(entry.count, 10) || 1);
    const az = `${region}a`;
    return {
      id: createId("set"),
      name: index === 0 ? DEFAULT_SET_NAME : `Set ${index + 1}`,
      instanceType: entry.instanceType ?? DEFAULT_INSTANCE_TYPE,
      region,
      poolBaseName: index === 0 ? DEFAULT_POOL_BASE_NAME : `pool-${index + 1}`,
      pools: [{ az, min: count, max: count }]
    };
  });
  return {
    region: rows[0]?.region ?? fallbackRegion,
    sets
  };
}
