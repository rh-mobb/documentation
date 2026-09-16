---
date: '2026-09-16'
title: Configuring Custom Web Console and Downloads Routes on ROSA HCP
tags: ["ROSA HCP", "Terraform"]
authors:
  - Kumudu Herath
  - Kevin Collins
validated_version: "4.22"
---

ROSA HCP clusters expose the web console and CLI downloads page on automatically generated hostnames under the cluster's base domain, for example `console-openshift-console.apps.<cluster-domain>`. For organizations with strict enterprise domain policies, compliance requirements, or teams migrating from ROSA Classic clusters that already use custom routes, replacing these default hostnames with organization-controlled names and certificates is a common day-2 requirement.

This guide walks through deploying a public ROSA HCP cluster using the [`rh-mobb/terraform-rosa`](https://github.com/rh-mobb/terraform-rosa) Terraform module, obtaining a trusted TLS certificate via Let's Encrypt, and configuring custom DNS names for the **console** and **downloads** routes: the two component routes supported on HCP.

{{% alert state="warning" %}}
The OAuth server route (`oauth-openshift.apps.*`) cannot be customized on HCP. The OAuth server runs on the Red Hat-managed control plane, not on the customer cluster's ingress. Configuring identity providers such as Azure Entra ID or GitHub is a separate operation and is unaffected by this limitation.
{{% /alert %}}

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with permissions to create IAM roles and manage Route 53
* [ROSA CLI](https://console.redhat.com/openshift/downloads) v1.2.65 or later, logged in (`rosa login`)
* A Red Hat OCM service account `client_id` and `client_secret` — create one at [console.redhat.com/iam/service-accounts](https://console.redhat.com/iam/service-accounts)
* [Terraform](https://developer.hashicorp.com/terraform/downloads) v1.5.0 or later
* [OpenShift CLI (`oc`)](https://console.redhat.com/openshift/downloads)
* [certbot](https://certbot.eff.org/) with the `certbot-dns-route53` plugin installed via `pipx`
* A Route 53 public hosted zone for a domain you control
* ROSA HCP enabled on your AWS account; verify with `rosa verify quota --region us-west-2`

## Set Environment Variables

Set these once and reuse them throughout the guide.

```bash
export CLUSTER_NAME="custom-console-hcp"
export VERSION="4.22.11"
export REGION="us-west-2"
export BASE_DOMAIN="example.com"                       # your Route53 public hosted zone
export HOSTED_ZONE_ID="<your-route53-hosted-zone-id>"  # e.g. Z1DYYYPJNN8FT9
export CONSOLE_HOSTNAME="console.${BASE_DOMAIN}"
export DOWNLOADS_HOSTNAME="downloads.${BASE_DOMAIN}"
export EMAIL="you@example.com"                         # Let's Encrypt account email
export CERT_DIR="/etc/letsencrypt/live"
export TF_VAR_client_id="<your-ocm-client-id>"
export TF_VAR_client_secret="<your-ocm-client-secret>"
export TF_VAR_admin_password="<your-admin-password>"
export TF_VAR_cluster_name="${CLUSTER_NAME}"
```

## Deploy a ROSA HCP Cluster

Clone the `rh-mobb/terraform-rosa` module. It handles networking, HCP account IAM roles, OIDC configuration, operator roles, cluster creation, and the default machine pool in a single `make` command.

```bash
git clone https://github.com/rh-mobb/terraform-rosa.git
cd terraform-rosa
```


Create a `terraform.tfvars` file for a public single-AZ HCP cluster:

```bash
cat > terraform.tfvars <<EOF
hosted_control_plane = true
private              = false
multi_az             = false
replicas             = 2
ocp_version          = "${VERSION}"
compute_machine_type = "m5.xlarge"
pod_cidr             = "10.128.0.0/14"
service_cidr         = "172.30.0.0/16"
EOF
```

Deploy the cluster:

```bash
make hcp
```

Expected output:

```
Apply complete! Resources: 24 added, 0 changed, 0 destroyed.

Outputs:

cluster_api_url     = "https://api.custom-console-hcp.xxxx.p3.openshiftapps.com:443"
cluster_console_url = "https://console-openshift-console.apps.custom-console-hcp.xxxx.p3.openshiftapps.com"
cluster_id          = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
cluster_name        = "custom-console-hcp"
```

{{% alert state="info" %}}
Cluster provisioning takes approximately 15 to 20 minutes. The `make hcp` target waits for the cluster to reach Ready state before returning.
{{% /alert %}}

## Verify the Cluster is Ready

```bash
rosa describe cluster -c ${CLUSTER_NAME} --region ${REGION}
```

Expected output:

```
Name:                       custom-console-hcp
State:                      ready
```

Log in to the cluster using the `make` helper:

```bash
make login
```

Or manually:

```bash
oc login $(terraform output -raw cluster_api_url) \
  --username admin \
  --password "${TF_VAR_admin_password}"
```

Capture the cluster domain for later steps. The `terraform-rosa` module does not expose `cluster_domain` directly, so derive it from `cluster_console_url`:

```bash
export CLUSTER_DOMAIN=$(terraform output -raw cluster_console_url \
  | sed 's|https://console-openshift-console.apps.||')
echo "Default console: https://console-openshift-console.apps.${CLUSTER_DOMAIN}"
```

## Obtain TLS Certificates

Use Let's Encrypt with the Route 53 DNS-01 challenge. Certbot automatically creates and cleans up the `_acme-challenge` TXT record in Route 53; no HTTP server or firewall changes are needed.

{{% alert state="info" %}}
The AWS credentials used by certbot require `route53:GetChange`, `route53:ListHostedZones`, `route53:ListResourceRecordSets`, and `route53:ChangeResourceRecordSets` on the hosted zone. Verify permissions before proceeding with `aws iam simulate-principal-policy`.
{{% /alert %}}

### Request Certificates

```bash
# Console certificate
sudo ~/.local/bin/certbot certonly \
  --dns-route53 \
  -d "${CONSOLE_HOSTNAME}" \
  --email "${EMAIL}" \
  --agree-tos \
  --non-interactive

# Downloads certificate
sudo ~/.local/bin/certbot certonly \
  --dns-route53 \
  -d "${DOWNLOADS_HOSTNAME}" \
  --email "${EMAIL}" \
  --agree-tos \
  --non-interactive
```

Verify the certificates were issued:

```bash
sudo ls ${CERT_DIR}/${CONSOLE_HOSTNAME}/
sudo ls ${CERT_DIR}/${DOWNLOADS_HOSTNAME}/
```

Expected output:

```
cert.pem  chain.pem  fullchain.pem  privkey.pem
```

## Configure DNS Records

### Get the Ingress Load Balancer Hostname

```bash
export INGRESS_LB=$(oc get svc router-default -n openshift-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Ingress LB: ${INGRESS_LB}"
```

### Create Route 53 CNAME Records

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${CONSOLE_HOSTNAME}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{ "Value": "${INGRESS_LB}" }]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOWNLOADS_HOSTNAME}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{ "Value": "${INGRESS_LB}" }]
      }
    }
  ]
}
EOF
)"
```

Verify DNS propagation (allow approximately 60 seconds):

```bash
dig +short ${CONSOLE_HOSTNAME}
dig +short ${DOWNLOADS_HOSTNAME}
```

Expected output:

```
<ingress-lb-hostname>
```

{{% alert state="info" %}}
If `dig` returns empty, wait another 30 to 60 seconds and retry. Route 53 changes typically propagate within 60 seconds, but the TTL on your local resolver's negative cache may delay visibility.
{{% /alert %}}

## Create TLS Secrets on the Cluster

The TLS secrets must exist in the `openshift-config` namespace on the hosted cluster before Terraform applies the component route configuration. OpenShift reads these secrets when routing TLS traffic for the custom hostnames.

{{% alert state="warning" %}}
The certificate files under `/etc/letsencrypt/live/` are root-owned. Copy them to a readable temp location before running `oc`; `oc` must run as your user (not root) to access your kubeconfig.
{{% /alert %}}

```bash
# Copy certs to a readable temp location
sudo cp ${CERT_DIR}/${CONSOLE_HOSTNAME}/fullchain.pem   /tmp/console-fullchain.pem
sudo cp ${CERT_DIR}/${CONSOLE_HOSTNAME}/privkey.pem     /tmp/console-privkey.pem
sudo cp ${CERT_DIR}/${DOWNLOADS_HOSTNAME}/fullchain.pem /tmp/downloads-fullchain.pem
sudo cp ${CERT_DIR}/${DOWNLOADS_HOSTNAME}/privkey.pem   /tmp/downloads-privkey.pem
sudo chmod 644 /tmp/console-*.pem /tmp/downloads-*.pem

