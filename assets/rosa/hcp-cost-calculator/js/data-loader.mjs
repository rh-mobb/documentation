export async function loadJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to load ${url}: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

export async function loadSnapshotData(baseUrl) {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const [regions, catalog, manifest] = await Promise.all([
    loadJson(`${normalizedBaseUrl}/regions.json`),
    loadJson(`${normalizedBaseUrl}/instance-catalog.json`),
    loadJson(`${normalizedBaseUrl}/snapshot-manifest.json`)
  ]);

  const regionCodes =
    manifest?.regions ??
    (Array.isArray(regions?.regions) ? regions.regions.map((region) => region.code) : []);

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

  const filteredRegionsList = Array.isArray(regions?.regions)
    ? regions.regions.filter((region) => availableRegionCodes.has(region?.code))
    : [];
  const filteredManifestRegions = Array.isArray(manifest?.regions)
    ? manifest.regions.filter((regionCode) => availableRegionCodes.has(regionCode))
    : [];

  return {
    regions: {
      ...regions,
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
