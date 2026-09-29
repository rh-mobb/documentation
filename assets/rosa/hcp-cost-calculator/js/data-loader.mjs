import {
  readCachedRegionPricing,
  readCachedSnapshotCore,
  writeCachedRegionPricing,
  writeCachedSnapshotCore
} from "./snapshot-storage.mjs";

const LEGACY_REGIONS_FILE = "regions.json";
const LEGACY_CATALOG_FILE = "instance-catalog.json";
const DEFAULT_REGIONS_FILE = "hcp-regions-snapshot.json";
const DEFAULT_CATALOG_FILE = "hcp-instance-catalog.json";

const regionPricingCache = new Map();

export function resetDataLoaderCaches() {
  regionPricingCache.clear();
}

export async function loadJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to load ${url}: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

async function tryLoadJson(url) {
  try {
    return await loadJson(url);
  } catch (error) {
    console.warn(`Skipping ${url}: ${error.message}`);
    return null;
  }
}

async function loadFirstAvailableJson(baseUrl, candidates) {
  const uniqueCandidates = Array.from(
    new Set(candidates.filter((candidate) => typeof candidate === "string" && candidate.length > 0))
  );
  for (const fileName of uniqueCandidates) {
    const payload = await tryLoadJson(`${baseUrl}/${fileName}`);
    if (payload) {
      return payload;
    }
  }
  return null;
}

function resolveRegionsList(regionsPayload, manifest) {
  if (Array.isArray(manifest?.regions_detail) && manifest.regions_detail.length > 0) {
    return manifest.regions_detail;
  }
  if (Array.isArray(regionsPayload?.regions) && regionsPayload.regions.length > 0) {
    return regionsPayload.regions;
  }
  return [];
}

function buildSnapshotCore(manifest, regionsList, catalog, regionsPayload = null) {
  const manifestRegions = Array.isArray(manifest?.regions) ? manifest.regions : [];

  return {
    regions: {
      ...(regionsPayload ?? {}),
      regions: regionsList
    },
    catalog,
    pricingByRegion: {},
    manifest: {
      ...manifest,
      regions: manifestRegions
    }
  };
}

export async function loadSnapshotCore(baseUrl) {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const manifest = await loadJson(`${normalizedBaseUrl}/snapshot-manifest.json`);
  const snapshotVersion = manifest?.generated_at;

  const cached = readCachedSnapshotCore(snapshotVersion);
  if (cached) {
    return {
      ...cached,
      pricingByRegion: {}
    };
  }

  let regionsList = resolveRegionsList(null, manifest);
  const catalogCandidates = [
    manifest?.files?.instance_catalog,
    DEFAULT_CATALOG_FILE,
    LEGACY_CATALOG_FILE
  ];
  const catalog = await loadFirstAvailableJson(normalizedBaseUrl, catalogCandidates);

  if (!regionsList.length) {
    const regionsCandidates = [
      manifest?.files?.regions,
      DEFAULT_REGIONS_FILE,
      LEGACY_REGIONS_FILE
    ];
    const regionsPayload = await loadFirstAvailableJson(normalizedBaseUrl, regionsCandidates);
    regionsList = resolveRegionsList(regionsPayload, manifest);
  }

  if (!Array.isArray(catalog?.instances) || catalog.instances.length === 0) {
    throw new Error("Instance catalog could not be loaded.");
  }

  const snapshot = buildSnapshotCore(manifest, regionsList, catalog);
  writeCachedSnapshotCore(snapshot);
  return snapshot;
}

/**
 * Load pricing for the given region codes one at a time (avoids Akamai rate limits).
 * Mutates and returns pricingByRegion.
 */
export async function ensureRegionPricing(
  baseUrl,
  regionCodes,
  pricingByRegion = {},
  { snapshotVersion } = {}
) {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const uniqueCodes = Array.from(
    new Set(
      (Array.isArray(regionCodes) ? regionCodes : [...regionCodes])
        .filter((regionCode) => typeof regionCode === "string" && regionCode.length > 0)
    )
  );

  for (const regionCode of uniqueCodes) {
    if (pricingByRegion[regionCode]) {
      continue;
    }
    const memoryCached = regionPricingCache.get(regionCode);
    if (memoryCached) {
      pricingByRegion[regionCode] = memoryCached;
      continue;
    }
    const sessionCached = readCachedRegionPricing(regionCode, snapshotVersion);
    if (sessionCached) {
      regionPricingCache.set(regionCode, sessionCached);
      pricingByRegion[regionCode] = sessionCached;
      continue;
    }
    try {
      const payload = await loadJson(`${normalizedBaseUrl}/pricing/${regionCode}.json`);
      regionPricingCache.set(regionCode, payload);
      pricingByRegion[regionCode] = payload;
      writeCachedRegionPricing(regionCode, snapshotVersion, payload);
    } catch (error) {
      console.warn(`Skipping pricing for region ${regionCode}: ${error.message}`);
    }
  }

  return pricingByRegion;
}

export async function loadSnapshotData(baseUrl, { regionCodes } = {}) {
  const core = await loadSnapshotCore(baseUrl);
  const codes =
    regionCodes ??
    (Array.isArray(core.manifest?.regions) && core.manifest.regions.length > 0
      ? core.manifest.regions
      : core.regions.regions.map((region) => region?.code).filter(Boolean));

  const pricingByRegion = await ensureRegionPricing(baseUrl, codes, {}, {
    snapshotVersion: core.manifest?.generated_at
  });
  const availableRegionCodes = new Set(Object.keys(pricingByRegion));
  if (availableRegionCodes.size === 0) {
    throw new Error("No region pricing files could be loaded.");
  }

  const filteredRegionsList = core.regions.regions.filter((region) =>
    availableRegionCodes.has(region?.code)
  );
  const filteredManifestRegions = Array.isArray(core.manifest?.regions)
    ? core.manifest.regions.filter((regionCode) => availableRegionCodes.has(regionCode))
    : [];

  return {
    regions: {
      ...core.regions,
      regions: filteredRegionsList
    },
    catalog: core.catalog,
    pricingByRegion,
    manifest: {
      ...core.manifest,
      regions: filteredManifestRegions
    }
  };
}

export function getRegionPricing(pricingByRegion, regionCode) {
  const payload = pricingByRegion?.[regionCode];
  if (!payload) {
    throw new Error(`Missing pricing for region ${regionCode}`);
  }
  return payload;
}