oc create secret tls console-tls \
  --cert=/tmp/console-fullchain.pem \
  --key=/tmp/console-privkey.pem \
  -n openshift-config

oc create secret tls downloads-tls \
  --cert=/tmp/downloads-fullchain.pem \
  --key=/tmp/downloads-privkey.pem \
  -n openshift-config

# Remove temp copies
rm /tmp/console-*.pem /tmp/downloads-*.pem
```

Verify both secrets exist:

```bash
oc get secrets -n openshift-config | grep -E "console-tls|downloads-tls"
```

Expected output:

```
console-tls    kubernetes.io/tls   2      10s
downloads-tls  kubernetes.io/tls   2      5s
```

## Configure Custom Component Routes

Add a new Terraform file to the cloned `terraform-rosa` directory. The `local.cluster_id` value is already defined in the module's `04-cluster.tf` and resolves to the HCP cluster ID.

```bash
cat > 25-component-routes.tf <<'EOF'
variable "console_hostname" {
  type    = string
  default = null
}

variable "console_tls_secret_ref" {
  type    = string
  default = null
}

variable "downloads_hostname" {
  type    = string
  default = null
}

variable "downloads_tls_secret_ref" {
  type    = string
  default = null
}

locals {
  component_routes = merge(
    var.console_hostname != null && var.console_tls_secret_ref != null ? {
      console = {
        hostname       = var.console_hostname
        tls_secret_ref = var.console_tls_secret_ref
      }
    } : {},
    var.downloads_hostname != null && var.downloads_tls_secret_ref != null ? {
      downloads = {
        hostname       = var.downloads_hostname
        tls_secret_ref = var.downloads_tls_secret_ref
      }
    } : {}
  )
}

