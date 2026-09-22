---
date: '2026-09-18'
title: Forwarding and Monitoring ROSA HCP Control Plane Audit Logs with Filebeat
tags: ["ROSA HCP", "Observability"]
authors:
  - Kumudu Herath
  - Michael McNeill
  - Kevin Collins
validated_version: "4.20"
---

In ROSA Hosted Control Planes (HCP), the Kubernetes API server, authentication server, and OAuth server run on Red Hat-managed infrastructure. Because there are no customer-accessible control plane nodes, the standard approach of reading audit logs directly from `/var/log/kube-apiserver/audit.log` does not apply. Instead, Red Hat's built-in log forwarder continuously ships control plane audit logs to an S3 bucket that you own and control.

This guide walks through the complete pipeline: configuring ROSA HCP to forward control plane audit logs to S3, setting up an Amazon SQS notification queue, deploying a Filebeat pod inside the cluster using IAM Roles for Service Accounts (IRSA) to receive and parse those logs, and validating that structured audit events — including `who`, `what`, `when`, and `which resource` — are correctly extracted. The same pipeline feeds Logstash, Elasticsearch, Splunk, or any other destination that Filebeat supports.

## Use Case

Control plane audit logs record every API call made to the Kubernetes API server. This includes:

- **Who** made each request (`user.username`, e.g., `developer`, `system:admin`, or a service account)
- **What** they did (`verb`: `create`, `delete`, `update`, `patch`, `get`, `list`, `watch`)
- **Which resource** was targeted (`objectRef.resource`, `objectRef.name`, `objectRef.namespace`)
- **When** it happened (`requestReceivedTimestamp`, `stageTimestamp`)
- **What was the outcome** (`responseStatus.code`: `200`, `201`, `403`, `409`)

This data is the primary source of truth for compliance auditing (PCI-DSS, HIPAA, SOC 2), incident investigation, and anomaly detection. For example, after running through this guide you will be able to answer questions like:

- Who deployed or deleted workloads in namespace `demo-kumudu`?
- Which service account patched a deployment's replica count?
- Were there any `403 Forbidden` responses that might indicate privilege escalation attempts?

## S3 Log Format

Before configuring ingestion, it is important to understand the format produced by ROSA's log forwarder:

| Property | Value |
|---|---|
| **S3 key pattern** | `<prefix>/ocm-production-<cluster-id>-<cluster-name>/kube-apiserver/<pod-name>/<timestamp>-<uuid>.json.gz` |
| **Content-Type** | `binary/octet-stream` (not `application/json`) |
| **Compression** | Single gzip — detected automatically by magic header, not by file extension or Content-Type |
| **Content structure** | Top-level JSON array `[{…}, {…}]` — NOT newline-delimited JSON |
| **Each array element** | Wrapper object with fields: `application`, `container_name`, `message`, `kubernetes`, `timestamp` |
| **`message` field** | JSON string containing one complete Kubernetes audit event (`audit.k8s.io/v1`) |

