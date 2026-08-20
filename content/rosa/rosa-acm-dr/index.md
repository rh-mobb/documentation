---
date: '2026-08-20'
title: ROSA HCP Disaster Recovery with ACM and OpenShift GitOps
tags: ["ROSA HCP", "ACM", "GitOps"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
---

This guide demonstrates how to set up an active/passive disaster recovery pattern for applications running on ROSA HCP clusters using Red Hat Advanced Cluster Management (ACM) and OpenShift GitOps (ArgoCD). ACM handles cluster health monitoring and automatic failover detection, while ArgoCD deploys the application to whichever cluster ACM selects.

> **Important:** This guide covers **application placement DR only** — it automates deploying your application to a healthy cluster when the primary becomes unavailable. It does **not** cover data replication. If your application requires data continuity across regions, you must configure S3 Cross-Region Replication and/or EFS replication separately. See the companion [ROSA DR with OADP](/experts/rosa/rosa-oadp-dr/) guide for the data layer.

The pattern works as follows:

- ACM monitors cluster health via klusterlet heartbeats
- A Placement resource selects one healthy cluster at a time (active/passive)
- When the active cluster becomes unreachable, ACM automatically moves the placement to the standby cluster
- ArgoCD detects the placement change and deploys the application to the new target cluster
- DNS is switched manually to point to the new active cluster

## Prerequisites

This guide assumes the following are already in place:

* Two ROSA HCP clusters in different AWS regions (referred to as `$CLUSTER_EAST` in us-east-1 and `$CLUSTER_WEST` in us-west-2)
* A third ROSA HCP cluster for the ACM hub (`$CLUSTER_ACM`) with the ACM operator installed
* S3 buckets created in each region for application data
* EFS file systems created in each region with the AWS EFS CSI Driver installed
* IRSA roles for S3 access created on each regional cluster
* AWS CLI, `oc` CLI, and `rosa` CLI configured
* A Route 53 hosted zone for the custom domain

## Environment Variables

Set the following environment variables. Update the values to match your environment.

```bash
export CLUSTER_ACM=<your-acm-cluster-name>
export CLUSTER_EAST=<your-east-cluster-name>
export CLUSTER_WEST=<your-west-cluster-name>
export NAMESPACE=acm-demo
export CUSTOM_DOMAIN=<your-custom-domain>
export S3_BUCKET_EAST=<your-east-s3-bucket>
export S3_BUCKET_WEST=<your-west-s3-bucket>
export S3_ROLE_ARN_EAST="arn:aws:iam::<your-account-id>:role/<your-east-s3-role>"
export S3_ROLE_ARN_WEST="arn:aws:iam::<your-account-id>:role/<your-west-s3-role>"
export EFS_ID_EAST=<your-east-efs-id>
export EFS_ID_WEST=<your-west-efs-id>
export HOSTED_ZONE_ID=<your-route53-hosted-zone-id>
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_ADMIN_PASSWORD='<your-cluster-admin-password>'
```

## Log into the ACM Hub Cluster

All resources in this guide are created on the ACM hub cluster unless otherwise noted.

```bash
ACM_API=$(rosa describe cluster -c $CLUSTER_ACM -o json | jq -r '.api.url')
oc login $ACM_API --username cluster-admin --password "$CLUSTER_ADMIN_PASSWORD"
```

## Import Managed Clusters into ACM

Import each regional cluster so ACM can monitor and manage them.

### Import the East Cluster

1. Create the ManagedCluster resource

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1
   kind: ManagedCluster
   metadata:
     name: ${CLUSTER_EAST}
     labels:
       name: ${CLUSTER_EAST}
       cloud: Amazon
       region: us-east-1
       vendor: OpenShift
   spec:
     hubAcceptsClient: true
   EOF
   ```

1. Get a token from the east cluster and create the auto-import secret

   > **Note:** Use `oc create secret generic` with `--from-literal` rather than inline YAML. Tokens often contain special characters that break YAML parsing.

   ```bash
   EAST_API=$(rosa describe cluster -c $CLUSTER_EAST -o json | jq -r '.api.url')
   oc login $EAST_API --username cluster-admin --password "$CLUSTER_ADMIN_PASSWORD" --insecure-skip-tls-verify
   EAST_TOKEN=$(oc whoami -t)

   oc login $ACM_API --username cluster-admin --password "$CLUSTER_ADMIN_PASSWORD"

   oc create secret generic auto-import-secret \
     -n ${CLUSTER_EAST} \
     --from-literal=autoImportRetry=5 \
     --from-literal=token="${EAST_TOKEN}" \
     --from-literal=server="${EAST_API}"
   ```

1. Wait for the cluster to be imported and available

   ```bash
   watch "oc get managedcluster ${CLUSTER_EAST}"
   ```

   Wait until `AVAILABLE` shows `True`:

   ```
   NAME       HUB ACCEPTED   MANAGED CLUSTER URLS                  JOINED   AVAILABLE   AGE
   kmc-east   true           https://api.kmc-east...                True     True        2m
   ```

### Import the West Cluster

1. Create the ManagedCluster resource

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1
   kind: ManagedCluster
   metadata:
     name: ${CLUSTER_WEST}
     labels:
       name: ${CLUSTER_WEST}
       cloud: Amazon
       region: us-west-2
       vendor: OpenShift
   spec:
     hubAcceptsClient: true
   EOF
   ```

1. Get a token from the west cluster and create the auto-import secret

   ```bash
   WEST_API=$(rosa describe cluster -c $CLUSTER_WEST -o json | jq -r '.api.url')
   oc login $WEST_API --username cluster-admin --password "$CLUSTER_ADMIN_PASSWORD" --insecure-skip-tls-verify
   WEST_TOKEN=$(oc whoami -t)

   oc login $ACM_API --username cluster-admin --password "$CLUSTER_ADMIN_PASSWORD"

   oc create secret generic auto-import-secret \
     -n ${CLUSTER_WEST} \
     --from-literal=autoImportRetry=5 \
     --from-literal=token="${WEST_TOKEN}" \
     --from-literal=server="${WEST_API}"
   ```

1. Wait for the cluster to be imported and available

   ```bash
   watch "oc get managedcluster ${CLUSTER_WEST}"
   ```

1. Verify both clusters are imported

   ```bash
   oc get managedclusters
   ```

   ```
   NAME            HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
   kmc-east        true           https://api...          True     True        5m
   kmc-west        true           https://api...          True     True        2m
   local-cluster   true           https://api...          True     True        30m
   ```

## Create a ManagedClusterSet

Group the regional clusters into a ManagedClusterSet so they can be referenced as a single pool for placement decisions.

1. Create the ManagedClusterSet

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1beta2
   kind: ManagedClusterSet
   metadata:
     name: dr-clusters
   EOF
   ```

1. Add both clusters to the set

   ```bash
   oc label managedcluster ${CLUSTER_EAST} cluster.open-cluster-management.io/clusterset=dr-clusters --overwrite
   oc label managedcluster ${CLUSTER_WEST} cluster.open-cluster-management.io/clusterset=dr-clusters --overwrite
   ```

1. Create a ManagedClusterSetBinding in the `openshift-gitops` namespace to allow ArgoCD to use this cluster set

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1beta2
   kind: ManagedClusterSetBinding
   metadata:
     name: dr-clusters
     namespace: openshift-gitops
   spec:
     clusterSet: dr-clusters
   EOF
   ```

## Install OpenShift GitOps on the Hub

Install the OpenShift GitOps operator which provides ArgoCD.

1. Install the operator

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: openshift-gitops-operator
     namespace: openshift-operators
   spec:
     channel: latest
     installPlanApproval: Automatic
     name: openshift-gitops-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   EOF
   ```

1. Wait for the operator to install

   ```bash
   watch "oc get csv -n openshift-operators | grep gitops"
   ```

   Wait until the `PHASE` shows `Succeeded`.

1. Grant the ArgoCD service account cluster-admin privileges

   ```bash
   oc adm policy add-cluster-role-to-user cluster-admin \
     system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
   ```

1. Get the ArgoCD admin password

   ```bash
   ARGOCD_PASS=$(oc get secret openshift-gitops-cluster \
     -n openshift-gitops \
     -o jsonpath='{.data.admin\.password}' | base64 -d)
   echo "ArgoCD admin password: $ARGOCD_PASS"
   ```

## Register Managed Clusters with ArgoCD

Use the ACM GitOpsCluster CRD to register managed clusters as ArgoCD deployment targets. This uses the ACM cluster-proxy so ArgoCD can deploy to managed clusters without direct network access.

1. Create a Placement to select all clusters in the DR cluster set

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1beta1
   kind: Placement
   metadata:
     name: all-dr-clusters
     namespace: openshift-gitops
   spec:
     clusterSets:
       - dr-clusters
   EOF
   ```

1. Create the GitOpsCluster resource

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: apps.open-cluster-management.io/v1beta1
   kind: GitOpsCluster
   metadata:
     name: gitops-cluster
     namespace: openshift-gitops
   spec:
     argoServer:
       cluster: local-cluster
       argoNamespace: openshift-gitops
     placementRef:
       kind: Placement
       apiVersion: cluster.open-cluster-management.io/v1beta1
       name: all-dr-clusters
       namespace: openshift-gitops
   EOF
   ```

1. Verify the clusters appear as ArgoCD cluster secrets

   ```bash
   oc get secrets -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
   ```

   You should see secrets for both `kmc-east` and `kmc-west`.

## Configure ACM Placement for Failover

Create the Placement that controls which cluster the application is deployed to. This is the core of the DR mechanism.

1. Create the application Placement

   This Placement selects exactly one cluster from the `dr-clusters` set. The `Steady` prioritizer keeps the application on its current cluster unless it becomes unreachable. The tolerations allow 30 seconds after a cluster is tainted as unreachable before the placement moves.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1beta1
   kind: Placement
   metadata:
     name: acm-demo-placement
     namespace: openshift-gitops
   spec:
     clusterSets:
       - dr-clusters
     numberOfClusters: 1
     prioritizerPolicy:
       mode: Exact
       configurations:
         - scoreCoordinate:
             type: BuiltIn
             builtIn: Steady
           weight: 3
     tolerations:
       - key: cluster.open-cluster-management.io/unreachable
         operator: Exists
         tolerationSeconds: 30
       - key: cluster.open-cluster-management.io/unavailable
         operator: Exists
         tolerationSeconds: 30
   EOF
   ```

1. Create the ConfigMap that tells the ArgoCD ApplicationSet how to read ACM PlacementDecisions

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: acm-placement-config
     namespace: openshift-gitops
   data:
     apiVersion: cluster.open-cluster-management.io/v1beta1
     kind: PlacementDecision
     statusListKey: status.decisions
     matchKey: status.decisions[].clusterName
   EOF
   ```

1. Verify the placement is selecting a cluster

   ```bash
   oc get placementdecision -n openshift-gitops \
     -l cluster.open-cluster-management.io/placement=acm-demo-placement \
     -o jsonpath='{.items[0].status.decisions[0].clusterName}'
   ```

## Tune Lease Duration for Faster Failover Detection

By default, ACM checks the klusterlet heartbeat lease every 5 minutes. For a faster demo, reduce the lease duration to 10 seconds on both managed clusters.

```bash
oc patch managedcluster ${CLUSTER_EAST} --type merge \
  -p '{"spec":{"leaseDurationSeconds":10}}'
oc patch managedcluster ${CLUSTER_WEST} --type merge \
  -p '{"spec":{"leaseDurationSeconds":10}}'
```

> **Note:** With a 10-second lease duration and 30-second placement toleration, total failover detection time is approximately 40 seconds. The default 5-minute lease results in failover detection of approximately 5.5 minutes. Choose values appropriate for your environment.

## Obtain a TLS Certificate (Optional)

If you want to serve the application on a custom domain with a valid TLS certificate, obtain one using Let's Encrypt with a DNS-01 challenge via Route 53.

1. Request the certificate

   ```bash
   certbot certonly --manual --preferred-challenges dns \
     --server https://acme-v02.api.letsencrypt.org/directory \
     -d ${CUSTOM_DOMAIN} \
     --config-dir /tmp/certbot/config \
     --work-dir /tmp/certbot/work \
     --logs-dir /tmp/certbot/logs
   ```

   Follow the prompts to create a DNS TXT record in Route 53 for validation.

1. Store the certificate and key in environment variables

   ```bash
   export TLS_CERT=$(cat /tmp/certbot/config/live/${CUSTOM_DOMAIN}/fullchain.pem)
   export TLS_KEY=$(cat /tmp/certbot/config/live/${CUSTOM_DOMAIN}/privkey.pem)
   ```

## Create the ArgoCD ApplicationSet

The ApplicationSet uses a merge generator that combines two sources:

- **clusterDecisionResource**: reads from ACM's PlacementDecision to know which cluster to deploy to
- **list**: provides per-cluster configuration (region, S3 bucket, IRSA role ARN, EFS file system ID)

When the PlacementDecision changes (e.g., failover), ArgoCD automatically deploys the application to the new target cluster and removes it from the old one.

> **Note:** During failover, the old cluster is unreachable, so ArgoCD cannot prune resources from it immediately. When the old cluster recovers, ArgoCD will detect it is no longer the placement target and prune the application resources. During this recovery window, the application may temporarily run on both clusters.

1. Create the ApplicationSet

   First, if you obtained a TLS certificate, prepare the indented cert and key for YAML embedding:

   ```bash
   if [ -n "${TLS_CERT}" ]; then
     export TLS_CERT_INDENTED=$(echo "$TLS_CERT" | awk '{printf "%s%s\n", "                    ", $0}')
     export TLS_KEY_INDENTED=$(echo "$TLS_KEY" | awk '{printf "%s%s\n", "                    ", $0}')
   else
     export TLS_CERT_INDENTED=""
     export TLS_KEY_INDENTED=""
   fi
   ```

   Then create the ApplicationSet:

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: acm-demo
     namespace: openshift-gitops
   spec:
     goTemplate: true
     generators:
       - merge:
           mergeKeys:
             - name
           generators:
             - clusterDecisionResource:
                 configMapRef: acm-placement-config
                 labelSelector:
                   matchLabels:
                     cluster.open-cluster-management.io/placement: acm-demo-placement
                 requeueAfterSeconds: 30
             - list:
                 elements:
                   - name: ${CLUSTER_EAST}
                     clusterRegion: us-east-1
                     s3Bucket: ${S3_BUCKET_EAST}
                     s3RoleArn: ${S3_ROLE_ARN_EAST}
                     efsId: ${EFS_ID_EAST}
                   - name: ${CLUSTER_WEST}
                     clusterRegion: us-west-2
                     s3Bucket: ${S3_BUCKET_WEST}
                     s3RoleArn: ${S3_ROLE_ARN_WEST}
                     efsId: ${EFS_ID_WEST}
     template:
       metadata:
         name: acm-demo-{{.name}}
         labels:
           region: "{{.clusterRegion}}"
           cluster: "{{.name}}"
       spec:
         project: default
         source:
           repoURL: https://github.com/rh-mobb/phoenix-mission-control.git
           targetRevision: main
           path: chart
           helm:
             releaseName: phoenix-mission-control
             values: |
               region: {{.clusterRegion}}
               clusterName: {{.name}}
               s3:
                 bucket: {{.s3Bucket}}
                 roleArn: {{.s3RoleArn}}
               efs:
                 fileSystemId: {{.efsId}}
                 storageClassName: acm-efs-sc
               primaryRegion: us-east-1
               primaryCluster: ${CLUSTER_EAST}
               primaryHealthUrl: ""
               drRegion: us-west-2
               drCluster: ${CLUSTER_WEST}
               route:
                 enabled: true
                 customDomain: ${CUSTOM_DOMAIN}
                 tls:
                   certificate: |
   ${TLS_CERT_INDENTED}
                   key: |
   ${TLS_KEY_INDENTED}
         destination:
           server: "{{.server}}"
           namespace: ${NAMESPACE}
         syncPolicy:
           automated:
             prune: true
             selfHeal: true
           syncOptions:
             - CreateNamespace=true
   EOF
   ```

   > **Note:** The heredoc substitutes `${VAR}` references with your environment variable values. The Go template `{{.field}}` references use double curly braces and are not substituted by the shell — they are processed by ArgoCD at deploy time. If you did not set `TLS_CERT` and `TLS_KEY`, the TLS fields will be empty and the route will use the cluster's default wildcard certificate.

1. Verify the Application was created and is syncing

   ```bash
   watch "oc get applications.argoproj.io -n openshift-gitops"
   ```

   Wait until the application shows `Synced` and `Healthy`:

   ```
   NAME                SYNC STATUS   HEALTH STATUS
   acm-demo-kmc-east   Synced        Healthy
   ```

## Set Up DNS

Create a Route 53 A record pointing to the router of the active cluster.

> **Note:** This guide uses a plain A record with a short TTL (30s) rather than an Alias record. Alias records with `EvaluateTargetHealth` can cause negative DNS caching if the ELB is temporarily unhealthy during failover. The trade-off is that ELB IP addresses can change without notice. With a 30s TTL this is tolerable for a demo, but for production use a CNAME or Alias record pointing to the ELB hostname with `EvaluateTargetHealth` set to `false`.

1. Get the ELB hostname and IP for the east cluster

   ```bash
   EAST_API=$(rosa describe cluster -c $CLUSTER_EAST -o json | jq -r '.api.url')
   EAST_ELB=$(oc --server=$EAST_API --insecure-skip-tls-verify \
     get svc -n openshift-ingress router-default \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   EAST_IP=$(dig +short $EAST_ELB | head -1)
   echo "East ELB: $EAST_ELB"
   echo "East IP: $EAST_IP"
   ```

1. Get the ELB hostname and IP for the west cluster

   ```bash
   WEST_API=$(rosa describe cluster -c $CLUSTER_WEST -o json | jq -r '.api.url')
   WEST_ELB=$(oc --server=$WEST_API --insecure-skip-tls-verify \
     get svc -n openshift-ingress router-default \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   WEST_IP=$(dig +short $WEST_ELB | head -1)
   echo "West ELB: $WEST_ELB"
   echo "West IP: $WEST_IP"
   ```

1. Create the DNS record pointing to the primary (east) cluster

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id $HOSTED_ZONE_ID \
     --change-batch "{
       \"Changes\": [{
         \"Action\": \"UPSERT\",
         \"ResourceRecordSet\": {
           \"Name\": \"${CUSTOM_DOMAIN}\",
           \"Type\": \"A\",
           \"TTL\": 30,
           \"ResourceRecords\": [{\"Value\": \"${EAST_IP}\"}]
         }
       }]
     }"
   ```

1. Verify the application is accessible

   ```bash
   curl -sk https://${CUSTOM_DOMAIN}/healthz
   ```

   ```json
   {"mission":"PHOENIX-7","status":"ok"}
   ```

## Failover Test

Simulate a region failure by stopping the worker instances on the east cluster.

1. Verify the application is healthy

   ```bash
   curl -sk https://${CUSTOM_DOMAIN}/healthz
   ```

1. Get the east cluster worker instance IDs

   ```bash
   EAST_INSTANCE_IDS=$(aws ec2 describe-instances --region us-east-1 \
     --filters "Name=tag:Name,Values=*${CLUSTER_EAST}*worker*" \
               "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' --output text)
   echo "East instance IDs: $EAST_INSTANCE_IDS"
   ```

1. Stop the east worker instances

   ```bash
   aws ec2 stop-instances --region us-east-1 --force --instance-ids $EAST_INSTANCE_IDS
   ```

1. Watch for ACM to detect the failure and ArgoCD to deploy to the west cluster

   With the tuned lease duration (10s) and toleration (30s), this should take approximately 40-50 seconds.

   ```bash
   watch -n5 "echo '=== Cluster Status ===' && \
     oc get managedcluster ${CLUSTER_EAST} -o jsonpath='Available: {.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' && \
     echo '' && echo '' && echo '=== ArgoCD Apps ===' && \
     oc get applications.argoproj.io -n openshift-gitops"
   ```

   Wait until `Available` changes from `True` to `Unknown` and a new application `acm-demo-kmc-west` appears with `Synced`/`Healthy` status.

1. Switch DNS to the west cluster

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id $HOSTED_ZONE_ID \
     --change-batch "{
       \"Changes\": [{
         \"Action\": \"UPSERT\",
         \"ResourceRecordSet\": {
           \"Name\": \"${CUSTOM_DOMAIN}\",
           \"Type\": \"A\",
           \"TTL\": 30,
           \"ResourceRecords\": [{\"Value\": \"${WEST_IP}\"}]
         }
       }]
     }"
   ```

1. Flush local DNS cache and verify

   ```bash
   # macOS
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

   curl -sk https://${CUSTOM_DOMAIN}/healthz
   ```

## Failback

Failing back is a manual process. The Steady prioritizer in the Placement keeps the application on the current (west) cluster even after east recovers, preventing unnecessary flip-flopping.

1. Start the east worker instances

   ```bash
   aws ec2 start-instances --region us-east-1 --instance-ids $EAST_INSTANCE_IDS
   ```

1. Wait for the east cluster to rejoin ACM

   This typically takes 2-3 minutes as the klusterlet pods restart and begin sending heartbeats.

   ```bash
   watch "oc get managedcluster ${CLUSTER_EAST} -o jsonpath='Available: {.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}'"
   ```

   Wait until it shows `True`.

1. Force the placement back to the east cluster

   The Steady prioritizer keeps the app on west (the current cluster). To fail back, temporarily add a label selector that only matches the east cluster:

   ```bash
   oc patch placement acm-demo-placement -n openshift-gitops --type merge \
     -p '{"spec":{"predicates":[{"requiredClusterSelector":{"labelSelector":{"matchLabels":{"name":"'${CLUSTER_EAST}'"}}}}]}}'
   ```

1. Verify ArgoCD deployed to the east cluster

   ```bash
   watch "oc get applications.argoproj.io -n openshift-gitops"
   ```

   Wait until `acm-demo-kmc-east` shows `Synced`/`Healthy`.

1. Switch DNS back to the east cluster

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id $HOSTED_ZONE_ID \
     --change-batch "{
       \"Changes\": [{
         \"Action\": \"UPSERT\",
         \"ResourceRecordSet\": {
           \"Name\": \"${CUSTOM_DOMAIN}\",
           \"Type\": \"A\",
           \"TTL\": 30,
           \"ResourceRecords\": [{\"Value\": \"${EAST_IP}\"}]
         }
       }]
     }"
   ```

1. Remove the failback label selector to restore automatic failover

   ```bash
   oc patch placement acm-demo-placement -n openshift-gitops --type json \
     -p '[{"op":"remove","path":"/spec/predicates"}]'
   ```

1. Flush local DNS cache and verify

   ```bash
   # macOS
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

   curl -sk https://${CUSTOM_DOMAIN}/healthz
   ```

## Failover Timeline Summary

| Event | Time |
|-------|------|
| Cluster failure occurs | T+0s |
| Klusterlet lease expires | T+10s |
| ACM taints cluster as unreachable | T+10s |
| Placement toleration expires | T+40s |
| ACM moves placement to standby cluster | T+40s |
| ArgoCD detects change and begins sync | T+45s |
| Application healthy on new cluster | T+50s |
| DNS switch (manual) | T+60s |

> **Note:** Failover detection is automatic. DNS switching is a manual step. For production environments, consider using Route 53 health checks with DNS failover routing to automate the DNS switch as well.

## Production Considerations

- **Data replication:** This guide covers application placement only. Configure [S3 Cross-Region Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html) and [EFS replication](https://docs.aws.amazon.com/efs/latest/ug/efs-replication.html) to ensure data continuity across regions.
- **ACM hub availability:** The ACM hub is a single point of failure for failover detection. In production, deploy the hub with high availability or consider an active-passive hub configuration.
- **DNS automation:** Replace the manual DNS switch with Route 53 health checks and failover routing policies for fully automated DR.
- **Lease duration tuning:** The 10-second lease used in this guide is aggressive. For production, balance detection speed against the risk of false positives from transient network issues. A 60-second lease is a reasonable starting point.

## Cleanup

1. Delete the ApplicationSet

   ```bash
   oc delete applicationset acm-demo -n openshift-gitops
   ```

1. Delete the Placement and ConfigMap

   ```bash
   oc delete placement acm-demo-placement -n openshift-gitops
   oc delete configmap acm-placement-config -n openshift-gitops
   ```

1. Delete the GitOpsCluster and all-clusters Placement

   ```bash
   oc delete gitopscluster gitops-cluster -n openshift-gitops
   oc delete placement all-dr-clusters -n openshift-gitops
   ```

1. Delete the ManagedClusterSetBinding and ManagedClusterSet

   ```bash
   oc delete managedclustersetbinding dr-clusters -n openshift-gitops
   oc delete managedclusterset dr-clusters
   ```

1. Detach the managed clusters

   ```bash
   oc delete managedcluster ${CLUSTER_EAST}
   oc delete managedcluster ${CLUSTER_WEST}
   ```

1. Delete the DNS record

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id $HOSTED_ZONE_ID \
     --change-batch "{
       \"Changes\": [{
         \"Action\": \"DELETE\",
         \"ResourceRecordSet\": {
           \"Name\": \"${CUSTOM_DOMAIN}\",
           \"Type\": \"A\",
           \"TTL\": 30,
           \"ResourceRecords\": [{\"Value\": \"${EAST_IP}\"}]
         }
       }]
     }"
   ```