resource "rhcs_hcp_default_ingress" "custom_routes" {
  cluster          = local.cluster_id
  listening_method = "external"
  component_routes = length(local.component_routes) > 0 ? local.component_routes : null
}
EOF
```

Apply with the route variables:

```bash
terraform apply \
  -var="console_hostname=${CONSOLE_HOSTNAME}" \
  -var="console_tls_secret_ref=console-tls" \
  -var="downloads_hostname=${DOWNLOADS_HOSTNAME}" \
  -var="downloads_tls_secret_ref=downloads-tls"
```

Expected output:

```
rhcs_hcp_default_ingress.custom_routes: Modifying...
rhcs_hcp_default_ingress.custom_routes: Modifications complete after 8s

Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

## Verify the Configuration

### Check the Cluster Ingress Config

```bash
oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.componentRoutes}' | jq
```

Expected output:

```json
[
  {
    "hostname": "console.example.com",
    "name": "console",
    "namespace": "openshift-console",
    "servingCertKeyPairSecret": { "name": "console-tls" }
  },
  {
    "hostname": "downloads.example.com",
    "name": "downloads",
    "namespace": "openshift-console",
    "servingCertKeyPairSecret": { "name": "downloads-tls" }
  }
]
```

### Confirm the Custom Routes Were Created

```bash
oc get routes -n openshift-console | grep -E "console-custom|downloads-custom"
```

Expected output:

```
console-custom    console.example.com    ...   reencrypt   None
downloads-custom  downloads.example.com  ...   reencrypt   None
```

### Verify the Default Route Redirects to the Custom Hostname

The original auto-generated route now issues an HTTP 301 redirect:

```bash
curl -Ik https://console-openshift-console.apps.${CLUSTER_DOMAIN}
```

Expected output:

```
HTTP/2 301
location: https://console.example.com
```

### Access the Console on the Custom Hostname

```bash
curl -sI https://${CONSOLE_HOSTNAME} | head -3
```

Expected output:

```
HTTP/2 200
content-type: text/html
```

**What to observe:**

1. The browser navigates directly to `https://console.example.com` without passing through the default cluster domain.
2. The TLS certificate in the browser shows your organization's domain (issued by Let's Encrypt) rather than the ROSA wildcard certificate.
3. The downloads page at `https://downloads.example.com` serves the `oc`, `kubectl`, and `rosa` CLI binaries correctly.
4. Logging in via the console still functions normally; authentication is unaffected by the route change.

