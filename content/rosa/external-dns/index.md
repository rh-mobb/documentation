---
date: '2023-02-19'
title: External DNS for ROSA Custom Domain
tags: ["AWS", "ROSA"]
authors:
  - Chris Kang
---

Configuring the Custom Domain Operator requires a wildcard CNAME DNS record in your Route53 Hosted Zone. If you do not wish to use a wildcard record, you can use the External DNS Operator to create individual entries for routes.

This document will guide you through deploying and configuring the External DNS Operator with a Custom Domain in ROSA.

**Important Note**: The ExternalDNS Operator does not support STS yet and uses long lived IAM credentials. This guide will be updated once STS is supported.

## Prerequisites
* ROSA Cluster
* AWS CLI
* Route53 Hosted Zone
* A domain

## Deploy

### Setup Environment

1. Set your email and domain

  ```bash
  export EMAIL=<YOUR-EMAIL>
  export DOMAIN=<YOUR-DOMAIN>
  ```

1. Set remaining environment variables

  ```bash
  export SCRATCH_DIR=/tmp/scratch
  export ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json \
  --dns-name "$DOMAIN." --query 'HostedZones[0]'.Id --out text | sed 's/\/hostedzone\///')
  mkdir -p $SCRATCH_DIR
  ```

### Custom Domain

> Check out the [dynamic certificates](/experts/rosa/dynamic-certificates") guide if you do not want to use a wildcard certificate.

1. Create TLS Key Pair for custom domain using certbot:

    > Skip this if you already have a key pair.

   ```bash
   certbot certonly --manual \
     --preferred-challenges=dns \
     --email $EMAIL \
     --server https://acme-v02.api.letsencrypt.org/directory \
     --agree-tos \
     --config-dir "$SCRATCH_DIR/config" \
     --work-dir "$SCRATCH_DIR/work" \
     --logs-dir "$SCRATCH_DIR/logs" \
     -d "*.$DOMAIN"
   ```

1. Create TLS secret for custom domain:

    > Note use your own keypair paths if not using certbot.

   ```bash
   CERTS=/tmp/scratch/config/live/$DOMAIN
   oc new-project my-custom-route
   oc create secret tls acme-tls --cert=$CERTS/fullchain.pem --key=$CERTS/privkey.pem
   ```

1. Create Custom Domain resource:

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: managed.openshift.io/v1alpha1
   kind: CustomDomain
   metadata:
     name: acme
   spec:
     domain: $DOMAIN
     certificate:
       name: acme-tls
       namespace: my-custom-route
   EOF
   ```

1. Wait for the domain to be ready:

   ```bash
   oc wait --for=condition=Ready customdomains/acme --timeout=300s
   ```

### External DNS

1. Deploy the External DNS Operator:

   ```bash
   oc new-project external-dns-operator
   
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: external-dns-group
     namespace: external-dns-operator
   spec:
     targetNamespaces:
     - external-dns-operator
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: external-dns-operator
     namespace: external-dns-operator
   spec:
     channel: stable-v1
     installPlanApproval: Automatic
     name: external-dns-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   EOF
   ```

1. Wait until the Operator is running:

   ```bash
   oc rollout status deploy external-dns-operator --timeout=300s
   ```

1. Create IAM Policy document that allows ExternalDNS to update Route53 only in your hosted zone:

   ```bash
   cat << EOF > $SCRATCH_DIR/externaldns-r53-policy.json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "route53:ChangeResourceRecordSets"
         ],
         "Resource": [
           "arn:aws:route53:::hostedzone/$ZONE_ID"
         ]
       },
       {
         "Effect": "Allow",
         "Action": [
           "route53:ListHostedZones",
           "route53:ListResourceRecordSets"
         ],
         "Resource": [
           "*"
         ]
       }
     ]
   }
   EOF
   ```

1. Create IAM Policy:
  
   ```bash
   POLICY_ARN=$(aws iam create-policy --policy-name "AllowExternalDNSUpdates" \
   --policy-document file://$SCRATCH_DIR/externaldns-r53-policy.json \
   --query 'Policy.Arn' --output text)
   ```

1. Create IAM user and attach policy:

   > Note: This will be changed to STS using IRSA in the future.

   ```bash
   aws iam create-user --user-name "externaldns"
   aws iam attach-user-policy --user-name "externaldns" --policy-arn $POLICY_ARN   
   ```

1. Create aws keys for IAM user:

   ```bash
   SECRET_ACCESS_KEY=$(aws iam create-access-key --user-name "externaldns")
   ```

1. Create static credentials:

   ```bash   
   cat << EOF > $SCRATCH_DIR/credentials
   [default]
   aws_access_key_id = $(echo $SECRET_ACCESS_KEY | jq -r '.AccessKey.AccessKeyId')
   aws_secret_access_key = $(echo $SECRET_ACCESS_KEY | jq -r '.AccessKey.SecretAccessKey')
   EOF
   ```

1. Create secret from credentials:

   ```bash
   oc create secret generic external-dns \
   --namespace external-dns-operator --from-file $SCRATCH_DIR/credentials
   ```

1. Deploy ExternalDNS controller:

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: externaldns.olm.openshift.io/v1beta1
   kind: ExternalDNS
   metadata:
     name: $DOMAIN
   spec:
     domains:
       - filterType: Include
         matchType: Exact
         name: $DOMAIN
     provider:
       aws:
         credentials:
           name: external-dns
       type: AWS
     source:
       openshiftRouteOptions:
         routerName: acme
       type: OpenShiftRoute
     zones:
       - $ZONE_ID
   EOF
   ```

1. Wait until the controller is running:
  
   ```bash
   oc rollout status deploy external-dns-$DOMAIN --timeout=300s
   ```
   

### Test 

1. Create a new route to OpenShift console using your domain:

   ```bash
   oc create route reencrypt --service=console console-acme \
      --hostname console.$DOMAIN -n openshift-console
   ```

1. Check if DNS record was created automatically by ExternalDNS:

   > It may take a few minutes for the record to appear in Route53

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
      --query "ResourceRecordSets[?Type == 'CNAME']" | grep console
   ```

1. You can also view the TXT records that indicate they were created by ExternalDNS:

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
      --query "ResourceRecordSets[?Type == 'TXT']" | grep $DOMAIN
   ```

1. Navigate to your custom console domain in the browser and you should see OpenShift login.

   ```bash
   echo console.$DOMAIN
   ```

