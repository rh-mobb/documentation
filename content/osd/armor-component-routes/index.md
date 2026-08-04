---
date: '2026-07-31'
title: Routing OpenShift Component Routes through a custom domain with Google Cloud Armor
tags: ["OSD"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.20"
---

This guide extends [Using Google Cloud Armor with a Secondary IngressController on OpenShift Dedicated (GCP)](/experts/osd/ingress-ca/) to securely route the OpenShift console, downloads, and OAuth endpoints through Cloud Armor. By the end of this guide, users will access the OpenShift web console, downloads server, and OAuth authentication through the Cloud Armor-protected HTTPS Load Balancer.

## Prerequisites

Complete the [Cloud Armor with Secondary IngressController guide](/experts/osd/ingress-ca/) through at least **Step 14** (Test the Configuration). You should have:

* A working Cloud Armor HTTPS Load Balancer with a secondary private `cloudarmor` IngressController
* The backend service showing `HEALTHY` (`gcloud compute backend-services get-health`)
* DNS configured for `*.${INGRESS_NAME}.${DOMAIN}` pointing to the Cloud Armor static IP
* A wildcard TLS certificate for `*.${INGRESS_NAME}.${DOMAIN}`

You will also need:

* The `ocm` CLI logged in to your Red Hat account (`ocm whoami` to verify)

## 1. Set Environment Variables

If continuing from the Cloud Armor guide, these variables should already be set. Otherwise, set them now:

```bash
export CLUSTER_NAME="kevin-cluster"
export INGRESS_NAME="cloudarmor"
export DOMAIN="kevin.mobb.cloud"
export SCRATCH_DIR="${HOME}/cloud-armor-setup"
```

## 2. Get OCM Cluster and Ingress IDs

Retrieve the OCM cluster ID and default ingress ID. These are needed to configure component routes through `ocm`.

```bash
export OCM_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters \
  --parameter search="name = '${CLUSTER_NAME}'" | jq -r '.items[0].id')

echo "OCM Cluster ID: ${OCM_CLUSTER_ID}"
```

Get the default ingress ID:

```bash
ocm get /api/clusters_mgmt/v1/clusters/${OCM_CLUSTER_ID}/ingresses | \
  jq -r '.items[] | "\(.id) \(.default)"'
```

The default ingress (marked `true`) is the one you need. For example, `v3p7`. Set it:

```bash
export DEFAULT_INGRESS_ID="v3p7"

echo "Default Ingress ID: ${DEFAULT_INGRESS_ID}"
```

## 3. Create TLS Secrets for Component Routes

Component routes require TLS secrets in the `openshift-config` namespace. Create secrets for console, downloads, and OAuth using the same wildcard certificate from the Cloud Armor guide:

```bash
for COMPONENT in console downloads oauth
do
  oc create secret tls ${COMPONENT}-tls \
    --cert=${SCRATCH_DIR}/openshift-certs/fullchain.pem \
    --key=${SCRATCH_DIR}/openshift-certs/privkey.pem \
    -n openshift-config
done
```

Verify the secrets were created:

```bash
oc get secrets -n openshift-config | grep -E "console-tls|downloads-tls|oauth-tls"
```

## 4. Configure Component Routes via OCM

Use `ocm edit ingress` to set custom hostnames and TLS secrets for the console, downloads, and OAuth component routes. All three components must be specified in a single command:

```bash
ocm edit ingress ${DEFAULT_INGRESS_ID} -c ${OCM_CLUSTER_ID} \
  --component-routes \
  'console: hostname=console.'"${INGRESS_NAME}.${DOMAIN}"';tlsSecretRef=console-tls,downloads: hostname=downloads.'"${INGRESS_NAME}.${DOMAIN}"';tlsSecretRef=downloads-tls,oauth: hostname=oauth.'"${INGRESS_NAME}.${DOMAIN}"';tlsSecretRef=oauth-tls'
```

This updates the `ingresses.config.openshift.io/cluster` resource, which tells the console and authentication operators to create routes with the custom hostnames. Wait a minute for the operators to reconcile, then verify the routes were created:

```bash
oc get routes -n openshift-console
oc get routes -n openshift-authentication
```

You should see `console-custom` and `downloads-custom` in `openshift-console`, and the existing `oauth-openshift` route in `openshift-authentication`.

## 5. Label Console and Downloads Routes

The operator-managed `console-custom` and `downloads-custom` routes need the `type=cloudarmor` label so the cloudarmor IngressController admits them:

```bash
oc label route console-custom -n openshift-console type=cloudarmor
oc label route downloads-custom -n openshift-console type=cloudarmor
```

Verify the routes are admitted by the cloudarmor IngressController:

```bash
oc get routes -n openshift-console -l type=cloudarmor
```

## 6. Create OAuth Reencrypt Route

The authentication operator creates the OAuth route with **passthrough** TLS termination. Passthrough routes forward raw TLS directly to the backend pod. This is incompatible with the Cloud Armor HTTPS Load Balancer, which terminates TLS at the Google edge and opens a new HTTPS connection to the backend. When the terminated connection reaches the OpenShift router, there is no raw TLS stream to pass through.

The solution is a **reencrypt** route. The reencrypt route terminates TLS at the router (accepting the LB's re-encrypted connection) and opens a new TLS connection to the OAuth pod on port 6443, verifying the pod's certificate using the service-serving-signer CA.

Extract the service-serving-signer CA:

```bash
oc get cm v4-0-config-system-service-ca -n openshift-authentication \
  -o jsonpath='{.data.service-ca\.crt}' > ${SCRATCH_DIR}/service-ca-bundle.pem
```

Create the reencrypt route:

```bash
oc create route reencrypt oauth-cloudarmor \
  --service=oauth-openshift \
  --port=6443 \
  -n openshift-authentication \
  --hostname=oauth.${INGRESS_NAME}.${DOMAIN} \
  --cert=${SCRATCH_DIR}/openshift-certs/fullchain.pem \
  --key=${SCRATCH_DIR}/openshift-certs/privkey.pem \
  --dest-ca-cert=${SCRATCH_DIR}/service-ca-bundle.pem
```

Label the route for the cloudarmor IngressController:

```bash
oc label route oauth-cloudarmor -n openshift-authentication type=cloudarmor
```

{{< alert state="info" >}}
The operator-managed `oauth-openshift` passthrough route remains on the **default** IngressController for direct cluster access. Do not label it with `type=cloudarmor`.
{{< /alert >}}

## 7. Verify Component Routes

Test each component route through Cloud Armor:

```bash
# Console (expect HTTP 200)
curl -s -o /dev/null -w "Console: %{http_code}\n" \
  https://console.${INGRESS_NAME}.${DOMAIN}

# Downloads (expect HTTP 200)
curl -s -o /dev/null -w "Downloads: %{http_code}\n" \
  https://downloads.${INGRESS_NAME}.${DOMAIN}

# OAuth health check (expect HTTP 200)
curl -s -o /dev/null -w "OAuth: %{http_code}\n" \
  https://oauth.${INGRESS_NAME}.${DOMAIN}/healthz
```
Wait roughly 10 minutes for everything to sync, then open the console in an **incognito/private browser window**:

```
https://console.<INGRESS_NAME>.<DOMAIN>
```

{{< alert state="warning" >}}
If you previously accessed the default OpenShift console, your browser may have cached the old OAuth redirect URL (`oauth-openshift.apps...`). Use an incognito/private window or clear your browser cache to avoid being redirected to the wrong OAuth endpoint.
{{< /alert >}}

Clicking **Log in** should redirect to the OAuth endpoint at `oauth.<INGRESS_NAME>.<DOMAIN>`, authenticate, and return you to the console.

## Cleanup

To remove the component route configuration while keeping the base Cloud Armor setup intact:

```bash
# Remove the OAuth reencrypt route
oc delete route oauth-cloudarmor -n openshift-authentication

# Remove cloudarmor labels from operator-managed routes
oc label route console-custom -n openshift-console type-
oc label route downloads-custom -n openshift-console type-

# Remove component routes configuration
cat > /tmp/ocm_patch.json << 'EOF'
{
  "component_routes": {
    "console": {"hostname": "", "tls_secret_ref": ""},
    "downloads": {"hostname": "", "tls_secret_ref": ""},
    "oauth": {"hostname": "", "tls_secret_ref": ""}
  }
}
EOF
ocm patch /api/clusters_mgmt/v1/clusters/${OCM_CLUSTER_ID}/ingresses/${DEFAULT_INGRESS_ID} --body /tmp/ocm_patch.json

# Remove TLS secrets
for COMPONENT in console downloads oauth
do
  oc delete secret ${COMPONENT}-tls -n openshift-config
done
```

To remove all Cloud Armor resources including the base setup, follow the cleanup steps in the [Cloud Armor guide](/experts/osd/ingress-ca/#17-cleanup).

## References

- [Cloud Armor with Secondary IngressController](/experts/osd/ingress-ca/)
- [Updating OSD Component Routes](https://docs.openshift.com/dedicated/latest/cloud_experts_tutorials/cloud-experts-osd-update-component-routes.html)
- [Google Cloud Armor Documentation](https://cloud.google.com/armor/docs)
- [OpenShift IngressController Documentation](https://docs.openshift.com/container-platform/latest/networking/ingress-operator.html)
