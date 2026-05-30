---
date: '2026-05-27'
title: Deploy gRPC Applications with AWS ALB and WAF on ROSA HCP using Service Mesh
tags: ["ROSA HCP", "GovCloud"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.21"
---

Organizations deploying gRPC applications on Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane (HCP) often need to meet security requirements that mandate AWS Web Application Firewall (WAF) protection. However, combining gRPC support with WAF presents a unique challenge: WAF can only be attached to Application Load Balancers (ALB), and configuring ALB to properly handle gRPC traffic requires a specific architectural approach.

This guide demonstrates how to successfully deploy gRPC applications on ROSA HCP with full WAF support using AWS Application Load Balancer with native gRPC protocol support and Red Hat OpenShift Service Mesh (Istio). This architecture works in both AWS Commercial Cloud and AWS GovCloud regions.

## Why This Architecture

This architecture is the optimal solution for gRPC on ROSA when WAF is required because it provides:

**Native gRPC Support**: AWS ALB has supported gRPC natively since 2020, but only when configured with the correct target group protocol version and targeting method.

**WAF Integration**: ALB supports AWS WAF attachment, providing Layer 7 security for gRPC traffic.

**Healthy Target Status**: Unlike workarounds that leave targets in an unhealthy state, this approach maintains fully healthy targets, ensuring proper AWS monitoring and alerting.

**AWS GovCloud and Commercial Cloud Compatible**: This architecture works in both AWS GovCloud regions (where CloudFront is not available) and AWS Commercial Cloud regions, making it a universal solution for organizations operating in either environment.

**Production Ready**: All components are supported enterprise solutions - AWS ALB, Red Hat OpenShift Service Mesh, and ROSA.

**HTTP/2-aware gRPC path**: The architecture preserves the protocol behavior required by gRPC, including HTTP/2, trailers, bidirectional streaming, and proper content-type handling.

## Architecture Overview

![Architecture Diagram](architecture.png)

**Key Components:**

1. **AWS Application Load Balancer**: Terminates client TLS, handles gRPC protocol, can attach WAF
2. **Istio Service Mesh**: Provides Envoy-based ingress with native HTTP/2 and gRPC support
3. **Network Load Balancer**: Created by Istio ingress gateway service, provides stable IP addresses for ALB targeting
4. **gRPC Application**: Your containerized gRPC service running on ROSA

**Critical Configuration**: The ALB target group uses **IP target type** pointing to the NLB's IP addresses with **ProtocolVersion: GRPC**. This combination enables AWS's native gRPC support.

## Prerequisites

* A ROSA HCP cluster in AWS Commercial Cloud or AWS GovCloud
* AWS CLI configured with appropriate credentials
* `oc` CLI tool
* `rosa` CLI tool
* Cluster admin access
* A registered domain with Route 53 hosted zone
* AWS Certificate Manager certificate for your domain

**Note**: This guide uses standard AWS regions in examples. For AWS GovCloud deployments, substitute the appropriate GovCloud region (e.g., `us-gov-west-1` or `us-gov-east-1`) and ensure your ACM certificates are imported into the GovCloud region.

Set environment variables:

```bash
export ROSA_CLUSTER_NAME=<your cluster name>
export REGION=$(rosa describe cluster -c $ROSA_CLUSTER_NAME -o json | jq -r .region.id)
export SUBNET_ID=$(rosa list machinepools -c $ROSA_CLUSTER_NAME -o json | jq -r '.[0].subnet')
export VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)
export DOMAIN=<your domain>  # e.g., example.com
export GRPC_HOSTNAME=grpc.$DOMAIN
```

## Install Red Hat OpenShift Service Mesh

Red Hat OpenShift Service Mesh 3 provides the Envoy proxy layer needed for proper gRPC handling. Service Mesh 3 uses the `sailoperator.io` API (based on upstream Istio) and provides a simpler installation experience compared to Service Mesh 2.

1. Install the Red Hat OpenShift Service Mesh 3 Operator

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: servicemeshoperator3
     namespace: openshift-operators
   spec:
     channel: stable
     installPlanApproval: Automatic
     name: servicemeshoperator3
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   EOF
   ```

1. Wait for the Service Mesh operator to be ready

   ```bash
   echo "Waiting for Service Mesh 3 operator installation..."
   oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/servicemeshoperator3.openshift-operators -n openshift-operators --timeout=300s
   oc wait --for=condition=Available deployment/servicemesh-operator3 -n openshift-operators --timeout=300s
   ```

1. Create the Service Mesh namespaces

   ```bash
   oc new-project istio-system
   oc new-project istio-cni
   ```
   
   **Note**: The `oc new-project` command creates a new namespace and automatically switches your context to it.

1. Deploy IstioCNI (required for sidecar injection)

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: sailoperator.io/v1
   kind: IstioCNI
   metadata:
     name: default
   spec:
     version: v1.28-latest
     namespace: istio-cni
   EOF
   ```

1. Wait for IstioCNI to be ready

   ```bash
   oc wait --for=condition=Ready istiocni/default --timeout=300s
   ```

1. Deploy the Istio control plane

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: sailoperator.io/v1
   kind: Istio
   metadata:
     name: default
   spec:
     namespace: istio-system
     version: v1.28-latest
   EOF
   ```

1. Wait for the control plane to be ready

   ```bash
   # Wait for Istio control plane (istiod) to be ready
   oc wait --for=condition=Available deployment/istiod -n istio-system --timeout=900s
   ```
   
   If the pod is pending due to resource constraints, you may need to scale up your cluster or reduce resource requests.

1. Deploy the ingress gateway

   Service Mesh 3 doesn't automatically create an ingress gateway. Deploy one manually:

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: istio-ingressgateway
     namespace: istio-system
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: istio-ingressgateway
         istio: ingressgateway
     template:
       metadata:
         labels:
           app: istio-ingressgateway
           istio: ingressgateway
           istio.io/rev: default
         annotations:
           inject.istio.io/templates: gateway
       spec:
         containers:
         - name: istio-proxy
           image: auto
           ports:
           - containerPort: 8443
             protocol: TCP
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: istio-ingressgateway
     namespace: istio-system
     annotations:
       service.beta.kubernetes.io/aws-load-balancer-type: nlb
       service.beta.kubernetes.io/aws-load-balancer-internal: "true"
   spec:
     type: LoadBalancer
     selector:
       app: istio-ingressgateway
       istio: ingressgateway
     ports:
     - name: https
       port: 443
       protocol: TCP
       targetPort: 8443
   EOF
   ```
   
   **Important Configuration Notes**:
   - The `inject.istio.io/templates: gateway` annotation is **critical** - it creates a gateway proxy (standalone Envoy) instead of a sidecar proxy. Without this, pods will have 2/2 containers but won't function as an ingress gateway.
   - The `istio.io/rev: default` label matches the Istio revision tag.
   - No ServiceAccount is specified, so the deployment uses the `default` ServiceAccount in the namespace.

1. Create RBAC for the ingress gateway to access TLS secrets

   The ingress gateway pods use the `default` ServiceAccount and need permission to read secrets for TLS certificates:

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: istio-ingressgateway-sds
     namespace: istio-system
   rules:
   - apiGroups: [""]
     resources: ["secrets"]
     verbs: ["get", "watch", "list"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: istio-ingressgateway-sds
     namespace: istio-system
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: istio-ingressgateway-sds
   subjects:
   - kind: ServiceAccount
     name: default
     namespace: istio-system
   EOF
   ```
   
   **Critical**: This RBAC configuration is essential. Without it, the ingress gateway pods cannot access the TLS certificates stored in Kubernetes secrets, causing connection resets and unhealthy ALB targets. The istiod logs will show errors like: `"attempted to access unauthorized certificates: default/istio-system is not authorized to read secrets"`

1. Wait for the ingress gateway to be ready

   ```bash
   oc wait --for=condition=Available deployment/istio-ingressgateway -n istio-system --timeout=300s
   ```

1. Get the Istio ingress gateway NLB IP addresses

   ```bash
   # Wait for LoadBalancer to provision
   echo "Waiting for NLB to provision..."
   until oc get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | grep -q elb; do
     echo "Still waiting for NLB..."
     sleep 10
   done
 
   NLB_DNS=$(oc get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   echo "Istio NLB DNS: $NLB_DNS"
 
   # Get the NLB ARN from the DNS name
   NLB_ARN=$(aws elbv2 describe-load-balancers \
     --region "$REGION" \
     --query "LoadBalancers[?DNSName=='$NLB_DNS'].LoadBalancerArn | [0]" \
     --output text)
 
   echo "Istio NLB ARN: $NLB_ARN"
 
   # Try DNS resolution first
   echo "Waiting for NLB DNS to resolve..."
   until NLB_IPS=($(dig +short "$NLB_DNS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')) && [ "${#NLB_IPS[@]}" -gt 0 ]; do
     echo "DNS not resolved yet, waiting..."
     sleep 10
   done
 
   echo "Istio NLB IPs from DNS:"
   printf '  %s\n' "${NLB_IPS[@]}"
   ```
 
   **Note**: DNS resolution for an NLB may not always return every zonal NLB IP immediately. If the command above returns fewer IPs than expected for your Availability Zone count, use the NLB network interfaces as the source of truth:
 
   ```bash
   # Get the NLB name from the ARN
   NLB_NAME=$(echo "$NLB_ARN" | awk -F'loadbalancer/' '{print $2}')
 
   # Get the private IPs of the NLB network interfaces.
   NLB_IPS=($(aws ec2 describe-network-interfaces \
     --region "$REGION" \
     --filters "Name=description,Values=ELB $NLB_NAME" \
     --query 'NetworkInterfaces[*].PrivateIpAddress' \
     --output text))
 
   echo "NLB IPs from network interfaces:"
   printf '  %s\n' "${NLB_IPS[@]}"
 
   aws ec2 describe-network-interfaces \
     --region "$REGION" \
     --filters "Name=description,Values=ELB $NLB_NAME" \
     --query 'NetworkInterfaces[*].{AZ:AvailabilityZone,Subnet:SubnetId,PrivateIP:PrivateIpAddress}' \
     --output table
   ```
 
   Save these IP addresses - you'll need them for the ALB target group configuration.

## Deploy a Sample gRPC Application

1. Create a namespace for your application

   ```bash
   oc new-project grpc-demo
   ```

1. Enable automatic sidecar injection for the namespace

   ```bash
   oc label namespace grpc-demo istio.io/rev=default
   ```
   
   **Note**: Service Mesh 3 uses revision-based injection with the label `istio.io/rev=default` instead of the legacy `istio-injection=enabled` label.

1. Deploy the gRPC health checking server

   This example uses the Kubernetes e2e test image that implements the gRPC health checking protocol:

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: grpc-server
     namespace: grpc-demo
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: grpc-server
     template:
       metadata:
         labels:
           app: grpc-server
       spec:
         containers:
         - name: grpc-server
           image: registry.k8s.io/e2e-test-images/agnhost:2.40
           args:
           - grpc-health-checking
           ports:
           - containerPort: 5000
             name: grpc
             protocol: TCP
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: grpc-server
     namespace: grpc-demo
   spec:
     selector:
       app: grpc-server
     ports:
     - name: grpc
       port: 5000
       targetPort: 5000
       protocol: TCP
   EOF
   ```
   
   **Note**: Since the namespace has the `istio.io/rev=default` label, pods will automatically get the Istio sidecar injected without needing the `sidecar.istio.io/inject: "true"` annotation.

1. Verify the pods are running with Istio sidecars

   ```bash
   oc get pods -n grpc-demo
   ```

   You should see `2/2` in the READY column, indicating both the application container and Istio sidecar are running.

## Configure Istio Gateway and VirtualService

1. Create a TLS certificate for the Istio Gateway

   For production, import your actual certificate. For testing, create a self-signed certificate:

   ```bash
   openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=*.$DOMAIN"
   
   oc create secret tls istio-ingressgateway-certs --cert=/tmp/tls.crt --key=/tmp/tls.key -n istio-system
   ```

   Note that this Kubernetes TLS secret is used by the Istio ingress gateway for target-side TLS. It does not replace the ACM certificate required by the public ALB HTTPS listener.

1. Create the Istio Gateway

   **Important**: The Gateway must be created in the `istio-system` namespace (where the ingress gateway pods run) for the TLS configuration to be properly applied in Service Mesh 3.

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: grpc-gateway
     namespace: istio-system
   spec:
     selector:
       app: istio-ingressgateway
     servers:
     - port:
         number: 8443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: istio-ingressgateway-certs
       hosts:
       - "$GRPC_HOSTNAME"
       - "*"
   EOF
   ```

   **Important Configuration Notes**:
   - Port `8443` matches the ingress gateway container port (not the service port 443)
   - The wildcard host `"*"` is required for ALB health checks which don't send SNI (Server Name Indication)
   - Use `HTTPS` protocol, not `GRPC`. Istio's validation rejects `GRPC` protocol with TLS settings. The ALB handles gRPC protocol negotiation, and Envoy processes it as HTTP/2.

1. Create VirtualServices for health checks and application traffic

   **Important**: VirtualServices must reference the Gateway using the `namespace/name` format since the Gateway is in a different namespace.

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: grpc-vs
     namespace: grpc-demo
   spec:
     hosts:
     - "$GRPC_HOSTNAME"
     - "*"
     gateways:
     - istio-system/grpc-gateway
     http:
     - match:
       - uri:
           prefix: "/grpc.health.v1.Health"
       route:
       - destination:
           host: grpc-server.grpc-demo.svc.cluster.local
           port:
             number: 5000
     - route:
       - destination:
           host: grpc-server.grpc-demo.svc.cluster.local
           port:
             number: 5000
   EOF
   ```
   
   **Important Configuration Note**: The wildcard host `"*"` is required in addition to `$GRPC_HOSTNAME` to handle ALB health check requests that don't include the Host header or SNI.

## Configure AWS Application Load Balancer

This is the critical step where we configure ALB with native gRPC support.

1. Get or create an ACM certificate for your domain

   **Option A: Use an existing validated certificate** (faster)
   
     ```bash
     # List existing issued certificates
     aws acm list-certificates --region $REGION --certificate-statuses ISSUED
     
     # Set the ARN of an existing certificate
     export CERT_ARN=<your-existing-certificate-arn>
     ```

   **Option B: Request a new certificate**
   
      ```bash
      # Request a new certificate
      CERT_ARN=$(aws acm request-certificate \
        --domain-name "$GRPC_HOSTNAME" \
        --validation-method DNS \
        --region $REGION \
        --query CertificateArn \
        --output text)
      
      echo "Certificate ARN: $CERT_ARN"
      ```

1. Validate the certificate via DNS (only if you requested a new certificate)

   Get the DNS validation record:
   
      ```bash
      # Get validation CNAME record details
      aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region $REGION \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord.{Name:Name,Type:Type,Value:Value}' \
        --output table
      
      # Store the validation record details
      VALIDATION_NAME=$(aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region $REGION \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' \
        --output text)
      
      VALIDATION_VALUE=$(aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region $REGION \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' \
        --output text)
      ```

   Add the CNAME record to Route 53:

   **Note**: If `$DOMAIN` is a subdomain, you do not necessarily need a separate hosted zone for that exact subdomain. If DNS for the subdomain is managed in a parent Route 53 hosted zone, create the ACM validation CNAME in the parent hosted zone instead.
   
   For example, if `GRPC_HOSTNAME=grpc.test.example.com` and the Route 53 hosted zone is `example.com`, use the `example.com` hosted zone to create the validation CNAME for `grpc.test.example.com`.
   
      ```bash
      # Set this to the Route 53 hosted zone that manages your DNS.
      # This may be the same as DOMAIN, or a parent domain such as example.com.

      # Example:
      # export DOMAIN=test.example.com
      # export GRPC_HOSTNAME=grpc.$DOMAIN
      # export ROUTE53_ZONE_DOMAIN=example.com
      
        ROUTE53_ZONE_DOMAIN=${ROUTE53_ZONE_DOMAIN:-$DOMAIN}

        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
          --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id" \
          --output text | cut -d'/' -f3)

        echo "Using hosted zone: $ROUTE53_ZONE_DOMAIN ($HOSTED_ZONE_ID)"
      
      # If the hosted zone doesn't exist, create it
      if [ -z "$HOSTED_ZONE_ID" ]; then
        echo "Creating hosted zone for domain: $DOMAIN"
        HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
          --name $DOMAIN \
          --caller-reference $(date +%s) \
          --query 'HostedZone.Id' \
          --output text | cut -d'/' -f3)
        
        # If this is a subdomain (e.g., myapp.example.com), you need to set up NS delegation
        # Get the nameservers for the new zone
        NAMESERVERS=$(aws route53 list-resource-record-sets \
          --hosted-zone-id $HOSTED_ZONE_ID \
          --query 'ResourceRecordSets[?Type==`NS`].ResourceRecords[].Value' \
          --output text | tr '\t' '\n')
        
        echo "Hosted zone created. If this is a subdomain, add these NS records to the parent domain:"
        echo "$NAMESERVERS"
        echo ""
        echo "Example: If your domain is 'myapp.example.com' and parent is 'example.com',"
        echo "add NS records in the 'example.com' zone pointing to the above nameservers."
        echo ""
        # If you control the parent zone, automate NS delegation:
        # PARENT_DOMAIN=$(echo $DOMAIN | sed 's/^[^.]*\.//')
        # PARENT_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${PARENT_DOMAIN}.'].Id" --output text | cut -d'/' -f3)
        # if [ -n "$PARENT_ZONE_ID" ]; then
        #   echo "Setting up NS delegation in parent zone..."
        #   # Create NS delegation JSON and apply
        # fi
      fi
      
      echo "Hosted Zone ID: $HOSTED_ZONE_ID"
      
      # Create the validation CNAME record
      cat <<EOF > /tmp/acm-validation.json
      {
        "Changes": [
          {
            "Action": "UPSERT",
            "ResourceRecordSet": {
              "Name": "$VALIDATION_NAME",
              "Type": "CNAME",
              "TTL": 300,
              "ResourceRecords": [
                {
                  "Value": "$VALIDATION_VALUE"
                }
              ]
            }
          }
        ]
      }
      EOF
      
      aws route53 change-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID \
        --change-batch file:///tmp/acm-validation.json
      ```

   Wait for certificate validation to complete:
   
   **Important**: If you created a new hosted zone for a subdomain, ensure NS delegation is set up in the parent domain before continuing. ACM cannot validate the certificate until the DNS records are resolvable.
   
      ```bash
      # Verify DNS resolution of the validation record
      dig +short $VALIDATION_NAME CNAME
      # Should return the validation value
      
      echo "Waiting for certificate validation (this can take 5-30 minutes)..."
      aws acm wait certificate-validated \
        --certificate-arn $CERT_ARN \
        --region $REGION
      
      echo "Certificate validated!"
      
      # Verify status is ISSUED
      aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region $REGION \
        --query 'Certificate.Status' \
        --output text
      ```
   
   Expected output: `ISSUED`

1. Create a security group for the ALB

      ```bash
      ALB_SG=$(aws ec2 create-security-group \
        --group-name grpc-alb-sg \
        --description "Security group for gRPC ALB" \
        --vpc-id $VPC_ID \
        --region $REGION \
        --query 'GroupId' \
        --output text)
      
      # Allow HTTPS from anywhere
      aws ec2 authorize-security-group-ingress \
        --group-id $ALB_SG \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region $REGION
      ```

1. Create the Application Load Balancer

     ```bash
     # Get public subnet IDs as an array.
     # Ensure this returns at least 2 subnets in different Availability Zones.
     PUBLIC_SUBNETS=($(aws ec2 describe-subnets \
       --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*public*" \
       --query 'Subnets[*].SubnetId' \
       --output text \
       --region "$REGION"))
   
     echo "Public subnets:"
     printf '  %s\n' "${PUBLIC_SUBNETS[@]}"
   
     # Create the Application Load Balancer
     ALB_ARN=$(aws elbv2 create-load-balancer \
       --name grpc-alb \
       --subnets "${PUBLIC_SUBNETS[@]}" \
       --security-groups "$ALB_SG" \
       --scheme internet-facing \
       --type application \
       --ip-address-type ipv4 \
       --region "$REGION" \
       --query 'LoadBalancers[0].LoadBalancerArn' \
       --output text)
   
     echo "ALB ARN: $ALB_ARN"
   
     # Get ALB DNS name
     ALB_DNS=$(aws elbv2 describe-load-balancers \
       --load-balancer-arns "$ALB_ARN" \
       --region "$REGION" \
       --query 'LoadBalancers[0].DNSName' \
       --output text)
   
     echo "ALB DNS: $ALB_DNS"
     ```
 
1. Create the gRPC target group with IP targets

   **This is the key configuration**: Use `--target-type ip` and `--protocol-version GRPC`:

   ```bash
   TG_ARN=$(aws elbv2 create-target-group \
     --name grpc-tg \
     --protocol HTTPS \
     --port 443 \
     --protocol-version GRPC \
     --target-type ip \
     --vpc-id $VPC_ID \
     --health-check-protocol HTTPS \
     --health-check-port traffic-port \
     --health-check-path /grpc.health.v1.Health/Check \
     --health-check-interval-seconds 30 \
     --healthy-threshold-count 2 \
     --unhealthy-threshold-count 2 \
     --matcher GrpcCode=0-99 \
     --region $REGION \
     --query 'TargetGroups[0].TargetGroupArn' \
     --output text)
   
   echo "Target Group ARN: $TG_ARN"
   ```

   **Why this works**: 
   - Using `--target-type ip` allows AWS to accept `GRPC` as the protocol version. If you use `--target-type alb` or target an NLB by ARN, AWS forces HTTP2 protocol, which causes protocol mismatch errors.
   - The `GrpcCode=0-99` matcher accepts any valid gRPC status code (0-99). Using `GrpcCode=0` (only OK/SERVING) may cause health check failures if the backend returns other codes during startup or under certain conditions. The permissive matcher is recommended for production reliability.

1. Register the Istio NLB IP addresses as targets

      ```bash
      # Convert the NLB IPs to target format and register them as a single command.
      # Each IP must be passed as a separate --targets argument.
      TARGET_ARGS=()
  
      for ip in "${NLB_IPS[@]}"; do
        TARGET_ARGS+=("Id=$ip,Port=443")
      done
  
      echo "Registering targets:"
      printf '  %s\n' "${TARGET_ARGS[@]}"
  
      aws elbv2 register-targets \
        --target-group-arn "$TG_ARN" \
        --targets "${TARGET_ARGS[@]}" \
        --region "$REGION"
  
      echo "Registered NLB IPs as targets"
      ```
   
   **Note**: Register all NLB IPs in a single command so the target group health state converges consistently. Passing each target as a separate array element also avoids shell word-splitting issues in zsh.

1. Create HTTPS listener on the ALB

   ```bash
   LISTENER_ARN=$(aws elbv2 create-listener \
     --load-balancer-arn $ALB_ARN \
     --protocol HTTPS \
     --port 443 \
     --certificates CertificateArn=$CERT_ARN \
     --default-actions Type=forward,TargetGroupArn=$TG_ARN \
     --region $REGION \
     --query 'Listeners[0].ListenerArn' \
     --output text)
   
   echo "Listener ARN: $LISTENER_ARN"
   ```

1. Wait for targets to become healthy

   ```bash
   echo "Waiting for targets to become healthy..."
   while true; do
     HEALTHY_COUNT=$(aws elbv2 describe-target-health \
       --target-group-arn $TG_ARN \
       --region $REGION \
       --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
       --output text)
     
     echo "$(date +%H:%M:%S) - Healthy targets: $HEALTHY_COUNT / 3"
     
     if [ "$HEALTHY_COUNT" -ge "2" ]; then
       echo "✓ Targets are healthy"
       break
     fi
     sleep 10
   done
   ```

   You should see all three targets become healthy. If they remain unhealthy, check:
   - Istio Gateway has the TLS certificate secret configured
   - VirtualService routes exist for the health check path
   - Security groups allow traffic between ALB and NLB IPs

## Configure DNS

1. Create or find the hosted zone for your domain

     ```bash
     # Check if hosted zone already exists
     HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
       --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
       --output text | cut -d'/' -f3)
     
      if [ -z "$HOSTED_ZONE_ID" ]; then
        echo "Creating hosted zone for domain: $ROUTE53_ZONE_DOMAIN"
        HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
          --name "$ROUTE53_ZONE_DOMAIN" \
          --caller-reference $(date +%s) \
          --query 'HostedZone.Id' \
          --output text | cut -d'/' -f3)
       
       echo "Created hosted zone: $HOSTED_ZONE_ID"
       
       # Get the name servers for delegation
       echo ""
       echo "Name servers for this hosted zone:"
       aws route53 get-hosted-zone \
         --id $HOSTED_ZONE_ID \
         --query 'DelegationSet.NameServers' \
         --output table
       
       echo ""
       echo "If this is a subdomain, you need to create NS records in the parent domain."
       echo "Example: If your domain is 'test.example.com' and parent is 'example.com',"
       echo "create NS records in 'example.com' pointing to the name servers above."
     else
       echo "Using existing hosted zone: $HOSTED_ZONE_ID for domain: $DOMAIN"
     fi
     ```

1. Create a DNS record pointing to your ALB

    ```bash
    cat <<EOF > /tmp/dns-record.json
    {
      "Changes": [
        {
          "Action": "UPSERT",
          "ResourceRecordSet": {
            "Name": "$GRPC_HOSTNAME",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [
              {
                "Value": "$ALB_DNS"
              }
            ]
          }
        }
      ]
    }
    EOF
    
    aws route53 change-resource-record-sets \
      --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch file:///tmp/dns-record.json
    ```
    
    Wait for DNS propagation:
    
    ```bash
    sleep 30
    nslookup $GRPC_HOSTNAME
    ```
    
## Test gRPC Connectivity

1. Create the gRPC health check proto definition

   ```bash
   cat <<'EOF' > /tmp/health.proto
   syntax = "proto3";
   
   package grpc.health.v1;
   
   message HealthCheckRequest {
     string service = 1;
   }
   
   message HealthCheckResponse {
     enum ServingStatus {
       UNKNOWN = 0;
       SERVING = 1;
       NOT_SERVING = 2;
       SERVICE_UNKNOWN = 3;
     }
     ServingStatus status = 1;
   }
   
   service Health {
     rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
     rpc Watch(HealthCheckRequest) returns (stream HealthCheckResponse);
   }
   EOF
   ```

1. Test with grpcurl

   ```bash
   grpcurl -import-path /tmp -proto health.proto -d '{"service":""}' $GRPC_HOSTNAME:443 grpc.health.v1.Health/Check
   ```

   Expected output:
   ```
   {
     "status": "SERVING"
   }
   ```
   
   **Note**: The `-insecure` flag is not needed when using a valid ACM certificate. Use `-d '{"service":""}'` to pass an empty service name to the health check.

  For additional validation, run the command with `-v` to confirm that the response is handled as gRPC traffic through Envoy:

  ```bash
  grpcurl -v \
    -import-path /tmp \
    -proto health.proto \
    -d '{"service":""}' \
    "$GRPC_HOSTNAME:443" \
    grpc.health.v1.Health/Check
  ```

  Expected indicators:

  ```text
  Response headers received:
  content-type: application/grpc
  server: istio-envoy

  Response contents:
  {
    "status": "SERVING"
  }
  ```

This confirms that traffic reaches the public ALB, is forwarded through the gRPC target group to the private Istio NLB IP targets, and is served by the Istio Envoy ingress gateway.

## Add AWS WAF (Optional)

Now that gRPC is working, you can add WAF protection:

1. Create a WAF Web ACL

   ```bash
   WAF_ARN=$(aws wafv2 create-web-acl \
     --name grpc-waf \
     --scope REGIONAL \
     --region $REGION \
     --default-action Allow={} \
     --rules '[
       {
         "Name": "RateLimitRule",
         "Priority": 1,
         "Statement": {
           "RateBasedStatement": {
             "Limit": 2000,
             "AggregateKeyType": "IP"
           }
         },
         "Action": {
           "Block": {}
         },
         "VisibilityConfig": {
           "SampledRequestsEnabled": true,
           "CloudWatchMetricsEnabled": true,
           "MetricName": "RateLimitRule"
         }
       }
     ]' \
     --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=grpcWAF \
     --query 'Summary.ARN' \
     --output text)
   ```

1. Associate WAF with ALB

   **Note**: Wait 30-60 seconds after creating the WAF before associating it. AWS WAFv2 may return `WAFUnavailableEntityException` if the services haven't fully synchronized.

   ```bash
   # Wait for WAF to be ready
   echo "Waiting for WAF to be fully available..."
   sleep 30
   
   # Associate WAF with ALB (retry if needed)
   MAX_RETRIES=3
   RETRY_COUNT=0
   
   while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
     if aws wafv2 associate-web-acl \
       --web-acl-arn $WAF_ARN \
       --resource-arn $ALB_ARN \
       --region $REGION 2>&1; then
       echo "✓ WAF successfully associated with ALB"
       break
     else
       RETRY_COUNT=$((RETRY_COUNT + 1))
       if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
         echo "Retry $RETRY_COUNT/$MAX_RETRIES: Waiting 30 seconds..."
         sleep 30
       else
         echo "Failed to associate WAF after $MAX_RETRIES attempts"
         exit 1
       fi
     fi
   done
   ```

1. Verify WAF is attached

   ```bash
   WAF_NAME=$(aws wafv2 get-web-acl-for-resource \
     --resource-arn $ALB_ARN \
     --region $REGION \
     --query 'WebACL.Name' \
     --output text)
   
   if [ -n "$WAF_NAME" ]; then
     echo "✓ WAF '$WAF_NAME' is successfully attached to ALB"
   else
     echo "✗ No WAF found attached to ALB"
     exit 1
   fi
   ```

1. Test that gRPC still works with WAF enabled

   ```bash
   grpcurl -import-path /tmp -proto health.proto -d '{"service":""}' $GRPC_HOSTNAME:443 grpc.health.v1.Health/Check
   ```
   
   You should still receive `{"status": "SERVING"}`, confirming WAF is not blocking legitimate gRPC traffic.

   And run another validation test:

    ```bash
    aws elbv2 describe-target-health \
      --target-group-arn "$TG_ARN" \
      --region "$REGION" \
      --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State]' \
      --output table
  
    aws wafv2 get-web-acl-for-resource \
      --resource-arn "$ALB_ARN" \
      --region "$REGION" \
      --query 'WebACL.{Name:Name,ARN:ARN}' \
      --output table
    ```

  Expected output:

  ```text
  ------------------------------------
  |       DescribeTargetHealth       |
  +---------------+------+-----------+
  |  10.10.46.176 |  443 |  healthy  |
  |  10.10.31.253 |  443 |  healthy  |
  |  10.10.9.236  |  443 |  healthy  |
  +---------------+------+-----------+
  
  WebACL:
  Name: grpc-waf
  ```

## Verification Checklist

Run this comprehensive verification script to confirm your deployment is working correctly:

```bash
cat > /tmp/verify-grpc.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "gRPC on ROSA - Verification Checklist"
echo "=========================================="
echo ""

# 1. Check ALB target health
echo "Checking ALB target health..."
HEALTHY_COUNT=$(aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --region $REGION \
  --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
  --output text)

if [ "$HEALTHY_COUNT" -ge "2" ]; then
  echo "  ✓ $HEALTHY_COUNT healthy targets found"
else
  echo "  ✗ Only $HEALTHY_COUNT healthy targets (need at least 2)"
  exit 1
fi

# 2. Test gRPC health check
echo ""
echo "Testing gRPC health check..."
GRPC_RESPONSE=$(grpcurl -proto /tmp/health.proto -import-path /tmp \
  -d '{"service":""}' \
  ${GRPC_HOSTNAME:-$ALB_DNS}:443 \
  grpc.health.v1.Health/Check 2>&1)

if echo "$GRPC_RESPONSE" | grep -q "SERVING"; then
  echo "  ✓ gRPC health check returned SERVING"
else
  echo "  ✗ gRPC health check failed"
  echo "  Response: $GRPC_RESPONSE"
  exit 1
fi

# 3. Check response headers
echo ""
echo "Verifying gRPC headers..."
HEADERS=$(grpcurl -v -proto /tmp/health.proto -import-path /tmp \
  -d '{"service":""}' \
  ${GRPC_HOSTNAME:-$ALB_DNS}:443 \
  grpc.health.v1.Health/Check 2>&1)

if echo "$HEADERS" | grep -q "content-type: application/grpc"; then
  echo "  ✓ Response includes content-type: application/grpc"
else
  echo "  ✗ Missing application/grpc content-type"
fi

if echo "$HEADERS" | grep -q "grpc-status: 0"; then
  echo "  ✓ Response includes grpc-status: 0 (OK)"
else
  echo "  ✗ Missing grpc-status: 0"
fi

# 4. Check WAF association
if [ -n "$WAF_ARN" ]; then
  echo ""
  echo "Checking WAF association..."
  WAF_NAME=$(aws wafv2 get-web-acl-for-resource \
    --resource-arn $ALB_ARN \
    --region $REGION \
    --query 'WebACL.Name' \
    --output text 2>/dev/null)
  
  if [ -n "$WAF_NAME" ]; then
    echo "  ✓ WAF ${WAF_NAME} is attached to ALB"
  else
    echo "  ⚠ No WAF attached (optional)"
  fi
fi

# 5. Check Istio gateway pods
echo ""
echo "Checking Istio ingress gateway pods..."
POD_COUNT=$(oc get pods -n istio-system -l app=istio-ingressgateway \
  --field-selector=status.phase=Running \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$POD_COUNT" -ge "1" ]; then
  echo "  ✓ $POD_COUNT ingress gateway pod(s) running"
else
  echo "  ✗ No ingress gateway pods running"
  exit 1
fi

echo ""
echo "=========================================="
echo "✓ All checks passed!"
echo "=========================================="
echo ""
echo "Your gRPC on ROSA deployment is fully functional."
EOF

chmod +x /tmp/verify-grpc.sh
/tmp/verify-grpc.sh
```

This creates the script in a file first using a heredoc, then executes it. This avoids quote escaping issues when copy-pasting.

## Architecture Deep Dive

### Why IP Targets Enable gRPC Protocol

When you create an ALB target group, the combination of target type and protocol version determines what AWS allows:

| Target Type | Allowed Protocol Versions |
|-------------|--------------------------|
| instance    | HTTP1, HTTP2             |
| ip          | HTTP1, HTTP2, **GRPC**   |
| alb         | HTTP1, HTTP2             |
| lambda      | (not applicable)         |

By using `--target-type ip`, we unlock the ability to set `--protocol-version GRPC`, which tells ALB to:
- Preserve gRPC-specific headers (`content-type: application/grpc`)
- Handle HTTP/2 trailers correctly
- Support bidirectional streaming
- Properly route health checks as gRPC calls

### Traffic Flow

1. **Client → ALB**:
   - TLS connection (certificate from ACM)
   - ALPN negotiates HTTP/2
   - Client sends gRPC request

2. **ALB → Istio NLB IPs**:
   - ALB terminates client TLS
   - ALB re-encrypts with target TLS
   - Forwards to registered IP targets (10.40.x.x:443)
   - Preserves gRPC protocol characteristics

3. **NLB → Envoy**:
   - NLB operates at Layer 4 (TCP passthrough)
   - Forwards encrypted traffic to Envoy pods

4. **Envoy → Application**:
   - Envoy terminates TLS (using istio-ingressgateway-certs)
   - Istio Gateway and VirtualService route the request
   - Forwards to application as plaintext gRPC

### Health Check Flow

ALB health checks follow the same path:
1. ALB sends: `HTTPS GET /grpc.health.v1.Health/Check` to NLB IPs
2. Envoy receives and routes via VirtualService
3. Application responds with gRPC status code
4. ALB checks if `grpc-status` matches GrpcCode matcher (0-99)
5. Target marked healthy if response is in range

## Troubleshooting

### Targets remain unhealthy

**Check target group configuration:** 

```bash
aws elbv2 describe-target-groups --target-group-arns $TG_ARN \
  --query 'TargetGroups[0].{ProtocolVersion:ProtocolVersion,HealthCheck:HealthCheckPath,Matcher:Matcher}'
```

Ensure:
- `ProtocolVersion: GRPC`
- `HealthCheckPath: /grpc.health.v1.Health/Check`
- `Matcher: {GrpcCode: "0-99"}`

**Check Istio configuration:**

```bash
# Verify Gateway has TLS certificate
oc get secret istio-ingressgateway-certs -n istio-system

# Verify VirtualService routes health check
oc get virtualservice -n grpc-demo -o yaml | grep -A 5 "grpc.health.v1.Health"

# Check istiod logs for certificate access errors
oc logs -n istio-system deployment/istiod --tail=50 | grep -i "unauthorized\|secret"
```

If you see errors like "attempted to access unauthorized certificates", ensure the RBAC Role and RoleBinding were created to allow the ingress gateway ServiceAccount to read secrets in the istio-system namespace.

**Check connectivity:**

```bash
# Test direct connection to NLB IP
curl -k --http2 -v https://10.40.x.x:443/grpc.health.v1.Health/Check
```

### gRPC calls timeout

**Verify DNS resolution:**

```bash
nslookup $GRPC_HOSTNAME
```

**Check ALB security group allows traffic:**

```bash
aws ec2 describe-security-groups --group-ids $ALB_SG \
  --query 'SecurityGroups[0].IpPermissions[?ToPort==`443`]'
```

**Check Envoy logs:**

```bash
oc logs -n istio-system -l istio=ingressgateway --tail=50
```

### HTTP 464 errors

This indicates protocol mismatch. Verify:
- Target group `ProtocolVersion` is set to `GRPC` (not HTTP2)
- Target type is `ip` (not `alb`)
- Istio Gateway protocol is `HTTPS` (not `GRPC`)

### WAF blocking legitimate traffic

Check WAF logs:

```bash
aws wafv2 get-sampled-requests \
  --web-acl-arn $WAF_ARN \
  --rule-metric-name RateLimitRule \
  --scope REGIONAL \
  --time-window StartTime=$(date -u -d '5 minutes ago' +%s),EndTime=$(date -u +%s) \
  --max-items 100
```

Adjust WAF rules as needed for your traffic patterns.

## Cleanup

To remove all resources created in this guide:

1. Disassociate and delete WAF (if configured)

   ```bash
    WAF_NAME=$(echo "$WAF_ARN" | awk -F'/' '{print $(NF-1)}')
    WAF_ID=$(echo "$WAF_ARN" | awk -F'/' '{print $NF}')

    WAF_LOCK_TOKEN=$(aws wafv2 get-web-acl \
      --name "$WAF_NAME" \
      --id "$WAF_ID" \
      --scope REGIONAL \
      --region "$REGION" \
      --query 'LockToken' \
      --output text)

    aws wafv2 disassociate-web-acl \
      --resource-arn "$ALB_ARN" \
      --region "$REGION"

    aws wafv2 delete-web-acl \
      --name "$WAF_NAME" \
      --id "$WAF_ID" \
      --scope REGIONAL \
      --lock-token "$WAF_LOCK_TOKEN" \
      --region "$REGION"
   ```

1. Delete DNS record

   ```bash
   cat <<EOF > /tmp/dns-delete.json
   {
     "Changes": [
       {
         "Action": "DELETE",
         "ResourceRecordSet": {
           "Name": "$GRPC_HOSTNAME",
           "Type": "CNAME",
           "TTL": 300,
           "ResourceRecords": [
             {
               "Value": "$ALB_DNS"
             }
           ]
         }
       }
     ]
   }
   EOF
   
   aws route53 change-resource-record-sets \
     --hosted-zone-id $HOSTED_ZONE_ID \
     --change-batch file:///tmp/dns-delete.json
   ```

1. Delete ALB and target group

   ```bash
   aws elbv2 delete-listener \
     --listener-arn "$LISTENER_ARN" \
     --region "$REGION"

   aws elbv2 delete-load-balancer \
     --load-balancer-arn "$ALB_ARN" \
     --region "$REGION"

   aws elbv2 wait load-balancers-deleted \
     --load-balancer-arns "$ALB_ARN" \
     --region "$REGION"

   aws elbv2 delete-target-group \
     --target-group-arn "$TG_ARN" \
     --region "$REGION"
    ```

1. Delete ACM certificate, if created by this guide

  ```bash
   aws acm delete-certificate \
     --certificate-arn "$CERT_ARN" \
     --region "$REGION"
  ```

1. Delete ACM validation CNAME record, if created by this guide

    ```bash
      cat <<EOF > /tmp/acm-validation-delete.json
      {
        "Changes": [
          {
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": "$VALIDATION_NAME",
              "Type": "CNAME",
              "TTL": 300,
              "ResourceRecords": [
                {
                  "Value": "$VALIDATION_VALUE"
                }
              ]
            }
          }
        ]
      }
      EOF

      aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file:///tmp/acm-validation-delete.json
    ```

    If Route 53 returns `InvalidChangeBatch` because the record was not found, the validation record was already removed or was created in a different hosted zone.

1. Delete security group

   ```bash
   aws ec2 delete-security-group --group-id $ALB_SG
   ```

1. Delete OpenShift resources

   ```bash
   oc delete namespace grpc-demo
   oc delete istio default
   oc delete istiocni default
   oc delete namespace istio-system
   oc delete namespace istio-cni
   ```

1. Uninstall Service Mesh 3 Operator (optional)

   ```bash
   oc delete subscription servicemeshoperator3 -n openshift-operators
   ```

## Critical Configuration Summary

This deployment requires several specific configurations that are **not obvious** and are critical for success:

### 1. Gateway Proxy Injection (Not Sidecar)

The ingress gateway deployment **must** use the `inject.istio.io/templates: gateway` annotation. Without this, pods will have sidecar proxies (2/2 containers) instead of gateway proxies and will not function as an ingress gateway.

### 2. RBAC for TLS Certificate Access

The ingress gateway pods use the `default` ServiceAccount and require explicit RBAC permissions to read TLS secrets. Without the Role and RoleBinding:
- istiod logs will show: `"attempted to access unauthorized certificates"`
- TLS handshake will fail
- Connection will reset
- ALB targets will remain unhealthy

### 3. Wildcard Host for Health Checks

Both the Gateway and VirtualService must include the wildcard host `"*"` in addition to the specific hostname. ALB health checks do not send SNI (Server Name Indication) or Host headers, so without the wildcard, health checks fail even though the configuration looks correct.

### 4. Port 8443 in Gateway Configuration

The Gateway `port.number` must be `8443` (the container port) not `443` (the service port). Using `443` causes routing failures.

### 5. GrpcCode=0-99 Health Check Matcher

Use `GrpcCode=0-99` instead of `GrpcCode=0` for production reliability. The permissive matcher accepts any valid gRPC status code, preventing health check failures during startup or when backends return non-zero status codes under normal operation.

### 6. WAF Association Timing

After creating a WAF Web ACL, wait 30-60 seconds before associating it with the ALB. Immediate association may fail with `WAFUnavailableEntityException` due to AWS service synchronization delays.

## Summary

This architecture provides a production-ready solution for deploying gRPC applications on ROSA HCP with full WAF protection in both AWS Commercial Cloud and AWS GovCloud environments. By using AWS ALB's native gRPC support (via IP target type and GRPC protocol version) combined with Istio Service Mesh's Envoy ingress, you get:

- ✅ Full gRPC protocol support (HTTP/2, trailers, bidirectional streaming)
- ✅ AWS WAF integration for Layer 7 security
- ✅ Healthy target status for proper monitoring
- ✅ AWS GovCloud and Commercial Cloud compatibility
- ✅ Enterprise support for all components

The key insight is that ALB's gRPC support requires IP-based targeting rather than NLB-to-NLB architecture, and Envoy provides the HTTP/2-aware ingress layer that traditional HAProxy-based routes cannot deliver. This universal approach works across all AWS environments, making it ideal for organizations operating in regulated industries that require GovCloud while also maintaining commercial cloud deployments.

**Note**: While this guide is specific to ROSA HCP, the architecture also works on ROSA Classic with identical Service Mesh 3 configuration.
