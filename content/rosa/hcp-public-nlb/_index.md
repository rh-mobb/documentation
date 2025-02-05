---
date: '2025-02-05'
title: Accesing an private ROSA Hosted Control Plane(HCP) cluser with an AWS Network Load Balancer
tags: ["AWS", "ROSA"]
authors:
  - Nerav Doshi
  - Michael McNeill
---
## Overview

This document provides guidance on using a public AWS Network Load Balancer (NLB) to connect to a private ROSA (Red Hat OpenShift on AWS) Hosted Control Plane(HCP) cluster.  When the cluster itself is private and does not have direct public IP access, the NLB allows secure, reliable routing of traffic from public sources to the private cluster by exposing a stable endpoint while maintaining network isolation. It helps ensure that the private cluster can still handle external traffic, such as from APIs or services, without exposing sensitive internal infrastructure directly to the internet.

## Pre-requisites

1. You will need a A Private ROSA HCP Cluster (see [Deploying ROSA HCP with Terraform or ROSA CLI](https://docs.aws.amazon.com/rosa/latest/userguide/getting-started-hcp.html) if you need help creating one).  

2. In this example we will use Entra ID as external authentication for ROSA HCP cluster (see [Configuring Microsoft Entra ID as an external authentication provider](https://cloud.redhat.com/experts/rosa/entra-external-auth))


3. (Optional) Launch an Jump Host EC2 instance in Public NLB VPC
This guide requires connectivity to the cluster, because we are using a private cluster you will need to ensure your workstation is connected to the AWS VPC which hosts the ROSA cluster.   If you already have this connectivity through a VPN, Direct Link or other method you can skip this part.  

If you do need to establish connectivity to the cluster [these instructions](./rosa-private-nlb-jumphost) will guide you through creating a jump host on the public subnet of the ROSA cluster.

## Create security group, target group and network load balancer in AWS subscription

Once ROSA HCP cluster is installed with external authentication as Entra ID we need to set additional security group to grant access outside the VPC, create target group and NLB.

#### AWS security groups to the AWS PrivateLink endpoint

When using ROSA with HCP clusters, the AWS PrivateLink endpoint in your VPC is secured by a security group that only allows access from within the cluster's Machine CIDR range. To allow access from outside the VPC you need to create and attach an additional security group to the PrivateLink endpoint to grant the necessary external access. Refer to [ROSA documentation](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-aws-private-creating-cluster.html#rosa-hcp-aws-private-security-groups_rosa-hcp-aws-private-creating-cluster)

example output of AWS console :

![AWS Console Additional Security group](./images/aws-portal-sg-allow-access.png)

#### Create target group with VPC Endpoints as targets

Define the target group with list of VPC endpoints IP that an NLB can reach to based on configured rules and health checks; allowing for load balancing across multiple instances within a group.

Here’s a step-by-step guide for creating a target group in AWS for your network load balancer:

##### 1. **Create a Target Group**:
   - Navigate to the **Target Groups** section in the AWS console and click **Create target group**.
   - **Target type**: Select **IP addresses** if you're using IP-based routing (common for VPCEs or EC2 instances in private subnets).
   - **Protocol**: Choose **TLS** if you're securing communication.
   - **Port**: Set the **Port** to **443**, which is the standard port for secure HTTPS/TLS traffic.
   - **VPC**: Choose the **VPC** where your targets for ROSA HCP VPCEs are located.

##### 2. **Configure Health Checks**:
   - **Health check protocol**: Set to **TCP** to check if the backend targets are healthy and accepting connections.
   - **Health check port**: Set to **443**, matching the port your targets will use for traffic.
   - **Health check path**: Leave this field empty or set it to a specific path (e.g., `/health`) if you want to perform HTTP/HTTPS health checks.
   - Optionally adjust other health check settings (e.g., threshold, interval) based on your needs.

##### 3. **Add Targets**:
   - **IP addresses**: Enter the **IP addresses** of the targets that should be included in this target group. You might enter the IPs of VPCEs that you want the load balancer to route traffic to private HCP cluster.
   - Click **Include in pending below** to add these targets to the group.

##### 4. **Create the Target Group**:
   - After verifying all your settings, click **Create target group** to finish setting up your target group.

Once created, you can associate this target group with your NLB listener to route traffic to ROSA HCP cluster.

example output of AWS console :

![AWS Console Target Group](./images/aws-portal-targetgroup.png)

#### Create and configure the public NLB

Here’s a step-by-step guide for creating a Network Load Balancer (NLB) and configuring it with your domain:

##### 1. **Create the NLB:**
   - **Scheme**: Choose **Internet-facing**. This allows your NLB to be accessible from the internet.
   - **VPC**: Select the **VPC**. This can be 
   - **Security Groups**: Select a **security group** that permits access to your API from your IP address. This should be set up to allow inbound traffic on the port you’ll be using (usually port 443 for secure communication).

##### 2. **Configure Listeners and Routing:**
   - **Protocol**: Set the **Protocol** to **TLS**, as you are securing communication.
   - **Port**: Set the **Port** to **443**, the standard port for HTTPS traffic.
   - **Target Group**: Choose the **target group** you created previously. This will route the incoming traffic to the appropriate targets.

##### 3. **Secure Listener Settings** (Optional but recommended for HTTPS):
   - **Certificate (from ACM)**: 
     - Select or **create a new certificate** using AWS ACM (AWS Certificate Manager).
     - This certificate should be for the **domain name** you plan to use for your externally facing API. For example, if your API will be accessible at `api.example.com`, ensure the certificate matches that domain.

   - Leave other settings at their **default values** unless specific changes are needed.

##### 4. **Create the Load Balancer**: 
   - After all the settings are configured, click **Create load balancer** to finalize the setup of your Network Load Balancer.

##### 5. **Update Route 53**:
   - **Create a Record**: In **Amazon Route 53**, create a new DNS **record** pointing to the NLB's **DNS name**.
     - The record should match the **domain name** for which the ACM certificate was issued (e.g., `api.example.com`).
     - Use the **Alias** record type to point to the NLB. AWS provides the DNS name of your NLB, which you can directly map to the record.

This setup will ensure that traffic is routed securely from the internet to your API, leveraging the NLB to distribute traffic to your backend resources.

example output of AWS console :

![AWS Console NLB](./images/aws-portal-public-nlb.png)

#### Validate connection to NLB

Validate that you can access the NLB from your machine using **domain name**. For example 

```bash
curl https://api.example.com/version
```

example output:

```bash
[ec2-user@ipaddress ~]$ curl -v https://api.example.com/version
*   Trying 44.241.175.135:443...
* Connected to api.example.com (44.241.175.135) port 443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
*  CAfile: /etc/pki/tls/certs/ca-bundle.crt
* TLSv1.0 (OUT), TLS header, Certificate Status (22):
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.2 (IN), TLS header, Certificate Status (22):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.2 (IN), TLS header, Finished (20):
* TLSv1.2 (IN), TLS header, Unknown (23):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.2 (IN), TLS header, Unknown (23):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.2 (IN), TLS header, Unknown (23):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.2 (IN), TLS header, Unknown (23):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.2 (OUT), TLS header, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.2 (OUT), TLS header, Unknown (23):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256
* ALPN, server did not agree to a protocol
* Server certificate:
*  subject: CN=api.example.com
*  start date: Jan 27 00:00:00 2025 GMT
*  expire date: Feb 25 23:59:59 2026 GMT
*  subjectAltName: host "api.example.com" matched cert's "api.example.com"
*  issuer: C=US; O=Amazon; CN=Amazon RSA 2048 M03
*  SSL certificate verify ok.
* TLSv1.2 (OUT), TLS header, Unknown (23):
> GET /version HTTP/1.1
> Host: api.example.com
> User-Agent: curl/7.76.1
> Accept: */*
> 
* TLSv1.2 (IN), TLS header, Unknown (23):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.2 (IN), TLS header, Unknown (23):
* Mark bundle as not supporting multiuse
< HTTP/1.1 200 OK
< Audit-Id: 403d5313-4774-43a1-bdf6-d54ef2b4d48f
< Cache-Control: no-cache, private
< Content-Type: application/json
< Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
< X-Kubernetes-Pf-Flowschema-Uid: 22baa61b-d99d-42cc-9f6e-31fafb5fca8c
< X-Kubernetes-Pf-Prioritylevel-Uid: abc60498-d4a2-4242-b207-bd6f381c055c
< Date: Tue, 28 Jan 2025 21:40:58 GMT
< Content-Length: 293
< 
{
  "major": "1",
  "minor": "28",
  "gitVersion": "v1.28.15+ff493be",
  "gitCommit": "4cf5291f1e18d974b97cae658aa9b2654bd9ea29",
  "gitTreeState": "clean",
  "buildDate": "2024-11-23T03:11:13Z",
  "goVersion": "go1.20.12 X:strictfipsruntime",
  "compiler": "gc",
  "platform": "linux/amd64"
* Connection #0 to host api.example.com left intact
```

#### Validate connection to ROSA HCP cluster's API

create a KUBECONFIG file here with EntraID details for example create **rosa-auth.kubeconfig** file with following information

```bash
apiVersion: v1
clusters:
- cluster:
    server: ${domain.name}
  name: cluster
contexts:
- context:
    cluster: cluster
    namespace: default
    user: oidc
  name: admin
current-context: admin
kind: Config
preferences: {}
users:
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://login.microsoftonline.com/${TENANT_ID}/v2.0
      - --oidc-client-id=${CLIENT_ID}
      - --oidc-client-secret=${CLIENT_SECRET}
      - --oidc-extra-scope=email
      - --oidc-extra-scope=openid
      command: kubectl
      env: null
      interactiveMode: Never
```

Set the `KUBECONFIG` environment variable to the location of the `rosa-cluster.kubeconfig` file. This will configure the OpenShift CLI to authenticate against the ROSA cluster with the OIDC client.


```bash
export KUBECONFIG=$(pwd)/rosa-auth.kubeconfig
```

Confirm your access to the cluster by running the following command:

```bash
oc get nodes
```
example output:

```bash
NAME                         STATUS   ROLES    AGE     VERSION
ip-10-0-0-170.ec2.internal   Ready    worker   3h29m   v1.30.7
ip-10-0-1-171.ec2.internal   Ready    worker   3h30m   v1.30.7
ip-10-0-2-161.ec2.internal   Ready    worker   3h29m   v1.30.7
```
To verify you are logged in as user of the group, run the following command:

```bash
oc auth whoami
```
example output:
```bash
ATTRIBUTE   VALUE
Username    XXXXXXX@redhat.com
Groups      [0000000000000000 system:authenticated]
```
