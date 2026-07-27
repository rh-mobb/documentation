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
      const payload = await loadJson(`${normalizedBaseUrl}/pricing/${regionCode}.json`);
      return [regionCode, payload];
    })
  );

  const pricingByRegion = Object.fromEntries(pricingEntries);
  return { regions, catalog, pricingByRegion, manifest };
}

export function getRegionPricing(pricingByRegion, regionCode) {
  const payload = pricingByRegion?.[regionCode];
  if (!payload) {
    throw new Error(`Missing pricing for region ${regionCode}`);
  }
  return payload;
}