The two-layer structure means parsing requires two `decode_json_fields` passes — one to unwrap the array element, and a second to decode the nested audit event inside `message`. This is covered in the Filebeat configuration section below.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with permissions to create S3 buckets, SQS queues, and IAM roles
* [ROSA CLI](https://console.redhat.com/openshift/downloads) v1.2.64 or later, logged in (`rosa login`)
* [OpenShift CLI (`oc`)](https://console.redhat.com/openshift/downloads), logged in to the target cluster as a cluster administrator
* A ROSA HCP cluster in **Ready** state — verify with `rosa describe cluster -c <cluster-name>`
* Filebeat 8.9.0 or later — this guide uses 8.15.0 in a container image; the `expand_event_list_from_field: ".[]"` option for top-level JSON arrays was added in 8.9.0

## Set Environment Variables

Set these once and reuse them throughout the guide.

```bash
export CLUSTER_NAME="my-hcp-cluster"
export CLUSTER_REGION="us-west-2"            # region where the ROSA HCP cluster runs
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="${CLUSTER_NAME}-audit-logs"
export SQS_QUEUE_NAME="${CLUSTER_NAME}-audit-s3-events"
export SQS_URL="https://sqs.${CLUSTER_REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/${SQS_QUEUE_NAME}"
export IAM_ROLE_NAME="${CLUSTER_NAME}-filebeat-s3-reader"
export LOG_PREFIX="${CLUSTER_NAME}"
export FILEBEAT_NAMESPACE="rosa-logging"
export FILEBEAT_SA="filebeat"
```
## Forward Control Plane Logs to S3
Create ROSA HCP cluster [control plane logs forwarding](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/logging/rosa-forwarding-control-plane-logs) to an [S3 bucket](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/logging/rosa-forwarding-control-plane-logs#rosa-set-up-s3-bucket_rosa-configuring-the-log-forwarder). Update the above environment variables `LOG_PREFIX` and `BUCKET_NAME` accordingly.

{{% alert state="warning" %}}
The S3 bucket **must be in the same AWS region as the ROSA HCP cluster**. ROSA's OCM API validates bucket accessibility by attempting to reach the bucket from the cluster's region. A bucket in a different region fails the pre-flight check with `Failed to reach bucket`, even if the bucket exists and the policy is correct.
{{% /alert %}}


## Verify Logs Are Flowing to S3

Wait 60 to 90 seconds, then list objects in the bucket:

```bash
aws s3 ls "s3://${BUCKET_NAME}/${LOG_PREFIX}/" \
  --region "${CLUSTER_REGION}" \
  --recursive | head -10
```

Expected output:

```
2026-09-18 21:54:00    9318  my-hcp-cluster/ocm-production-.../kube-apiserver/kube-apiserver-796bd67c6d-ctfzc/20260918-215358-19d21192.json.gz
2026-09-18 21:54:08    2709  my-hcp-cluster/ocm-production-.../kube-apiserver/kube-apiserver-796bd67c6d-ctfzc/20260918-215406-3e288b6d.json.gz
2026-09-18 21:54:22  109962  my-hcp-cluster/ocm-production-.../kube-apiserver/kube-apiserver-796bd67c6d-ctfzc/20260918-215421-c07f30fb.json.gz
```

Files above approximately 10 KB contain audit events. Very small files (under 3 KB) are application log lines from the kube-apiserver container itself, not audit events. Both types are handled correctly by the Filebeat configuration in this guide.

Inspect the format of a large file to confirm the two-level JSON structure:

```bash
SAMPLE_KEY=$(aws s3 ls "s3://${BUCKET_NAME}/${LOG_PREFIX}/" \
  --region "${CLUSTER_REGION}" --recursive 2>/dev/null \
  | awk '$3 > 50000 && /kube-apiserver/ {print $4}' | head -1)

aws s3 cp "s3://${BUCKET_NAME}/${SAMPLE_KEY}" /tmp/sample-audit.json.gz \
  --region "${CLUSTER_REGION}"

gzip -dc /tmp/sample-audit.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('Array length:', len(data))
elem = data[0]
print('Element keys:', list(elem.keys()))
inner = json.loads(elem['message'])
print('Inner message keys:', list(inner.keys()))
print('auditID:', inner.get('auditID'))
print('verb:', inner.get('verb'))
"
```

Expected output:

```
Array length: 1145
Element keys: ['application', 'container_name', 'file', 'ingest_timestamp', 'kubernetes', 'mc_cluster_id', 'message', 'metadata', 'namespace', 'pod_name', 'source_type', 'stream', 'timestamp']
Inner message keys: ['kind', 'apiVersion', 'level', 'auditID', 'stage', 'requestURI', 'verb', 'user', 'sourceIPs', 'userAgent', 'objectRef', 'responseStatus', 'requestReceivedTimestamp', 'stageTimestamp', 'annotations']
auditID: 57e686f5-e226-4f54-bae7-81e5242b7996
verb: create
```

## Create the SQS Queue

Filebeat uses SQS event notifications to know when new objects arrive in S3. Create the queue in the same region as the bucket.

```bash
aws sqs create-queue \
  --queue-name "${SQS_QUEUE_NAME}" \
  --region "${CLUSTER_REGION}" \
  --attributes '{"VisibilityTimeout":"300","MessageRetentionPeriod":"86400"}'
```

Get the queue ARN and apply a policy that permits S3 to send messages to it:

```bash
SQS_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${SQS_URL}" \
  --attribute-names QueueArn \
  --region "${CLUSTER_REGION}" \
  --query 'Attributes.QueueArn' --output text)

aws sqs set-queue-attributes \
  --queue-url "${SQS_URL}" \
  --region "${CLUSTER_REGION}" \
  --attributes "Policy=$(cat <<EOF | tr -d '\n'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowS3SendMessage",
    "Effect": "Allow",
    "Principal": { "Service": "s3.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "${SQS_ARN}",
    "Condition": { "ArnLike": { "aws:SourceArn": "arn:aws:s3:::${BUCKET_NAME}" } }
  }]
}
EOF
)"
```

Configure S3 event notifications to publish to the queue when new objects appear under the log prefix:

```bash
aws s3api put-bucket-notification-configuration \
  --bucket "${BUCKET_NAME}" \
  --region "${CLUSTER_REGION}" \
  --notification-configuration "{
    \"QueueConfigurations\": [{
      \"Id\": \"audit-log-events\",
      \"QueueArn\": \"${SQS_ARN}\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {
        \"Key\": {
          \"FilterRules\": [{ \"Name\": \"prefix\", \"Value\": \"${LOG_PREFIX}/\" }]
        }
      }
    }]
  }"
```

Verify the notification configuration:

```bash
aws s3api get-bucket-notification-configuration \
  --bucket "${BUCKET_NAME}" \
  --region "${CLUSTER_REGION}"
```

Expected output:

```json
{
    "QueueConfigurations": [
        {
            "Id": "audit-log-events",
            "QueueArn": "arn:aws:sqs:us-west-2:660250927410:my-hcp-cluster-audit-s3-events",
            "Events": [ "s3:ObjectCreated:*" ],
            "Filter": {
                "Key": {
                    "FilterRules": [{ "Name": "Prefix", "Value": "my-hcp-cluster/" }]
                }
            }
        }
    ]
}
```

## Create the Filebeat IAM Role

Filebeat runs as a pod in the cluster and uses IRSA (IAM Roles for Service Accounts) to authenticate to AWS without static credentials. The IAM role trust policy uses the cluster's OIDC provider so that only the `filebeat` service account in the `rosa-logging` namespace can assume it.

Get the cluster's OIDC issuer:

```bash
OIDC_PROVIDER=$(rosa describe cluster -c "${CLUSTER_NAME}" --output json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['aws']['sts']['oidc_endpoint_url'].replace('https://',''))")

echo "OIDC provider: ${OIDC_PROVIDER}"
```

Expected output:

```
OIDC provider: oidc.op1.openshiftapps.com/2stioo4np7rlnl6gcefe3grd10reftcd
```

Create the IAM role with a trust policy scoped to the `filebeat` service account:

```bash
aws iam create-role \
  --role-name "${IAM_ROLE_NAME}" \
  --description "IRSA role for Filebeat pod to read from S3 and SQS (${CLUSTER_NAME})" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:${FILEBEAT_NAMESPACE}:${FILEBEAT_SA}\",
          \"${OIDC_PROVIDER}:aud\": \"openshift\"
        }
      }
    }]
  }"
```

Attach an inline policy granting Filebeat read access to the S3 bucket and SQS queue:

```bash
aws iam put-role-policy \
  --role-name "${IAM_ROLE_NAME}" \
  --policy-name filebeat-s3-sqs-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"S3ReadAuditLogs\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:ListBucket\", \"s3:GetBucketLocation\"],
        \"Resource\": [
          \"arn:aws:s3:::${BUCKET_NAME}\",
          \"arn:aws:s3:::${BUCKET_NAME}/*\"
        ]
      },
      {
        \"Sid\": \"SQSReceiveMessages\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"sqs:ReceiveMessage\",
          \"sqs:DeleteMessage\",
          \"sqs:GetQueueAttributes\",
          \"sqs:GetQueueUrl\"
        ],
        \"Resource\": \"${SQS_ARN}\"
      }
    ]
  }"

FILEBEAT_ROLE_ARN=$(aws iam get-role --role-name "${IAM_ROLE_NAME}" \
  --query 'Role.Arn' --output text)
echo "Filebeat role ARN: ${FILEBEAT_ROLE_ARN}"
```

Expected output:

```
Filebeat role ARN: arn:aws:iam::660250927410:role/my-hcp-cluster-filebeat-s3-reader
```

## Deploy Filebeat to the Cluster

Create the `rosa-logging` namespace, then apply all resources from a single manifest.

```bash
oc create namespace "${FILEBEAT_NAMESPACE}"
```

Create the manifest. The deployment mounts the service account's projected token at the path expected by the AWS SDK for web identity authentication.

```bash
cat > filebeat-deployment.yaml <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${FILEBEAT_SA}
  namespace: ${FILEBEAT_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${FILEBEAT_ROLE_ARN}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: filebeat-config
  namespace: ${FILEBEAT_NAMESPACE}
data:
  filebeat.yml: |
    filebeat.inputs:
      - type: aws-s3
        queue_url: "${SQS_URL}"

        # CRITICAL: content_type and expand_event_list_from_field must be placed
        # inside the file_selectors entry, not at the input level.
        # When file_selectors is present, input-level settings are ignored for
        # selector-matched files (Filebeat 8.x behavior).
        file_selectors:
          - regex: "/kube-apiserver/"
            content_type: application/json
            expand_event_list_from_field: ".[]"

        processors:
          # Level 1: decode the wrapper element from the JSON array.
          # Produces audit.application, audit.container_name, audit.kubernetes,
          # and audit.message (which contains the inner audit event JSON string).
          - decode_json_fields:
              fields: ["message"]
              target: "audit"
              overwrite_keys: true
              add_error_key: true

          # Level 2: decode the inner audit event from audit.message.
          # Produces audit.auditID, audit.verb, audit.user, audit.objectRef, etc.
          - decode_json_fields:
              fields: ["audit.message"]
              target: "audit"
              overwrite_keys: true
              add_error_key: true

          # Drop non-audit entries (konnectivity-server, oauth app logs, etc.)
          # Genuine audit events always have auditID; app log lines do not.
          - drop_event:
              when:
                not:
                  has_fields: ["audit.auditID"]

    output.logstash:
      hosts: ["logstash.your-namespace.svc.cluster.local:5044"]

    logging.level: info
    logging.to_stderr: true

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filebeat-s3
  namespace: ${FILEBEAT_NAMESPACE}
  labels:
    app: filebeat-s3
spec:
  replicas: 1
  selector:
    matchLabels:
      app: filebeat-s3
  template:
    metadata:
      labels:
        app: filebeat-s3
    spec:
      serviceAccountName: ${FILEBEAT_SA}
      containers:
        - name: filebeat
          image: docker.elastic.co/beats/filebeat:8.15.0
          args: ["-c", "/etc/filebeat/filebeat.yml", "-e"]
          env:
            - name: AWS_ROLE_ARN
              value: "${FILEBEAT_ROLE_ARN}"
            - name: AWS_WEB_IDENTITY_TOKEN_FILE
              value: "/var/run/secrets/openshift/serviceaccount/token"
            - name: AWS_DEFAULT_REGION
              value: "${CLUSTER_REGION}"
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          volumeMounts:
            - name: filebeat-config
              mountPath: /etc/filebeat
              readOnly: true
            - name: data
              mountPath: /usr/share/filebeat/data
            - name: openshift-token
              mountPath: /var/run/secrets/openshift/serviceaccount
              readOnly: true
      volumes:
        - name: filebeat-config
          configMap:
            name: filebeat-config
        - name: data
          emptyDir: {}
        - name: openshift-token
          projected:
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 86400
                  audience: openshift
EOF
```

Apply the manifest:

```bash
oc apply -f filebeat-deployment.yaml
```

Expected output:

```
serviceaccount/filebeat created
configmap/filebeat-config created
deployment.apps/filebeat-s3 created
```

Verify the pod is running:

```bash
oc get pods -n "${FILEBEAT_NAMESPACE}"
```

Expected output:

```
NAME                           READY   STATUS    RESTARTS   AGE
filebeat-s3-75b58ff747-4rbgj   1/1     Running   0          30s
```

## Validate Structured Audit Events

Check the Filebeat pod logs. After a few seconds, you should see it connect to the SQS queue and begin processing S3 objects.

```bash
oc logs -n "${FILEBEAT_NAMESPACE}" deployment/filebeat-s3 2>&1 | \
  grep -E "(aws-s3|SQS|region|error|warn)" | head -10
```

Expected output:

```json
{"log.level":"info","message":"Input 'aws-s3' starting","id":"2F9BD9B1F7F9B9C1"}
{"log.level":"info","message":"AWS region is set to us-west-2.","queue_url":"https://sqs.us-west-2..."}
{"log.level":"info","message":"AWS SQS visibility_timeout is set to 5m0s."}
```

After 30 seconds, check the pipeline metrics. Look for `added` and `acked` values that match in large batches (hundreds per file):

```bash
oc logs -n "${FILEBEAT_NAMESPACE}" deployment/filebeat-s3 2>&1 | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        m = d.get('monitoring', {}).get('metrics', {})
        fb = m.get('filebeat', {}).get('events', {})
        out = m.get('libbeat', {}).get('output', {}).get('events', {})
        pipe = m.get('libbeat', {}).get('pipeline', {}).get('events', {})
        if fb.get('added', 0) > 0:
            print(f'added={fb[\"added\"]}, filtered={pipe.get(\"filtered\",0)}, acked={out.get(\"acked\",0)}')
    except: pass
"
```

Expected output showing hundreds of events per batch (one large kube-apiserver file typically contains 500 to 1500 audit events):

```
added=2039, filtered=598, acked=1441
added=1145, filtered=0,   acked=1145
```

{{% alert state="info" %}}
`filtered` counts events dropped by the `drop_event` processor — these are non-audit application log lines from the kube-apiserver container. `acked` counts genuine audit events forwarded to Logstash or Elasticsearch.
{{% /alert %}}

## Querying Audit Events

Once events reach Elasticsearch or Logstash, the following fields are available for filtering and alerting.

### Key Fields Reference

| Field | Description | Example |
|---|---|---|
| `audit.auditID` | Unique ID per API request | `57e686f5-e226-4f54-bae7-81e5242b7996` |
| `audit.verb` | HTTP verb mapped to K8s action | `create`, `delete`, `update`, `patch`, `get`, `list` |
| `audit.user.username` | Identity making the request | `developer`, `system:admin`, `system:serviceaccount:kube-system:deployment-controller` |
| `audit.user.groups` | Groups the identity belongs to | `["system:authenticated", "system:masters"]` |
| `audit.objectRef.namespace` | Target namespace | `demo-kumudu` |
| `audit.objectRef.resource` | Resource type | `deployments`, `pods`, `secrets`, `rolebindings` |
| `audit.objectRef.name` | Resource name | `my-app-deployment` |
| `audit.objectRef.subresource` | Sub-resource | `scale`, `status`, `log` |
| `audit.responseStatus.code` | HTTP response code | `200`, `201`, `403`, `409` |
| `audit.requestReceivedTimestamp` | When the API server received the request | `2026-09-18T21:06:27.000000Z` |
| `audit.stage` | Audit stage | `ResponseComplete` (use this for completed actions) |
| `audit.requestURI` | Full API path | `/apis/apps/v1/namespaces/demo-kumudu/deployments` |

### Example Queries

**Find all write operations by a specific user in a namespace:**

```
audit.user.username: "developer"
AND audit.objectRef.namespace: "demo-kumudu"
AND audit.verb: (create OR delete OR update OR patch)
AND audit.stage: "ResponseComplete"
```

**Detect secret access events:**

```
audit.objectRef.resource: "secrets"
AND audit.verb: (get OR list OR watch)
AND audit.stage: "ResponseComplete"
```

**Find privilege escalation attempts (403 responses):**

```
audit.responseStatus.code: 403
AND audit.stage: "ResponseComplete"
```

**Track deployment scaling events:**

```
audit.objectRef.resource: "deployments"
AND audit.objectRef.subresource: "scale"
AND audit.verb: "patch"
AND audit.stage: "ResponseComplete"
```

## Understanding the Audit Trail

To show what a complete audit trail looks like, here is an example from a live ROSA HCP cluster. A developer created a new project, deployed a Java Spring Boot application from source, deleted a pod, and scaled the deployment. The audit log captured the full sequence:

```
TIME (UTC)            VERB    RESOURCE                    NAME                                         USER
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
21:05:55              create  rolebindings                admin                                        system:admin
21:06:27              create  imagestreams                                                             developer
21:06:27              create  buildconfigs                devfile-sample-java-springboot-basic-git     developer
21:06:27              create  deployments                 devfile-sample-java-springboot-basic-git     developer
21:06:27              create  services                    devfile-sample-java-springboot-basic-git     developer
21:06:27              create  routes                                                                   developer
21:08:02              update  deployments                 devfile-sample-java-springboot-basic-git     system:serviceaccount:openshift-infra:image-trigger-controller
21:09:12              delete  pods                        devfile-sample-java-springboot-basic-git-... system:node:ip-10-10-36-210.us-west-2.compute.internal
21:35:00              delete  pods                        devfile-sample-java-springboot-basic-git-... developer
21:35:35              patch   deployments/scale           devfile-sample-java-springboot-basic-git     developer
```

Each user action is immediately followed by a cascade of system controller actions (scheduler, replicaset-controller, endpoint-controller) that are also fully recorded. This gives security teams a complete causal chain from the initial human action to every side effect.

{{% alert state="info" %}}
The `system:node:…` identity deleting a pod at 21:09:12 represents the node cleaning up a completed build pod — expected behavior. A similar `delete pods` event by `system:admin` or an unexpected service account during off-hours would be a candidate for an alert.
{{% /alert %}}

## Common Configuration Pitfalls

These are the three most frequent configuration errors when ingesting ROSA HCP audit logs with Filebeat.

### Pitfall 1: `content_type` and `expand_event_list_from_field` at the Wrong Level

When `file_selectors` is present, Filebeat applies only the selector's own settings to matching files. Input-level `content_type` and `expand_event_list_from_field` are **silently ignored** for selector-matched files.

```yaml
# WRONG — expand_event_list_from_field at the input level is silently ignored
# when file_selectors is also present. The entire file is treated as one event.
filebeat.inputs:
  - type: aws-s3
    queue_url: "..."
    content_type: application/json
    expand_event_list_from_field: ".[]"
    file_selectors:
      - regex: "/kube-apiserver/"

# CORRECT — both options must be inside the selector
filebeat.inputs:
  - type: aws-s3
    queue_url: "..."
    file_selectors:
      - regex: "/kube-apiserver/"
        content_type: application/json
        expand_event_list_from_field: ".[]"
```

The symptom of this mistake is a `message` field containing the entire raw JSON array as a string, and only one event emitted per S3 file instead of hundreds.

### Pitfall 2: Only One Level of JSON Decode

The ROSA log forwarder wraps each audit event in an outer metadata object. A single `decode_json_fields` pass decodes the outer wrapper but leaves `message` (the inner audit event) as an unparsed string under `audit.message`. `audit.auditID` is never populated, so `drop_event` removes every event.

```yaml
# WRONG — only one decode pass. audit.auditID is never set.
processors:
  - decode_json_fields:
      fields: ["message"]
      target: "audit"
      overwrite_keys: true

# CORRECT — two decode passes: outer wrapper then inner audit event
processors:
  - decode_json_fields:
      fields: ["message"]
      target: "audit"
      overwrite_keys: true
      add_error_key: true
  - decode_json_fields:
      fields: ["audit.message"]
      target: "audit"
      overwrite_keys: true
      add_error_key: true
  - drop_event:
      when:
        not:
          has_fields: ["audit.auditID"]
```

### Pitfall 3: `input` and `decompress` are Invalid `file_selectors` Fields

Only `regex`, `content_type`, and `expand_event_list_from_field` are valid inside `file_selectors`. Using `input` or `decompress` causes Filebeat to silently ignore those keys, leaving `content_type` unset and processing every file as `binary/octet-stream`.

```yaml
# WRONG — 'input' and 'decompress' are not valid file_selectors fields
file_selectors:
  - regex: '.*\.json\.gz$'
    input: "application/json"    # invalid — silently ignored
    decompress: true              # invalid — silently ignored
    expand_event_list_from_field: ".[]"

# CORRECT
file_selectors:
  - regex: '.*\.json\.gz$'
    content_type: application/json
    expand_event_list_from_field: ".[]"
```

{{% alert state="warning" %}}
Gzip decompression is handled automatically by Filebeat via magic header detection (`\x1f\x8b`). The `content_type` setting controls JSON parsing, not decompression. You do not need — and cannot use — a `decompress` option.
{{% /alert %}}

## Production Considerations

The manifest in this guide uses `output.console` and `emptyDir` storage — both are suitable for validation but require changes before running in production.

### Output destination

Replace `output.console` with `output.logstash` or `output.elasticsearch` in the ConfigMap.

**Logstash** (recommended when you need pipeline routing, enrichment, or fan-out to multiple destinations):

```yaml
output.logstash:
  hosts: ["logstash.your-namespace.svc.cluster.local:5044"]
```

**Elasticsearch directly** (simpler when you don't need Logstash transformation):

```yaml
output.elasticsearch:
  hosts: ["https://your-elasticsearch:9200"]
  index: "rosa-control-plane-audit-%{+yyyy.MM.dd}"
  username: "${ELASTICSEARCH_USERNAME}"
  password: "${ELASTICSEARCH_PASSWORD}"
```

### Keep replicas at 1

Run exactly one Filebeat replica. The SQS visibility timeout (`VisibilityTimeout`) prevents two consumers from processing the same message simultaneously, but if a second replica picks up a message before the first acknowledges it, both will download and parse the same S3 object. There is no deduplication downstream that removes identical audit events, so multiple replicas produce duplicate events in Elasticsearch.

If you need higher throughput, increase the `number_of_workers` setting inside the `aws-s3` input instead:

```yaml
filebeat.inputs:
  - type: aws-s3
    number_of_workers: 4   # parallel S3 download goroutines within one pod
    queue_url: "${SQS_URL}"
    ...
```

### Persistent volume for Filebeat state

The `data` volume in the manifest uses `emptyDir`, which is wiped on every pod restart. Filebeat stores its SQS position and per-file cursor in `/usr/share/filebeat/data`. Without persistence, a pod restart causes Filebeat to re-download and re-process every unacknowledged SQS message.

Replace the `emptyDir` volume with a `PersistentVolumeClaim`:

```yaml
# Add to your manifest
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: filebeat-data
  namespace: rosa-logging
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

Then update the Deployment volume entry:

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: filebeat-data   # replaces emptyDir: {}
```

### SQS dead-letter queue

Configure a dead-letter queue (DLQ) on the SQS queue so that S3 objects Filebeat cannot parse do not cycle indefinitely. Without a DLQ, a corrupt or unexpected file format causes the message to become visible again after `VisibilityTimeout` expires and Filebeat retries it forever.

```bash
# Create the DLQ
DLQ_ARN=$(aws sqs create-queue \
  --queue-name "${SQS_QUEUE_NAME}-dlq" \
  --region "${CLUSTER_REGION}" \
  --query QueueUrl --output text | xargs -I{} \
  aws sqs get-queue-attributes --queue-url {} \
    --attribute-names QueueArn \
    --query Attributes.QueueArn --output text)

# Attach DLQ to the main queue (retry 3 times before routing to DLQ)
aws sqs set-queue-attributes \
  --queue-url "${SQS_URL}" \
  --region "${CLUSTER_REGION}" \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"
```

{{% alert state="info" %}}
**Priority order for production readiness:** The single most impactful change is replacing `emptyDir` with a PVC. Without it, every pod restart risks re-processing audit events that were already sent to Elasticsearch. Output destination and DLQ are important but secondary.
{{% /alert %}}


## Cleanup

Remove the Filebeat deployment and namespace:

```bash
oc delete namespace "${FILEBEAT_NAMESPACE}"
```

Remove the HCP log forwarder:

```bash
FORWARDER_ID=$(rosa list log-forwarders -c "${CLUSTER_NAME}" -o json \
  | python3 -c "import json,sys; l=json.load(sys.stdin); print(l['items'][0]['id'])" 2>/dev/null)
rosa delete log-forwarder -c "${CLUSTER_NAME}" --id "${FORWARDER_ID}" -y
```

Remove AWS resources:

```bash
# Delete SQS queue
aws sqs delete-queue --queue-url "${SQS_URL}" --region "${CLUSTER_REGION}"

# Remove bucket notification
aws s3api put-bucket-notification-configuration \
  --bucket "${BUCKET_NAME}" \
  --notification-configuration '{}' \
  --region "${CLUSTER_REGION}"

# Empty and delete bucket
aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "${CLUSTER_REGION}"
aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${CLUSTER_REGION}"

# Delete Filebeat IRSA role
aws iam delete-role-policy --role-name "${IAM_ROLE_NAME}" --policy-name filebeat-s3-sqs-access
aws iam delete-role --role-name "${IAM_ROLE_NAME}"

# Delete customer log distribution role (if created)
aws iam delete-role-policy --role-name "${CUSTOMER_ROLE_NAME}" --policy-name kms-encrypt-access 2>/dev/null || true
aws iam delete-role --role-name "${CUSTOMER_ROLE_NAME}" 2>/dev/null || true
```

## Summary

| Component | Key Requirement | Why |
|---|---|---|
| **S3 bucket region** | Must match the ROSA HCP cluster region | ROSA's OCM API validates bucket accessibility from the cluster's region during log forwarder creation |
| **Customer log distribution role** | Optional; role name must include `CustomerLogDistribution` | Required only when the S3 bucket uses a KMS customer-managed key — the Red Hat central role has no access to your KMS keys, but a role in your account can bridge the gap |
| **`content_type` in `file_selectors`** | Must be inside the selector entry, not at input level | Input-level `content_type` is silently ignored when `file_selectors` is present |
| **`expand_event_list_from_field`** | Must be inside the selector entry, set to `.[]` | Filebeat 8.9.0+ only; required to split the top-level JSON array into individual events |
| **Two `decode_json_fields` passes** | First on `message → audit`, second on `audit.message → audit` | ROSA wraps each audit event in an outer metadata object; the audit event itself is a JSON string inside `message` |
| **`drop_event` on `audit.auditID`** | Filters out non-audit application log lines | Not all kube-apiserver container log files contain audit events; small files are often plain-text app logs |
| **IRSA via projected service account token** | `audience: openshift` token at `/var/run/secrets/openshift/serviceaccount/token` | ROSA HCP uses the OpenShift OIDC provider; the token audience must match the role's trust policy condition |
| **Gzip decompression** | Automatic, no configuration needed | Filebeat detects gzip by magic header; `Content-Type: binary/octet-stream` on S3 objects does not prevent decompression |

## Additional Resources

* [Red Hat documentation: Forwarding control plane logs on ROSA HCP](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/logging/rosa-forwarding-control-plane-logs)
* [Elastic documentation: Filebeat aws-s3 input](https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-aws-s3.html)
* [GitHub PR #35475: Add support for top-level JSON arrays in aws-s3 input](https://github.com/elastic/beats/pull/35475) — introduces `expand_event_list_from_field: ".[]"` (Filebeat 8.9.0)
* [AWS documentation: S3 Event Notifications with SQS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-how-to-event-types-and-destinations.html)
