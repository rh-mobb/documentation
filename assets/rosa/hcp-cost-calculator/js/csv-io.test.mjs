import assert from "node:assert/strict";
import test from "node:test";

import {
  CSV_FORMAT,
  CSV_FORMAT_VERSION,
  buildScenarioCsv,
  escapeCsvField,
  parseCsvLine,
  parseScenarioCsv
} from "./csv-io.mjs";

test("escapeCsvField quotes commas and embedded quotes", () => {
  assert.equal(escapeCsvField("plain"), "plain");
  assert.equal(escapeCsvField("a,b"), '"a,b"');
  assert.equal(escapeCsvField('say "hi"'), '"say ""hi"""');
});

test("parseCsvLine handles quoted commas", () => {
  assert.deepEqual(parseCsvLine('pool,"workers, primary",us-east-1'), [
    "pool",
    "workers, primary",
    "us-east-1"
  ]);
});

test("buildScenarioCsv and parseScenarioCsv round-trip sizing and discounting", () => {
  const csv = buildScenarioCsv({
    exportedAt: "2026-07-28T00:00:00.000Z",
    sizing: {
      clusterCount: 2,
      instances: [
        { instanceType: "m7i.xlarge", region: "us-east-1", count: 3 },
        { instanceType: "m7i.2xlarge", region: "eu-west-1", count: 6 }
      ]
    },
    discounting: {
      ec2SavingsPlanDiscountPercent: 12.5,
      rhContractTier: "oneYear",
      summaryPriceUnit: "monthly"
    },
    summary: {
      unit: "monthly",
      pools: [
        {
          cluster: "Cluster 1",
          pool: "workers",
          region: "us-east-1",
          instanceType: "m7i.xlarge",
          count: 3,
          vcpus: 12,
          memoryGiB: 48,
          ec2CostUsd: 100.5,
          nodeFeeUsd: 50.25,
          totalCostUsd: 150.75
        }
      ],
      clusterFee: {
        label: "HCP cluster fee (2 clusters)",
        count: "",
        vcpus: "",
        memoryGiB: "",
        ec2CostUsd: 0,
        nodeFeeUsd: 365,
        totalCostUsd: 365
      },
      total: {
        count: 3,
        vcpus: 12,
        memoryGiB: 48,
        ec2CostUsd: 100.5,
        nodeFeeUsd: 415.25,
        totalCostUsd: 515.75
      }
    }
  });

  assert.match(csv, new RegExp(`format,${CSV_FORMAT}`));
  assert.match(csv, new RegExp(`format_version,${CSV_FORMAT_VERSION}`));
  assert.match(csv, /SECTION,Cluster sizing/);
  assert.match(csv, /SECTION,Discounting/);
  assert.match(csv, /SECTION,Summary/);
  assert.match(csv, /m7i\.2xlarge,eu-west-1,6/);
  assert.match(csv, /pool,Cluster 1,workers,us-east-1,m7i\.xlarge,3,12,48,100\.5/);
  assert.match(csv, /cluster_fee,,HCP cluster fee \(2 clusters\)/);

  const parsed = parseScenarioCsv(csv);
  assert.deepEqual(parsed.sizing, {
    clusterCount: 2,
    instances: [
      { instanceType: "m7i.xlarge", region: "us-east-1", count: 3 },
      { instanceType: "m7i.2xlarge", region: "eu-west-1", count: 6 }
    ]
  });
  assert.deepEqual(parsed.discounting, {
    ec2SavingsPlanDiscountPercent: 12.5,
    rhContractTier: "oneYear",
    summaryPriceUnit: "monthly"
  });
});

test("parseScenarioCsv rejects unsupported format and missing sizing", () => {
  assert.throws(
    () =>
      parseScenarioCsv(`SECTION,Meta
format,other-tool
SECTION,Cluster sizing
cluster_count,1
instance_type,region,count
m7i.xlarge,us-east-1,3
`),
    /Unsupported CSV format/
  );

  assert.throws(() => parseScenarioCsv("SECTION,Discounting\nrh_contract_tier,onDemand\n"), /Cluster sizing/);
});