## Removing Custom Routes

To revert both routes to cluster defaults, pass null values and re-apply:

```bash
terraform apply \
  -var="console_hostname=null" \
  -var="console_tls_secret_ref=null" \
  -var="downloads_hostname=null" \
  -var="downloads_tls_secret_ref=null" \
  -var="cluster_name=${CLUSTER_NAME}" \
  -var="client_id=${TF_VAR_client_id}" \
  -var="client_secret=${TF_VAR_client_secret}"
```

OpenShift immediately restores the auto-generated hostnames under the cluster domain. No rolling restart is required.

## Certificate Renewal

Let's Encrypt certificates expire after 90 days. Use `--dry-run=client -o yaml | oc apply -f -` to update secrets in-place rather than erroring on a duplicate resource:

```bash
# Renew certificates
sudo ~/.local/bin/certbot renew --dns-route53

# Copy renewed certs to a readable temp location
sudo cp ${CERT_DIR}/${CONSOLE_HOSTNAME}/fullchain.pem   /tmp/console-fullchain.pem
sudo cp ${CERT_DIR}/${CONSOLE_HOSTNAME}/privkey.pem     /tmp/console-privkey.pem
sudo cp ${CERT_DIR}/${DOWNLOADS_HOSTNAME}/fullchain.pem /tmp/downloads-fullchain.pem
sudo cp ${CERT_DIR}/${DOWNLOADS_HOSTNAME}/privkey.pem   /tmp/downloads-privkey.pem
sudo chmod 644 /tmp/console-*.pem /tmp/downloads-*.pem

# Update secrets in the cluster
oc create secret tls console-tls \
  --cert=/tmp/console-fullchain.pem \
  --key=/tmp/console-privkey.pem \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

oc create secret tls downloads-tls \
  --cert=/tmp/downloads-fullchain.pem \
  --key=/tmp/downloads-privkey.pem \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

rm /tmp/console-*.pem /tmp/downloads-*.pem
```

{{% alert state="info" %}}
`certbot renew` is idempotent and skips renewal when the certificate has more than 30 days remaining. A post-renewal hook script can run the `oc apply` commands automatically on each successful renewal.
{{% /alert %}}

## Cleanup

```bash
# Revert to default routes and remove the component routes file
terraform apply \
  -var="console_hostname=null" \
  -var="console_tls_secret_ref=null" \
  -var="downloads_hostname=null" \
  -var="downloads_tls_secret_ref=null" \
  -var="cluster_name=${CLUSTER_NAME}" \
  -var="client_id=${TF_VAR_client_id}" \
  -var="client_secret=${TF_VAR_client_secret}"
rm 25-component-routes.tf

# Destroy the cluster and all infrastructure
make destroy
```

## Summary

| Capability | What It Shows | Benefit |
|---|---|---|
| **Custom console hostname** | Replaces `console-openshift-console.apps.*` with an organization-controlled domain | Enterprise branding and compliance domain policy |
| **Custom downloads hostname** | Replaces `downloads-openshift-console.apps.*` with an organization-controlled domain | Consistent domain across all cluster-facing tools |
| **Let's Encrypt + Route 53 DNS-01** | Automated certificate issuance without HTTP challenge or firewall changes | Works for private clusters and complex network topologies |
| **Terraform-managed component routes** | `rhcs_hcp_default_ingress.component_routes` tracks state and diffs cleanly on plan | Infrastructure-as-code for day-2 route operations |
| **Partial route configuration** | Console-only, downloads-only, or both can be set independently | Incremental rollout with no forced all-or-nothing change |
| **Idempotent secret renewal** | `--dry-run=client -o yaml \| oc apply` updates secrets without re-create errors | Safe to run in automated renewal pipelines |

## Additional Resources

* [RHCS provider: `rhcs_hcp_default_ingress` resource](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/resources/hcp_default_ingress)
* [rh-mobb/terraform-rosa module](https://github.com/rh-mobb/terraform-rosa)
* [OpenShift documentation: Customizing the ingress controller](https://docs.openshift.com/container-platform/4.22/networking/ingress-operator.html)
* [certbot-dns-route53 plugin documentation](https://certbot-dns-route53.readthedocs.io/)