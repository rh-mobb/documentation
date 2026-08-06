const DEFAULT_STALE_SNAPSHOT_DAYS = 30;
const DEFAULT_BURST_SPREAD_THRESHOLD = 30;
const DEFAULT_AZ_IMBALANCE_THRESHOLD = 3;

function normalizeInteger(value) {
  if (typeof value === "number") {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    return Number(value);
  }
  return Number.NaN;
}

function isInvalidNodeCount(value) {
  const normalized = normalizeInteger(value);
  return !Number.isInteger(normalized) || normalized < 0;
}

function getSnapshotAgeDays(input) {
  if (Number.isFinite(input.snapshotAgeDays)) {
    return Number(input.snapshotAgeDays);
  }
  if (!input.snapshotGeneratedAt) {
    return null;
  }
  const generatedAtMs = Date.parse(input.snapshotGeneratedAt);
  if (Number.isNaN(generatedAtMs)) {
    return null;
  }
  const ageMs = Date.now() - generatedAtMs;
  return ageMs / (1000 * 60 * 60 * 24);
}

export function validateEstimate(input) {
  const {
    estimate,
    allowedAzs = [],
    supportedTypes = [],
    staleSnapshotDaysThreshold = DEFAULT_STALE_SNAPSHOT_DAYS,
    burstSpreadThreshold = DEFAULT_BURST_SPREAD_THRESHOLD,
    enableAzImbalanceWarning = false,
    azImbalanceThreshold = DEFAULT_AZ_IMBALANCE_THRESHOLD
  } = input;

  const errors = [];
  const warnings = [];
  const allowedAzSet = new Set(allowedAzs);
  const supportedTypeSet = new Set(supportedTypes);

  for (const set of estimate?.sets ?? []) {
    if (!supportedTypeSet.has(set.instanceType)) {
      errors.push({
        code: "UNSUPPORTED_INSTANCE_TYPE",
        message: `Instance type ${set.instanceType} is not supported for this estimate.`,
        setId: set.id
      });
    }

    let minNodesMin = Number.POSITIVE_INFINITY;
    let minNodesMax = Number.NEGATIVE_INFINITY;

    for (const pool of set.pools ?? []) {
      if (!allowedAzSet.has(pool.az)) {
        errors.push({
          code: "INVALID_AZ_FOR_REGION",
          message: `Availability zone ${pool.az} is not valid for the selected region.`,
          setId: set.id,
          az: pool.az
        });
      }

      if (
        isInvalidNodeCount(pool.min) ||
        isInvalidNodeCount(pool.max)
      ) {
        errors.push({
          code: "INVALID_NODE_VALUE",
          message: `Node counts must be non-negative integers for ${pool.az}.`,
          setId: set.id,
          az: pool.az
        });
        continue;
      }

      const min = normalizeInteger(pool.min);
      const max = normalizeInteger(pool.max);
      minNodesMin = Math.min(minNodesMin, min);
      minNodesMax = Math.max(minNodesMax, min);

      if (!(min <= max)) {
        errors.push({
          code: "INVALID_NODE_ORDER",
          message: `Node counts must follow min <= max for ${pool.az}.`,
          setId: set.id,
          az: pool.az
        });
      }

      const burstSpread = max - min;
      if (burstSpread > burstSpreadThreshold) {
        warnings.push({
          code: "LARGE_BURST_SPREAD",
          message: `Burst spread is high in ${pool.az} for set ${set.name}.`,
          setId: set.id,
          az: pool.az,
          spread: burstSpread
        });
      }
    }

    if (
      enableAzImbalanceWarning &&
      Number.isFinite(minNodesMin) &&
      Number.isFinite(minNodesMax) &&
      minNodesMax - minNodesMin > azImbalanceThreshold
    ) {
      warnings.push({
        code: "AZ_IMBALANCE",
        message: `Minimum-node distribution is imbalanced for set ${set.name}.`,
        setId: set.id,
        spread: minNodesMax - minNodesMin
      });
    }
  }

  const snapshotAgeDays = getSnapshotAgeDays(input);
  if (snapshotAgeDays !== null && snapshotAgeDays > staleSnapshotDaysThreshold) {
    warnings.push({
      code: "STALE_SNAPSHOT",
      message: `Snapshot is ${Math.floor(snapshotAgeDays)} days old and may be stale.`,
      ageDays: Math.floor(snapshotAgeDays)
    });
  }

  return { errors, warnings };
}
