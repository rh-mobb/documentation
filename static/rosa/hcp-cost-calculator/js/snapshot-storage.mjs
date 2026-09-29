const CORE_VERSION_KEY = "hcp-calculator-snapshot:version";
const CORE_DATA_KEY = "hcp-calculator-snapshot:core";
const PRICING_VERSION_KEY = "hcp-calculator-pricing:version";

function getSessionStorage() {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

function pricingStorageKey(regionCode) {
  return `hcp-calculator-pricing:${regionCode}`;
}

export function readCachedSnapshotCore(expectedVersion) {
  const storage = getSessionStorage();
  if (!storage || !expectedVersion) {
    return null;
  }
  try {
    if (storage.getItem(CORE_VERSION_KEY) !== expectedVersion) {
      return null;
    }
    const raw = storage.getItem(CORE_DATA_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed?.catalog?.instances) || parsed.catalog.instances.length === 0) {
      return null;
    }
    return parsed;
  } catch (error) {
    console.warn(`Failed to read cached snapshot core: ${error.message}`);
    return null;
  }
}

export function writeCachedSnapshotCore(snapshot) {
  const storage = getSessionStorage();
  const version = snapshot?.manifest?.generated_at;
  if (!storage || !version) {
    return;
  }
  try {
    storage.setItem(
      CORE_VERSION_KEY,
      version
    );
    storage.setItem(
      CORE_DATA_KEY,
      JSON.stringify({
        regions: snapshot.regions,
        catalog: snapshot.catalog,
        manifest: snapshot.manifest
      })
    );
  } catch (error) {
    console.warn(`Failed to cache snapshot core: ${error.message}`);
  }
}

export function readCachedRegionPricing(regionCode, expectedVersion) {
  const storage = getSessionStorage();
  if (!storage || !expectedVersion || !regionCode) {
    return null;
  }
  try {
    if (storage.getItem(PRICING_VERSION_KEY) !== expectedVersion) {
      return null;
    }
    const raw = storage.getItem(pricingStorageKey(regionCode));
    return raw ? JSON.parse(raw) : null;
  } catch (error) {
    console.warn(`Failed to read cached pricing for ${regionCode}: ${error.message}`);
    return null;
  }
}

export function writeCachedRegionPricing(regionCode, expectedVersion, payload) {
  const storage = getSessionStorage();
  if (!storage || !expectedVersion || !regionCode || !payload) {
    return;
  }
  try {
    storage.setItem(PRICING_VERSION_KEY, expectedVersion);
    storage.setItem(pricingStorageKey(regionCode), JSON.stringify(payload));
  } catch (error) {
    console.warn(`Failed to cache pricing for ${regionCode}: ${error.message}`);
  }
}

export function clearSnapshotStorage() {
  const storage = getSessionStorage();
  if (!storage) {
    return;
  }
  try {
    const keysToRemove = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (
        key === CORE_VERSION_KEY ||
        key === CORE_DATA_KEY ||
        key === PRICING_VERSION_KEY ||
        key?.startsWith("hcp-calculator-pricing:")
      ) {
        keysToRemove.push(key);
      }
    }
    keysToRemove.forEach((key) => storage.removeItem(key));
  } catch (error) {
    console.warn(`Failed to clear snapshot storage: ${error.message}`);
  }
}
