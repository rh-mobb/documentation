#!/usr/bin/env node

import { mkdir, rm, writeFile } from "node:fs/promises";
import { execFile as execFileCb } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const HOURS_PER_MONTH = 730;
const RH_DOC_SERVICE_DEFINITION_URL =
  "https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition";
const WGARCIA_REGIONS_URL = "https://rosa.wigarcia.com/data/regions.json";
const execFile = promisify(execFileCb);

function assertCondition(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

async function writeJson(filePath, value) {
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  await writeFile(filePath, serialized, "utf8");
}

function regionSort(a, b) {
  if (a === "us-east-1") {
    return -1;
  }
  if (b === "us-east-1") {
    return 1;
  }
  return a.localeCompare(b);
}

async function runRosaJsonCommand(args, description) {
  try {
    const { stdout } = await execFile("rosa", args, { maxBuffer: 20 * 1024 * 1024 });
    const parsed = JSON.parse(stdout);
    assertCondition(Array.isArray(parsed), `${description} returned unexpected JSON shape.`);
    return parsed;
  } catch (error) {
    throw new Error(`${description} failed. Ensure ROSA CLI is installed and authenticated. ${error.message}`);
  }
}

function toGiBFromBytes(bytesValue) {
  const bytes = Number(bytesValue ?? 0);
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return 0;
  }
  return Math.round((bytes / 1024 ** 3) * 100) / 100;
}

