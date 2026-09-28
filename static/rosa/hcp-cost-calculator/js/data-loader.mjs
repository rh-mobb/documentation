const LEGACY_REGIONS_FILE = "regions.json";
const LEGACY_CATALOG_FILE = "instance-catalog.json";
const DEFAULT_REGIONS_FILE = "hcp-regions-snapshot.json";
const DEFAULT_CATALOG_FILE = "hcp-instance-catalog.json";

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
  if (Array.isArray(regionsPayload?.regions) && regionsPayload.regions.length > 0) {
    return regionsPayload.regions;
  }
  if (Array.isArray(manifest?.regions_detail) && manifest.regions_detail.length > 0) {
    return manifest.regions_detail;
  }
  return [];
}

export async function loadSnapshotData(baseUrl) {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const manifest = await loadJson(`${normalizedBaseUrl}/snapshot-manifest.json`);

  const regionsCandidates = [
    manifest?.files?.regions,
    DEFAULT_REGIONS_FILE,
    LEGACY_REGIONS_FILE
  ];
  const catalogCandidates = [
    manifest?.files?.instance_catalog,
    DEFAULT_CATALOG_FILE,
    LEGACY_CATALOG_FILE
  ];

  const [regionsPayload, catalog] = await Promise.all([
    loadFirstAvailableJson(normalizedBaseUrl, regionsCandidates),
    loadFirstAvailableJson(normalizedBaseUrl, catalogCandidates)
  ]);

  if (!Array.isArray(catalog?.instances) || catalog.instances.length === 0) {
    throw new Error("Instance catalog could not be loaded.");
  }

  const regionsList = resolveRegionsList(regionsPayload, manifest);
  const regionCodes =
    (Array.isArray(manifest?.regions) && manifest.regions.length > 0
      ? manifest.regions
      : regionsList.map((region) => region?.code).filter(Boolean));

  const pricingEntries = await Promise.all(
    regionCodes.map(async (regionCode) => {
      try {
        const payload = await loadJson(`${normalizedBaseUrl}/pricing/${regionCode}.json`);
        return [regionCode, payload];
      } catch (error) {
        console.warn(`Skipping pricing for region ${regionCode}: ${error.message}`);
        return null;
      }
    })
  );

  const pricingByRegion = Object.fromEntries(pricingEntries.filter(Boolean));
  const availableRegionCodes = new Set(Object.keys(pricingByRegion));
  if (availableRegionCodes.size === 0) {
    throw new Error("No region pricing files could be loaded.");
  }

  const filteredRegionsList = regionsList.filter((region) => availableRegionCodes.has(region?.code));
  const filteredManifestRegions = Array.isArray(manifest?.regions)
    ? manifest.regions.filter((regionCode) => availableRegionCodes.has(regionCode))
    : [];

  return {
    regions: {
      ...(regionsPayload ?? {}),
      regions: filteredRegionsList
    },
    catalog,
    pricingByRegion,
    manifest: {
      ...manifest,
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
