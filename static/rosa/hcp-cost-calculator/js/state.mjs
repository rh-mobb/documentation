const DEFAULT_INSTANCE_TYPE = "m7i.xlarge";
const DEFAULT_SET_NAME = "Default Set";
const DEFAULT_POOL_BASE_NAME = "workers";
const FALLBACK_ZONES = ["a", "b", "c"];

function createSetId() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `set-${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
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