function parseNumber(value) {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.replaceAll(",", "").trim();
  if (!normalized.length) {
    return null;
  }
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function computeMonthlyTier(pricingRow, preferredAnnualField, fallbackAnnualField) {
  const annualPreferred = parseNumber(pricingRow[preferredAnnualField]);
  if (annualPreferred && annualPreferred > 0) {
    return annualPreferred / 12;
  }
  const annualFallback = parseNumber(pricingRow[fallbackAnnualField]);
  if (annualFallback && annualFallback > 0) {
    return annualFallback / 12;
  }
  const onDemandHourly = parseNumber(pricingRow.priceOnDemand);
  if (onDemandHourly && onDemandHourly > 0) {
    return onDemandHourly * HOURS_PER_MONTH;
  }
  return null;
}

function buildPricingByInstanceType(pricingRows, supportedInstanceTypes) {
  const byInstanceType = {};
  for (const pricingRow of pricingRows) {
    const instanceType = `${pricingRow?.type ?? ""}`.toLowerCase().trim();
    if (!instanceType || !supportedInstanceTypes.has(instanceType)) {
      continue;
    }
    const onDemandHourly = parseNumber(pricingRow.priceOnDemand);
    if (!(onDemandHourly > 0)) {
      continue;
    }
    const onDemandMonthly = onDemandHourly * HOURS_PER_MONTH;
    const oneYearMonthly = computeMonthlyTier(
      pricingRow,
      "reservedAllUpfront1yr",
      "reservedPartialUpfront1yr"
    );
    const threeYearMonthly = computeMonthlyTier(
      pricingRow,
      "reservedAllUpfront3yr",
      "reservedPartialUpfront3yr"
    );
    if (!(oneYearMonthly > 0 && threeYearMonthly > 0)) {
      continue;
    }
    byInstanceType[instanceType] = {
      onDemandMonthly: Number(onDemandMonthly.toFixed(6)),
      oneYearMonthly: Number(oneYearMonthly.toFixed(6)),
      threeYearMonthly: Number(threeYearMonthly.toFixed(6))
    };
  }
  return byInstanceType;
}

async function refresh() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDir, "..");
  const dataRoot = path.join(repoRoot, "static", "rosa", "hcp-cost-calculator", "data");
  const pricingDir = path.join(dataRoot, "pricing");
  const regionsPath = path.join(dataRoot, "regions.json");
  const catalogPath = path.join(dataRoot, "instance-catalog.json");
  const manifestPath = path.join(dataRoot, "snapshot-manifest.json");

  await mkdir(pricingDir, { recursive: true });

  const [rosaRegions, rosaInstanceTypes, sourceRegions] = await Promise.all([
    runRosaJsonCommand(["list", "regions", "-o", "json"], "rosa list regions -o json"),
    runRosaJsonCommand(["list", "instance-types", "-o", "json"], "rosa list instance-types -o json"),
    fetchJson(WGARCIA_REGIONS_URL)
  ]);

  const supportedRegionCodes = new Set(
    rosaRegions
      .filter((region) => region?.enabled !== false)
      .filter((region) => region?.supports_hypershift !== false)
      .map((region) => region?.id)
      .filter((regionCode) => typeof regionCode === "string" && regionCode.length > 0)
  );
  assertCondition(
    supportedRegionCodes.size > 0,
    "ROSA CLI returned no supported HCP regions. Check `rosa list regions -o json`."
  );
  const supportedInstanceTypesFromRosa = new Set(
    rosaInstanceTypes
      .map((item) => `${item?.id ?? ""}`.toLowerCase().trim())
      .filter((instanceType) => instanceType.length > 0)
  );
  assertCondition(
    supportedInstanceTypesFromRosa.size > 0,
    "ROSA CLI returned no instance types. Check `rosa list instance-types -o json`."
  );
  const rosaInstanceTypeById = new Map(
    rosaInstanceTypes
      .filter((item) => typeof item?.id === "string" && item.id.length > 0)
      .map((item) => [item.id.toLowerCase(), item])
  );

  const sourceRegionsByCode = new Map(
    sourceRegions
      .filter((region) => typeof region?.code === "string")
      .map((region) => [region.code, region])
  );

  const regionCodesFromRosa = Array.from(supportedRegionCodes).sort(regionSort);
  const includedRegions = [];
  const missingRegionPricing = [];
  const pricingByRegion = {};

  for (const regionCode of regionCodesFromRosa) {
    if (!sourceRegionsByCode.has(regionCode)) {
      missingRegionPricing.push(regionCode);
      continue;
    }

    const pricingUrl = `https://rosa.wigarcia.com/prices/${regionCode}-ec2.json`;
    let pricingRows;
    try {
      pricingRows = await fetchJson(pricingUrl);
    } catch {
      missingRegionPricing.push(regionCode);
      continue;
    }

    assertCondition(
      Array.isArray(pricingRows),
      `Expected pricing feed to return a list for region ${regionCode}.`
    );

    const byInstanceType = buildPricingByInstanceType(pricingRows, supportedInstanceTypesFromRosa);
    if (Object.keys(byInstanceType).length === 0) {
      missingRegionPricing.push(regionCode);
      continue;
    }

    includedRegions.push(regionCode);
    pricingByRegion[regionCode] = { region: regionCode, byInstanceType };
  }

  assertCondition(includedRegions.length > 0, "No regions with pricing were collected.");

  const supportedByInstance = new Map();
  for (const regionCode of includedRegions) {
    for (const instanceType of Object.keys(pricingByRegion[regionCode].byInstanceType)) {
      if (!supportedByInstance.has(instanceType)) {
        supportedByInstance.set(instanceType, new Set());
      }
      supportedByInstance.get(instanceType).add(regionCode);
    }
  }

  const instances = Array.from(supportedByInstance.entries())
    .map(([instanceType, supportedRegions]) => {
      const catalogEntry = rosaInstanceTypeById.get(instanceType);
      if (!catalogEntry) {
        return null;
      }
      const vcpus = Number(catalogEntry?.cpu?.value ?? 0);
      const memoryGiB = toGiBFromBytes(catalogEntry?.memory?.value);
      if (!(vcpus > 0 && memoryGiB > 0)) {
        return null;
      }
      return {
        type: instanceType,
        architecture: catalogEntry?.architecture ?? "unknown",
        vcpus,
        memory_gib: memoryGiB,
        supported_regions: Array.from(supportedRegions).sort(regionSort)
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.type.localeCompare(b.type));

  assertCondition(instances.length > 0, "No instances were collected after filtering.");

  const generatedAt = process.env.HCP_PRICING_GENERATED_AT ?? new Date().toISOString();

  const regionsPayload = {
    version: 1,
    generated_at: generatedAt,
    source: {
      supported_regions_and_instances: RH_DOC_SERVICE_DEFINITION_URL
    },
    regions: includedRegions.map((regionCode) => {
      const sourceRegion = sourceRegionsByCode.get(regionCode);
      const zones = Array.isArray(sourceRegion?.zones)
        ? sourceRegion.zones.filter((zone) => typeof zone === "string" && zone.length > 0)
        : [];
      assertCondition(zones.length > 0, `Region ${regionCode} is missing zone data in source feed.`);
      return { code: regionCode, zones };
    })
  };

  const catalogPayload = {
    version: 1,
    generated_at: generatedAt,
    source: {
      supported_regions_and_instances: RH_DOC_SERVICE_DEFINITION_URL
    },
    instances
  };

  const manifestPayload = {
    version: 1,
    generated_at: generatedAt,
    runtime_base_path: "/experts/rosa/hcp-cost-calculator/data",
    sources: {
      supported_regions_and_instances: RH_DOC_SERVICE_DEFINITION_URL,
      rosa_regions_command: "rosa list regions -o json",
      rosa_instance_types_command: "rosa list instance-types -o json",
      regions_feed: WGARCIA_REGIONS_URL,
      pricing_feed_template: "https://rosa.wigarcia.com/prices/{region}-ec2.json"
    },
    regions: includedRegions,
    files: {
      regions: "regions.json",
      instance_catalog: "instance-catalog.json",
      pricing: Object.fromEntries(includedRegions.map((regionCode) => [regionCode, `pricing/${regionCode}.json`]))
    }
  };

  await rm(pricingDir, { recursive: true, force: true });
  await mkdir(pricingDir, { recursive: true });

  await writeJson(regionsPath, regionsPayload);
  await writeJson(catalogPath, catalogPayload);

  for (const regionCode of includedRegions) {
    await writeJson(path.join(pricingDir, `${regionCode}.json`), {
      version: 1,
      generated_at: generatedAt,
      ...pricingByRegion[regionCode]
    });
  }

  await writeJson(manifestPath, manifestPayload);

  console.log(`Collected ${includedRegions.length} region(s) from ROSA CLI + available pricing feed.`);
  console.log(`Collected ${instances.length} supported instance type(s) from ROSA CLI.`);
  if (missingRegionPricing.length > 0) {
    console.log(
      `Skipped ${missingRegionPricing.length} supported region(s) missing source pricing feed: ${missingRegionPricing.join(
        ", "
      )}`
    );
  }
  console.log(`Updated snapshot files with generated_at=${generatedAt}.`);
}

refresh().catch((error) => {
  console.error(`HCP pricing refresh failed: ${error.message}`);
  process.exitCode = 1;
});
