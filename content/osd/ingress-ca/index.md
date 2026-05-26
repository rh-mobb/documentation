---
date: '2026-05-20'
title: Using Google Cloud Armor with a Secondary IngressController on OpenShift Dedicated (GCP)
tags: ["OSD"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.21"
---

Google Cloud Armor provides DDoS protection and Web Application Firewall (WAF) capabilities for applications running on Google Cloud Platform. This guide demonstrates how to configure a secondary IngressController on OpenShift Dedicated (OSD) running on GCP and protect it with Cloud Armor security policies.

The architecture uses an HTTP(S) Load Balancer with Cloud Armor in front of a secondary IngressController, providing a secure path from the Internet to your applications: Internet -> HTTPS Load Balancer (with Cloud Armor) -> Secondary IngressController (Network Load Balancer) -> Application.

![Architecture Diagram](images/architecture.png)

## 0. Why this Approach

Google Cloud Armor only works with HTTP(S) Load Balancers that have backend services. OpenShift IngressControllers create Network Load Balancers (Layer 4) which don't support Cloud Armor directly. Therefore, we create:

1. A **private** secondary IngressController that creates an Internal Network Load Balancer (no internet access)
2. A **public** HTTP(S) Load Balancer with Cloud Armor security policies (internet-facing)
3. The public HTTP(S) Load Balancer forwards traffic through the VPC to the private Network Load Balancer
4. Applications use standard OpenShift Route objects

The traffic flow is:
```
Internet → Cloud Armor HTTPS LB (public) → Backend Service → Instance Group → 
Private IngressController NLB → Router Pods → Application
```

This approach allows you to:

- Use Google Cloud Armor for DDoS protection and WAF capabilities
- Implement geo-based access controls and rate limiting
- Block malicious IP addresses and traffic patterns
- Keep the IngressController private with no direct internet exposure
- Use standard OpenShift Route objects instead of managing Ingress resources
- Maintain compatibility with existing OpenShift deployment patterns

## 1. Prerequisites

* An OpenShift Dedicated cluster on GCP v4.18 and above
* The `oc` CLI logged in to your cluster
* The `gcloud` CLI configured with access to the GCP project
* A domain name for testing (these instructions assume you control DNS for the domain)
* certbot installed. On macOS: brew install certbot or On RHEL/Fedora: sudo dnf install certbot

## 2. Set Environment Variables

Set the following environment variables for use throughout this guide:

```bash
export PROJECT_ID=$(gcloud config get-value project)
export CLUSTER_NAME="kevin-cluster"  # Replace with your cluster name
export INGRESS_NAME="cloudarmor"
export DOMAIN="kevin.mobb.cloud"  # Replace with your base domain
export EMAIL="your-email@example.com"  # Replace with your email for Let's Encrypt
export SCRATCH_DIR="${HOME}/cloud-armor-setup"
```

The IngressController will use the domain `${INGRESS_NAME}.${DOMAIN}` (e.g., `cloudarmor.kevin.mobb.cloud`), and applications will be accessible at `*.${INGRESS_NAME}.${DOMAIN}` (e.g., `hello.cloudarmor.kevin.mobb.cloud`).

## 3. Create a Private Secondary IngressController

Create a **private** secondary IngressController that will handle traffic from Cloud Armor:

```bash
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ${INGRESS_NAME}
  namespace: openshift-ingress-operator
spec:
  domain: ${INGRESS_NAME}.${DOMAIN}
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: Internal
  replicas: 2
  routeSelector:
    matchLabels:
      type: cloudarmor
EOF
```

**Note:** The `scope: Internal` setting creates a private Network Load Balancer that is only accessible within the VPC, not from the internet.

Wait for the IngressController to provision:

```bash
oc get ingresscontroller ${INGRESS_NAME} -n openshift-ingress-operator -w
```

Press `Ctrl+C` when the status shows as available.

Wait for the Internal Load Balancer to provision and get an IP address:

```bash
echo "Waiting for Internal NLB IP to be assigned..."
while true
do
  INTERNAL_NLB_IP=$(oc get svc router-${INGRESS_NAME} -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$INTERNAL_NLB_IP" ]]
  then
    echo "Internal NLB IP assigned: $INTERNAL_NLB_IP"
    break
  fi
  echo -n "."
  sleep 5
done
```

Verify the Internal Load Balancer was created with a private IP:

```bash
# Verify it is a private IP (should be in the 10.x.x.x range)
if [[ $INTERNAL_NLB_IP == 10.* ]]
then
  echo "✓ Confirmed: Internal Load Balancer with private IP"
else
  echo "✗ Warning: Expected private IP, got: $INTERNAL_NLB_IP"
fi
```

The Internal Network Load Balancer is not accessible from the internet. Traffic will only reach it through the Cloud Armor HTTPS Load Balancer.

## 4. Create Backend Service with Internal IP

Create Network Endpoint Groups (NEGs) that point to the Internal NLB IP address. This step automatically detects all zones where router pods are running and creates NEGs in each zone for high availability:

**Note:** Get the ODS cluster's VPC Network name. If VPC network has cluster name you could use following, if not define NETWORK value manually. 
```bash
# Get network name
NETWORK=$(gcloud compute networks list --filter="name~${CLUSTER_NAME}" --format="value(name)" | head -1)
```

```bash
# Get the internal NLB IP
INTERNAL_NLB_IP=$(oc get svc router-${INGRESS_NAME} -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Validate network name
[ -z "$NETWORK" ] && { echo "X Error: NETWORK is empty. No network found for ${CLUSTER_NAME}";}
echo "Using network: $NETWORK"

# Detect zones where router pods are running
ZONES=$(oc get pods -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${INGRESS_NAME} \
  -o json | jq -r '.items[].spec.nodeName' | \
  xargs -I {} oc get node {} -o json | \
  jq -r '.metadata.labels["topology.kubernetes.io/zone"] // empty' | \
  sort -u)

echo "Creating NEGs in zones: ${ZONES}"

# Create a Network Endpoint Group in each zone
for ZONE in ${ZONES}
do
  echo "Creating NEG in zone ${ZONE}..."
  
  gcloud compute network-endpoint-groups create ${CLUSTER_NAME}-armor-neg-${ZONE} \
    --network-endpoint-type=NON_GCP_PRIVATE_IP_PORT \
    --zone=${ZONE} \
    --network=${NETWORK}
  
  # Add the internal NLB IP as an endpoint on port 443
  gcloud compute network-endpoint-groups update ${CLUSTER_NAME}-armor-neg-${ZONE} \
    --zone=${ZONE} \
    --add-endpoint="ip=${INTERNAL_NLB_IP},port=443"
done
```

**Note:** The NEGs use `NON_GCP_PRIVATE_IP_PORT` type because the Internal NLB IP is managed by Kubernetes, not directly by GCP. Even though all NEGs point to the same Internal NLB IP, creating them in multiple zones provides redundancy and allows the Cloud Armor backend service to distribute health checks and traffic properly.

## 5. Create Health Check

Create an HTTPS health check that probes the IngressController through the Internal NLB:

```bash
gcloud compute health-checks create https ${CLUSTER_NAME}-armor-hc \
  --port=443 \
  --request-path="/" \
  --host="hello.${INGRESS_NAME}.${DOMAIN}" \
  --check-interval=10s \
  --timeout=5s \
  --unhealthy-threshold=3 \
  --healthy-threshold=2 \
  --description="Health check for ${INGRESS_NAME} ingress controller"
```

**Note:** The health check uses port 443 (HTTPS) with a Host header (`hello.${INGRESS_NAME}.${DOMAIN}`) because the IngressController requires a valid hostname that matches a route. Without a matching Host header, the router returns an error page and the health check fails. The backend will show as UNHEALTHY until you deploy the test application in Section 14, which creates a route matching this hostname.

## 6. Create Backend Service

Create a backend service that will be protected by Cloud Armor:

```bash
# Create backend service with logging enabled
gcloud compute backend-services create ${CLUSTER_NAME}-armor-backend \
  --global \
  --protocol=HTTPS \
  --health-checks=${CLUSTER_NAME}-armor-hc \
  --timeout=30s \
  --port-name=https \
  --enable-logging \
  --logging-sample-rate=1.0

# Detect zones where router pods are running
ZONES=$(oc get pods -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${INGRESS_NAME} \
  -o json | jq -r '.items[].spec.nodeName' | \
  xargs -I {} oc get node {} -o json | \
  jq -r '.metadata.labels["topology.kubernetes.io/zone"] // empty' | \
  sort -u)

# Add each Network Endpoint Group as a backend
for ZONE in ${ZONES}
do
  echo "Adding NEG from zone ${ZONE} to backend service..."
  gcloud compute backend-services add-backend ${CLUSTER_NAME}-armor-backend \
    --global \
    --network-endpoint-group=${CLUSTER_NAME}-armor-neg-${ZONE} \
    --network-endpoint-group-zone=${ZONE} \
    --balancing-mode=RATE \
    --max-rate-per-endpoint=1000
done
```

**Note:** We use `RATE` balancing mode for NEG backends instead of `UTILIZATION`.

## 7. Create Cloud Armor Security Policy

Create a Cloud Armor security policy with example rules:

```bash
# Create the security policy
gcloud compute security-policies create ${CLUSTER_NAME}-armor-policy \
  --description="Cloud Armor policy for ${CLUSTER_NAME} ingress"

# Example: Allow traffic only from specific countries
gcloud compute security-policies rules create 1000 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="origin.region_code == 'US' || origin.region_code == 'CA'" \
  --action=allow \
  --description="Allow traffic from US and Canada"

# Example: Block a specific IP range
gcloud compute security-policies rules create 2000 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="inIpRange(origin.ip, '192.0.2.0/24')" \
  --action=deny-403 \
  --description="Block example malicious IP range"

# Set default rule to allow (you can change to deny for allowlist approach)
gcloud compute security-policies rules update 2147483647 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --action=allow \
  --description="Default rule - allow all other traffic"
```

## 8. Attach Cloud Armor to Backend Service

Attach the security policy to the backend service:

```bash
gcloud compute backend-services update ${CLUSTER_NAME}-armor-backend \
  --global \
  --security-policy=${CLUSTER_NAME}-armor-policy
```

## 9. Create URL Map

Create a URL map that routes all traffic to the backend service:

```bash
gcloud compute url-maps create ${CLUSTER_NAME}-armor-urlmap \
  --default-service=${CLUSTER_NAME}-armor-backend
```

## 10. Create SSL Certificates

Both the Cloud Armor HTTPS Load Balancer and the OpenShift IngressController need to handle TLS for the same wildcard domain (`*.${INGRESS_NAME}.${DOMAIN}`). We'll create a single Let's Encrypt certificate and use it in both places.

**Note:** Google-managed certificates do not support wildcard domains, so we use Let's Encrypt instead.

### 10.1. Create Let's Encrypt Certificate

Create a Let's Encrypt wildcard certificate (requires DNS TXT record verification):

```bash
# Install certbot if not already installed
# On macOS: brew install certbot
# On RHEL/Fedora: sudo dnf install certbot

# Create directories
mkdir -p ${SCRATCH_DIR}/letsencrypt/{config,work,logs}
mkdir -p ${SCRATCH_DIR}/openshift-certs

# Generate wildcard certificate
certbot certonly \
  --manual \
  --preferred-challenges=dns \
  --email ${EMAIL} \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --agree-tos \
  --config-dir ${SCRATCH_DIR}/letsencrypt/config \
  --work-dir ${SCRATCH_DIR}/letsencrypt/work \
  --logs-dir ${SCRATCH_DIR}/letsencrypt/logs \
  -d "*.${INGRESS_NAME}.${DOMAIN}"
```

When prompted, create a DNS TXT record for `_acme-challenge.${INGRESS_NAME}.${DOMAIN}` with the value provided by certbot.

Verify the DNS record has propagated:

```bash
dig TXT _acme-challenge.$INGRESS_NAME.$DOMAIN
```

Once verified, press Enter in the certbot prompt to complete the certificate generation.

Copy the certificates to the working directory:

```bash
cp ${SCRATCH_DIR}/letsencrypt/config/live/${INGRESS_NAME}.${DOMAIN}/fullchain.pem ${SCRATCH_DIR}/openshift-certs/
cp ${SCRATCH_DIR}/letsencrypt/config/live/${INGRESS_NAME}.${DOMAIN}/privkey.pem ${SCRATCH_DIR}/openshift-certs/
chmod 644 ${SCRATCH_DIR}/openshift-certs/fullchain.pem
chmod 600 ${SCRATCH_DIR}/openshift-certs/privkey.pem
```

### 10.2. Upload Certificate to GCP

Upload the Let's Encrypt certificate to GCP for the Cloud Armor HTTPS Load Balancer:

```bash
gcloud compute ssl-certificates create ${CLUSTER_NAME}-armor-cert \
  --certificate=${SCRATCH_DIR}/openshift-certs/fullchain.pem \
  --private-key=${SCRATCH_DIR}/openshift-certs/privkey.pem \
  --global
```

### 10.3. Configure Certificate for IngressController

Create a TLS secret and configure it on the IngressController:

```bash
# Create TLS secret
oc create secret tls ${INGRESS_NAME}-certs \
  --cert=${SCRATCH_DIR}/openshift-certs/fullchain.pem \
  --key=${SCRATCH_DIR}/openshift-certs/privkey.pem \
  -n openshift-ingress

# Patch the IngressController to use the certificate
oc patch ingresscontroller ${INGRESS_NAME} \
  -n openshift-ingress-operator \
  --type=merge \
  --patch='{"spec":{"defaultCertificate":{"name":"'${INGRESS_NAME}'-certs"}}}'

# Wait for router pods to restart
oc get pods -n openshift-ingress -w | grep ${INGRESS_NAME}
```

Press `Ctrl+C` once the router pods are running.

## 11. Create Target HTTPS Proxy

Create a target HTTPS proxy:

```bash
gcloud compute target-https-proxies create ${CLUSTER_NAME}-armor-proxy \
  --url-map=${CLUSTER_NAME}-armor-urlmap \
  --ssl-certificates=${CLUSTER_NAME}-armor-cert
```

## 12. Reserve Static IP and Create Forwarding Rule

Reserve a static IP address:

```bash
gcloud compute addresses create ${CLUSTER_NAME}-armor-ip \
  --global \
  --ip-version=IPV4
```

Get the IP address:

```bash
STATIC_IP=$(gcloud compute addresses describe ${CLUSTER_NAME}-armor-ip \
  --global \
  --format="value(address)")
echo "Static IP for Cloud Armor LB: $STATIC_IP"
```

Create the forwarding rule:

```bash
gcloud compute forwarding-rules create ${CLUSTER_NAME}-armor-https-rule \
  --global \
  --target-https-proxy=${CLUSTER_NAME}-armor-proxy \
  --address=${CLUSTER_NAME}-armor-ip \
  --ports=443
```

## 13. Configure DNS

Create a wildcard DNS record pointing to the static IP address.

**Note:** The example below uses Google Cloud DNS. If you are using a different DNS provider (Route 53, Cloudflare, etc.), follow similar steps in your DNS provider's console or CLI to create the wildcard A record.

### Using Google Cloud DNS

```bash
# Get your DNS zone name (find it with: gcloud dns managed-zones list)
ZONE_NAME="your-dns-zone"  # Replace with your zone name

# Create wildcard A record for the Cloud Armor ingress
gcloud dns record-sets create "*.${INGRESS_NAME}.${DOMAIN}." \
  --zone=${ZONE_NAME} \
  --type=A \
  --ttl=300 \
  --rrdatas=${STATIC_IP}
```

### Using Other DNS Providers

If using a different DNS provider, create a wildcard A record with the following values:
- **Name**: `*.${INGRESS_NAME}.${DOMAIN}` (e.g., `*.cloudarmor.kevin.mobb.cloud`)
- **Type**: A
- **Value**: `${STATIC_IP}` (the Cloud Armor Load Balancer IP)
- **TTL**: 300 (or your preferred value)

Verify DNS propagation:

```bash
# Should return the STATIC_IP
dig +short hello.$INGRESS_NAME.$DOMAIN
```

## 14. Test the Configuration

Create a test application:

```bash
# Create a new project
oc new-project cloudarmor-test

# Create a test application
oc new-app --docker-image=docker.io/openshift/hello-openshift

# Create a route with the cloudarmor label
oc create route edge hello-cloudarmor \
  --service=hello-openshift \
  --hostname=hello.${INGRESS_NAME}.${DOMAIN}

# Label the route so it uses the cloudarmor ingress
oc label route hello-cloudarmor type=cloudarmor
```

Test access to the application:

```bash
curl https://hello.$INGRESS_NAME.$DOMAIN
```

You should see: `Hello OpenShift!`

## 15. Verify Cloud Armor is Working

### Test Geographic Restriction

If you configured the geo-restriction rule (allowing only US/CA), test from a different location or use a VPN:

```bash
# From an allowed location (US/CA)
curl https://hello.$INGRESS_NAME.$DOMAIN
# Should return: Hello OpenShift!

# From a blocked location (not US/CA)
curl https://hello.$INGRESS_NAME.$DOMAIN
# Should return: HTTP 403 Forbidden
```

### Test IP Blocking

Test the IP blocking rule:

```bash
# Get your IPv4 address (use -4 to ensure IPv4 since that's what connects to Cloud Armor)
MY_IP=$(curl -4 -s ifconfig.me)
echo "Blocking IPv4: $MY_IP"

# Use priority 500 (lower than the geo-allow rule at 1000) so this deny is evaluated first
gcloud compute security-policies rules create 500 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="inIpRange(origin.ip, '${MY_IP}/32')" \
  --action=deny-403 \
  --description="Block test IPv4"

# Wait for the rule to propagate (can take 30-60 seconds)
echo "Waiting 60 seconds for rule to propagate..."
sleep 60

# Test access (should be blocked)
curl https://hello.$INGRESS_NAME.$DOMAIN
# Should return: HTTP 403 Forbidden

# Remove the test rule
gcloud compute security-policies rules delete 500 \
  --security-policy=${CLUSTER_NAME}-armor-policy
```

**Note:** Cloud Armor evaluates rules in ascending priority order and stops at the first match. The IP block rule must have a lower priority number (500) than the geo-allow rule (1000), otherwise traffic from allowed countries will match the geo-allow rule first and never reach the IP block rule.

### View Cloud Armor Logs

**Note:** Logging was enabled on the backend service in Section 6 with `--enable-logging --logging-sample-rate=1.0`. This allows Cloud Armor to send request logs to Cloud Logging.

View the blocked requests from the IP blocking test above:

```bash
# View blocked requests from the IP blocking test (priority 500)
gcloud logging read "resource.type=http_load_balancer AND jsonPayload.enforcedSecurityPolicy.configuredAction=DENY AND jsonPayload.enforcedSecurityPolicy.priority=500" --limit=10 --freshness=10m --format="table(timestamp,jsonPayload.remoteIp,httpRequest.requestUrl,httpRequest.status,jsonPayload.enforcedSecurityPolicy.priority)"
```

View all recent security policy logs:

```bash
# Generate some allowed traffic
for i in {1..5}
do
  curl https://hello.$INGRESS_NAME.$DOMAIN
done

# Wait a few seconds for logs to be ingested
sleep 10

# View recent logs (last 10 minutes)
gcloud logging read "resource.type=http_load_balancer" --limit=10 --freshness=10m --format="table(timestamp,jsonPayload.remoteIp,httpRequest.requestUrl,httpRequest.status,jsonPayload.enforcedSecurityPolicy.configuredAction,jsonPayload.enforcedSecurityPolicy.priority)"
```

To view only blocked requests:

```bash
gcloud logging read "resource.type=http_load_balancer AND jsonPayload.enforcedSecurityPolicy.configuredAction=DENY" --limit=10 --freshness=10m --format="table(timestamp,jsonPayload.remoteIp,httpRequest.requestUrl,httpRequest.status,jsonPayload.enforcedSecurityPolicy.priority)"
```

## 16. Advanced Cloud Armor Rules

**Note:** The advanced rules below use low priority numbers (100, 200, 300) to ensure they are evaluated before the geo-allow rule at priority 1000. Cloud Armor evaluates rules in ascending priority order and stops at the first match, so security rules must have lower priority numbers than allow rules to be effective.

### Rate Limiting

Limit requests to 100 per minute from a single IP:

```bash
# Use priority 100 (before geo-allow at 1000) so rate limiting is evaluated first
gcloud compute security-policies rules create 100 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="true" \
  --action=rate-based-ban \
  --rate-limit-threshold-count=100 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --ban-duration-sec=600 \
  --description="Rate limit: 100 req/min per IP"

# Wait for the rule to propagate
echo "Waiting 60 seconds for rule to propagate..."
sleep 60
```

Test the rate limiting by sending rapid requests:

```bash
# Send 120 requests rapidly to trigger the rate limit
for i in {1..120}
do
  curl -s -o /dev/null -w "%{http_code}\n" https://hello.$INGRESS_NAME.$DOMAIN
  sleep 0.1
done

# After ~100 requests, you should start seeing 429 (Too Many Requests) responses
```

Remove the rate limit rule:

```bash
gcloud compute security-policies rules delete 100 \
  --security-policy=${CLUSTER_NAME}-armor-policy
```

### SQL Injection Protection

**Note:** Make sure to delete the rate limiting rule from the previous test before proceeding, otherwise you may get rate-limited (429 errors) during testing.

Block common SQL injection patterns:

```bash
# Use priority 200 (before geo-allow at 1000) so SQLi protection is evaluated first
gcloud compute security-policies rules create 200 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="evaluatePreconfiguredExpr('sqli-stable')" \
  --action=deny-403 \
  --description="Block SQL injection attempts"

# Wait for rule to propagate
echo "Waiting 60 seconds for rule to propagate..."
sleep 60
```

Test SQL injection protection:

```bash
# Attempt a SQL injection pattern (URL-encoded: 1' OR '1'='1)
echo "Testing SQL injection pattern (should be blocked):"
curl "https://hello.$INGRESS_NAME.$DOMAIN/?id=1%27%20OR%20%271%27=%271"
echo ""

# Normal request (should work)
echo "Testing normal request (should succeed):"
curl "https://hello.$INGRESS_NAME.$DOMAIN/"
echo ""
```

Remove the SQL injection rule:

```bash
gcloud compute security-policies rules delete 200 \
  --security-policy=${CLUSTER_NAME}-armor-policy
```

### XSS Protection

**Note:** Make sure to delete the SQL injection rule from the previous test before proceeding.

Block cross-site scripting attempts:

```bash
# Use priority 300 (before geo-allow at 1000) so XSS protection is evaluated first
gcloud compute security-policies rules create 300 \
  --security-policy=${CLUSTER_NAME}-armor-policy \
  --expression="evaluatePreconfiguredExpr('xss-stable')" \
  --action=deny-403 \
  --description="Block XSS attempts"

# Wait for rule to propagate
echo "Waiting 60 seconds for rule to propagate..."
sleep 60
```

Test XSS protection:

```bash
# Attempt an XSS pattern (URL-encoded: <script>alert('xss')</script>)
echo "Testing XSS pattern (should be blocked):"
curl "https://hello.$INGRESS_NAME.$DOMAIN/?name=%3Cscript%3Ealert%28%27xss%27%29%3C/script%3E"
echo ""

# Normal request (should work)
echo "Testing normal request (should succeed):"
curl "https://hello.$INGRESS_NAME.$DOMAIN/"
echo ""
```

Remove the XSS protection rule:

```bash
gcloud compute security-policies rules delete 300 \
  --security-policy=${CLUSTER_NAME}-armor-policy
```

## 17. Cleanup

To remove all resources created in this guide:

```bash
# Delete forwarding rule
gcloud compute forwarding-rules delete ${CLUSTER_NAME}-armor-https-rule --global --quiet

# Delete target proxy
gcloud compute target-https-proxies delete ${CLUSTER_NAME}-armor-proxy --quiet

# Delete URL map
gcloud compute url-maps delete ${CLUSTER_NAME}-armor-urlmap --quiet

# Delete SSL certificate
gcloud compute ssl-certificates delete ${CLUSTER_NAME}-armor-cert --global --quiet

# Delete backend service (this automatically detaches the security policy)
gcloud compute backend-services delete ${CLUSTER_NAME}-armor-backend --global --quiet

# Delete security policy
gcloud compute security-policies delete ${CLUSTER_NAME}-armor-policy --quiet

# Delete health check
gcloud compute health-checks delete ${CLUSTER_NAME}-armor-hc --quiet

# Delete Network Endpoint Groups
ZONES=$(oc get pods -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${INGRESS_NAME} \
  -o json | jq -r '.items[].spec.nodeName' | \
  xargs -I {} oc get node {} -o json | \
  jq -r '.metadata.labels["topology.kubernetes.io/zone"] // empty' | \
  sort -u)

for ZONE in ${ZONES}
do
  gcloud compute network-endpoint-groups delete ${CLUSTER_NAME}-armor-neg-${ZONE} \
    --zone=${ZONE} --quiet
done

# Delete static IP
gcloud compute addresses delete ${CLUSTER_NAME}-armor-ip --global --quiet

# Delete test application
oc delete project cloudarmor-test

# Delete secondary ingress controller
oc delete ingresscontroller ${INGRESS_NAME} -n openshift-ingress-operator
```

## References

- [Google Cloud Armor Documentation](https://cloud.google.com/armor/docs)
- [Cloud Armor Security Policy Rules](https://cloud.google.com/armor/docs/configure-security-policies)
- [OpenShift IngressController Documentation](https://docs.openshift.com/container-platform/latest/networking/ingress-operator.html)
- [Google Cloud Load Balancing](https://cloud.google.com/load-balancing/docs)
