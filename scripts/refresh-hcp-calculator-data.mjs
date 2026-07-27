#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED_TIERS = ["onDemandMonthly", "oneYearMonthly", "threeYearMonthly"];

function assertCondition(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function readJson(filePath) {
  const raw = await readFile(filePath, "utf8");
  return JSON.parse(raw);
}

async function writeJson(filePath, value) {
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  await writeFile(filePath, serialized, "utf8");
}

function validateRegions(regionsPayload) {
  const regions = regionsPayload?.regions;
  assertCondition(Array.isArray(regions) && regions.length > 0, "regions.json must contain a non-empty regions array.");
  for (const region of regions) {
    assertCondition(typeof region?.code === "string" && region.code.length > 0, "Each region must include a non-empty code.");
    assertCondition(Array.isArray(region?.zones) && region.zones.length > 0, `Region ${region.code} must include zones.`);
  }
  return regions.map((region) => region.code);
}

function validateCatalog(catalogPayload) {
  const instances = catalogPayload?.instances;
  assertCondition(Array.isArray(instances) && instances.length > 0, "instance-catalog.json must contain a non-empty instances array.");
  const catalogTypes = new Set();
  for (const instance of instances) {
    assertCondition(typeof instance?.type === "string" && instance.type.length > 0, "Each catalog instance requires a type.");
    catalogTypes.add(instance.type);
  }
  return catalogTypes;
}

function validatePricingPayload(regionCode, pricingPayload, catalogTypes) {
  assertCondition(pricingPayload?.region === regionCode, `pricing/${regionCode}.json region must be ${regionCode}.`);
  const byInstanceType = pricingPayload?.byInstanceType;
  assertCondition(
    byInstanceType && typeof byInstanceType === "object" && !Array.isArray(byInstanceType),
    `pricing/${regionCode}.json must contain byInstanceType object.`
  );

  for (const [instanceType, tiers] of Object.entries(byInstanceType)) {
    assertCondition(
      catalogTypes.has(instanceType),
      `Unknown instance in pricing/${regionCode}.json: ${instanceType} is not present in instance-catalog.json.`
    );
    for (const tierField of REQUIRED_TIERS) {
      assertCondition(
        Object.prototype.hasOwnProperty.call(tiers, tierField),
        `Missing required tier field ${tierField} for ${instanceType} in pricing/${regionCode}.json.`
      );
      assertCondition(
        Number.isFinite(tiers[tierField]),
        `Invalid ${tierField} for ${instanceType} in pricing/${regionCode}.json. Expected numeric value.`
      );
    }
  }
}

async function refresh() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDir, "..");
  const dataRoot = path.join(repoRoot, "static", "rosa", "hcp-cost-calculator", "data");
  const pricingDir = path.join(dataRoot, "pricing");

  await mkdir(pricingDir, { recursive: true });

  const regionsPath = path.join(dataRoot, "regions.json");
  const catalogPath = path.join(dataRoot, "instance-catalog.json");
  const manifestPath = path.join(dataRoot, "snapshot-manifest.json");

  const [regionsPayload, catalogPayload, manifestPayload] = await Promise.all([
    readJson(regionsPath),
    readJson(catalogPath),
    readJson(manifestPath)
  ]);

  const regionCodes = validateRegions(regionsPayload);
  const catalogTypes = validateCatalog(catalogPayload);

  const pricingByRegion = {};
  for (const regionCode of regionCodes) {
    const pricingPath = path.join(pricingDir, `${regionCode}.json`);
    const pricingPayload = await readJson(pricingPath);
    validatePricingPayload(regionCode, pricingPayload, catalogTypes);
    pricingByRegion[regionCode] = pricingPayload;
  }

  const generatedAt = process.env.HCP_PRICING_GENERATED_AT ?? new Date().toISOString();

  const updatedRegions = {
    ...regionsPayload,
    generated_at: generatedAt
  };
  const updatedCatalog = {
    ...catalogPayload,
    generated_at: generatedAt
  };

  await writeJson(regionsPath, updatedRegions);
  await writeJson(catalogPath, updatedCatalog);

  for (const regionCode of regionCodes) {
    await writeJson(path.join(pricingDir, `${regionCode}.json`), {
      ...pricingByRegion[regionCode],
      generated_at: generatedAt
    });
  }

  const updatedManifest = {
    version: manifestPayload?.version ?? 1,
    generated_at: generatedAt,
    runtime_base_path: "/experts/rosa/hcp-cost-calculator/data",
    regions: regionCodes,
    files: {
      regions: "regions.json",
      instance_catalog: "instance-catalog.json",
      pricing: Object.fromEntries(regionCodes.map((regionCode) => [regionCode, `pricing/${regionCode}.json`]))
    }
  };
  await writeJson(manifestPath, updatedManifest);

  console.log(`Validated ${catalogTypes.size} catalog instance types.`);
  console.log(`Validated pricing for ${regionCodes.length} region(s).`);
  console.log(`Updated snapshot files with generated_at=${generatedAt}.`);
}

refresh().catch((error) => {
  console.error(`HCP pricing refresh failed: ${error.message}`);
  process.exitCode = 1;
});
