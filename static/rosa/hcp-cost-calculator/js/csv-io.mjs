export const CSV_FORMAT = "rosa-hcp-calculator";
export const CSV_FORMAT_VERSION = "1";

const VALID_RH_TIERS = new Set(["onDemand", "oneYear", "threeYear"]);
const VALID_UNITS = new Set(["hourly", "monthly", "yearly"]);

export function escapeCsvField(value) {
  const text = value == null ? "" : String(value);
  if (/[",\n\r]/.test(text)) {
    return `"${text.replaceAll('"', '""')}"`;
  }
  return text;
}

export function parseCsvLine(line) {
  const fields = [];
  let current = "";
  let inQuotes = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (inQuotes) {
      if (char === '"') {
        if (line[index + 1] === '"') {
          current += '"';
          index += 1;
        } else {
          inQuotes = false;
        }
      } else {
        current += char;
      }
      continue;
    }

    if (char === '"') {
      inQuotes = true;
      continue;
    }
    if (char === ",") {
      fields.push(current);
      current = "";
      continue;
    }
    current += char;
  }

  fields.push(current);
  return fields;
}

function normalizeSectionName(name) {
  return String(name ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function roundMoney(value) {
  if (!Number.isFinite(value)) {
    return "";
  }
  return String(Number(value.toFixed(6)));
}

/**
 * @param {object} input
 * @param {object} input.sizing
 * @param {number} input.sizing.clusterCount
 * @param {Array<{instanceType:string, region:string, count:number}>} input.sizing.instances
 * @param {object} input.discounting
 * @param {number} input.discounting.ec2SavingsPlanDiscountPercent
 * @param {string} input.discounting.rhContractTier
 * @param {string} input.discounting.summaryPriceUnit
 * @param {object} input.summary
 * @param {string} input.summary.unit
 * @param {Array<object>} input.summary.pools
 * @param {object} input.summary.clusterFee
 * @param {object} input.summary.total
 * @param {string} [input.exportedAt]
 */
export function buildScenarioCsv({ sizing, discounting, summary, exportedAt }) {
  const lines = [];
  const push = (fields) => lines.push(fields.map(escapeCsvField).join(","));

  push(["SECTION", "Meta"]);
  push(["format", CSV_FORMAT]);
  push(["format_version", CSV_FORMAT_VERSION]);
  push(["exported_at", exportedAt ?? new Date().toISOString()]);
  lines.push("");

  push(["SECTION", "Cluster sizing"]);
  push(["cluster_count", sizing?.clusterCount ?? 1]);
  push(["instance_type", "region", "count"]);
  for (const instance of sizing?.instances ?? []) {
    push([instance.instanceType, instance.region, instance.count]);
  }
  lines.push("");

  push(["SECTION", "Discounting"]);
  push(["ec2_savings_plan_discount_percent", discounting?.ec2SavingsPlanDiscountPercent ?? 0]);
  push(["rh_contract_tier", discounting?.rhContractTier ?? "onDemand"]);
  push(["summary_price_unit", discounting?.summaryPriceUnit ?? "yearly"]);
  lines.push("");

  push(["SECTION", "Summary"]);
  push(["unit", summary?.unit ?? discounting?.summaryPriceUnit ?? "yearly"]);
  push([
    "row_type",
    "pool",
    "region",
    "instance_type",
    "count",
    "ec2_cost_usd",
    "node_fee_usd",
    "total_cost_usd"
  ]);
  for (const pool of summary?.pools ?? []) {
    push([
      "pool",
      pool.pool,
      pool.region,
      pool.instanceType,
      pool.count ?? "",
      pool.ec2CostUsd == null ? "" : roundMoney(pool.ec2CostUsd),
      pool.nodeFeeUsd == null ? "" : roundMoney(pool.nodeFeeUsd),
      pool.totalCostUsd == null ? "" : roundMoney(pool.totalCostUsd)
    ]);
  }
  const clusterFee = summary?.clusterFee ?? {};
  push([
    "cluster_fee",
    clusterFee.label ?? "HCP cluster fee",
    "",
    "",
    clusterFee.count ?? "",
    roundMoney(clusterFee.ec2CostUsd ?? 0),
    roundMoney(clusterFee.nodeFeeUsd ?? 0),
    roundMoney(clusterFee.totalCostUsd ?? 0)
  ]);
  const total = summary?.total ?? {};
  push([
    "total",
    "Total",
    "",
    "",
    total.count ?? "",
    roundMoney(total.ec2CostUsd ?? 0),
    roundMoney(total.nodeFeeUsd ?? 0),
    roundMoney(total.totalCostUsd ?? 0)
  ]);
  lines.push("");

  return `${lines.join("\n")}\n`;
}

/**
 * Parse a scenario CSV. Summary section is accepted but ignored for import.
 * @param {string} text
 */
export function parseScenarioCsv(text) {
  if (typeof text !== "string" || !text.trim()) {
    throw new Error("CSV is empty.");
  }

  const lines = text.replace(/^\uFEFF/, "").split(/\r?\n/);
  const sections = new Map();
  let currentSection = null;

  for (const rawLine of lines) {
    if (!rawLine.trim()) {
      continue;
    }
    const fields = parseCsvLine(rawLine);
    if (normalizeSectionName(fields[0]) === "section") {
      currentSection = normalizeSectionName(fields[1]);
      if (!sections.has(currentSection)) {
        sections.set(currentSection, []);
      }
      continue;
    }
    if (!currentSection) {
      continue;
    }
    sections.get(currentSection).push(fields);
  }

  const metaRows = sections.get("meta") ?? [];
  const formatRow = metaRows.find((row) => row[0] === "format");
  if (formatRow && formatRow[1] !== CSV_FORMAT) {
    throw new Error(`Unsupported CSV format: ${formatRow[1]}`);
  }

  const sizingRows = sections.get("cluster sizing") ?? [];
  if (!sizingRows.length) {
    throw new Error('Missing "Cluster sizing" section.');
  }

  let clusterCount = 1;
  const instances = [];
  let inInstanceTable = false;

  for (const row of sizingRows) {
    const key = String(row[0] ?? "").trim();
    if (key === "cluster_count") {
      const parsed = Number.parseInt(row[1], 10);
      clusterCount = Number.isFinite(parsed) ? Math.max(1, parsed) : 1;
      inInstanceTable = false;
      continue;
    }
    if (key === "instance_type" && String(row[1] ?? "").trim() === "region") {
      inInstanceTable = true;
      continue;
    }
    if (!inInstanceTable) {
      continue;
    }
    const instanceType = String(row[0] ?? "").trim();
    const region = String(row[1] ?? "").trim();
    const count = Number.parseInt(row[2], 10);
    if (!instanceType || !region || !Number.isFinite(count) || count < 1) {
      continue;
    }
    instances.push({ instanceType, region, count });
  }

  if (!instances.length) {
    throw new Error("Cluster sizing section has no valid instance rows.");
  }

  const discountRows = sections.get("discounting") ?? [];
  const discountMap = new Map(
    discountRows
      .filter((row) => row[0])
      .map((row) => [String(row[0]).trim(), String(row[1] ?? "").trim()])
  );

  let ec2SavingsPlanDiscountPercent = Number.parseFloat(
    discountMap.get("ec2_savings_plan_discount_percent") ?? "0"
  );
  if (!Number.isFinite(ec2SavingsPlanDiscountPercent)) {
    ec2SavingsPlanDiscountPercent = 0;
  }
  ec2SavingsPlanDiscountPercent = Math.min(100, Math.max(0, ec2SavingsPlanDiscountPercent));

  let rhContractTier = discountMap.get("rh_contract_tier") ?? "onDemand";
  if (!VALID_RH_TIERS.has(rhContractTier)) {
    throw new Error(`Unsupported rh_contract_tier: ${rhContractTier}`);
  }

  let summaryPriceUnit = discountMap.get("summary_price_unit") ?? "yearly";
  if (!VALID_UNITS.has(summaryPriceUnit)) {
    throw new Error(`Unsupported summary_price_unit: ${summaryPriceUnit}`);
  }

  return {
    format: formatRow?.[1] ?? CSV_FORMAT,
    formatVersion:
      metaRows.find((row) => row[0] === "format_version")?.[1] ?? CSV_FORMAT_VERSION,
    sizing: {
      clusterCount,
      instances
    },
    discounting: {
      ec2SavingsPlanDiscountPercent,
      rhContractTier,
      summaryPriceUnit
    }
  };
}
