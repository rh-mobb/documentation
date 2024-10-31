---
date: '2024-10-30T0:00:00.0000'
title: Limit Egress with Google Secure Web Proxy
tags: ["OSD", "Google", "Secure Web Proxy", "GCP"]
authors:
  - Michael McNeill
---

In this guide, we will implement egress restrictions for OpenShift Dedicated by using Google's [Secure Web Proxy](https://cloud.google.com/security/products/secure-web-proxy). Secure Web Proxy is a cloud first service that helps you secure egress web traffic (HTTP/S). OpenShift Dedicated relies on egress being allowed to specific fully qualified domain names (FQDNs), not just IP addresses. Secure Web Proxy provides support for limiting egress web traffic to the FQDNs necessary for the external endpoints that OpenShift Dedicated relies on. 

{{% alert state="warning" %}}
The ability to restrict egress traffic using Google Secure Web Proxy requires a support exception to use this functionality. For additional assistance, please [open a support case](https://access.redhat.com/support/cases/#/case/new).
{{% /alert %}}

You can deploy Secure Web Proxy in multiple different modes, including explicit proxy routing, Private Service Connect service attachment mode, and Secure Web Proxy as next hop. In this guide, we will configure Secure Web Proxy as the next hop for routing in our network. This reduces the administrative overhead of configuring an explicit proxy variable for each source workload, and ensures that egress traffic to the internet can only flow via the Secure Web Proxy.

### Prerequisites

* Ensure that you have the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`) installed.
* Ensure that you have [`jq`](https://jqlang.github.io/jq/) installed.
* Ensure that you have the [OCM CLI](https://github.com/openshift-online/ocm-cli) installed.
* Ensure that you are logged in to the Google Cloud CLI and that you are in the correct project where you plan to deploy OpenShift Dedicated.
* Ensure that you are logged in to the OCM CLI and that you are in the correct Red Hat account where you plan to deploy OpenShift Dedicated. 
* Confirm that you have the minimum necessary permissions in Google Cloud as outlined in the [Secure Web Proxy documentation](https://cloud.google.com/secure-web-proxy/docs/roles-permissions). 
* Confirm you have the `networksecurity.googleapis.com`, `networkservices.googleapis.com`, and `gcloud services enable certificatemanager.googleapis.com` services enabled. To enable them, run the following command:
    ```bash
    gcloud services enable networksecurity.googleapis.com
    gcloud services enable networkservices.googleapis.com
    gcloud services enable certificatemanager.googleapis.com
    ```

### Environment

Prepare the environment variables:
```bash
export project_id=$(gcloud config list --format="value(core.project)")
export region=us-east1
export prefix=osd-swp
export cluster_name=cluster-demo
export scratch="/tmp/${prefix}/secure-web-proxy"
mkdir -p ${scratch}
echo "Project ID: ${project_id}, Region: ${region}, Prefix: ${prefix}, Cluster name: ${cluster_name}"
```

In this example, we will use us-east1 as the region to deploy into, we will prefix all of our resources with `osd-swp`, and our cluster will be called `cluster-demo`. Modify the parameters to meet your needs.

### Create the VPC and Subnets

Before we can deploy a Secure Web Proxy, we must first create a VPC and subnets that we will use for OpenShift Dedicated:
1. Create the VPC by running the following command:
    ```bash
    gcloud compute networks create ${prefix}-vpc --subnet-mode=custom
    ```
1. Create the worker, control plane, and Private Service Connect subnets by running the following commands:
    ```bash
    gcloud compute networks subnets create ${prefix}-worker \
        --range=10.0.2.0/23 \
        --network=${prefix}-vpc \
        --region=${region}
    gcloud compute networks subnets create ${prefix}-control-plane \
        --range=10.0.0.0/25 \
        --network=${prefix}-vpc \
        --region=${region}
    gcloud compute networks subnets create ${prefix}-psc \
        --network=${prefix}-vpc \
        --region=${region} \
        --stack-type=IPV4_ONLY \
        --range=10.0.0.128/29 \
        --purpose=PRIVATE_SERVICE_CONNECT
    ```
    In this example, we are using subnet ranges of `10.0.0.0/25` for the control plane subnet, `10.0.2.0/23` for the worker subnets, and `10.0.0.128/29` for the PSC subnet. Modify the parameters to meet your needs. Ensure these values are contained within the machine CIDR you set above.

1. Create the proxy-only subnet for the Secure Web Proxy by running the following command:
    ```bash
    gcloud compute networks subnets create ${prefix}-proxy \
        --range=10.0.4.0/23 \
        --network=${prefix}-vpc \
        --region=${region} \
        --purpose=REGIONAL_MANAGED_PROXY \
        --role=ACTIVE
    ```

    This subnet is used to provide a pool of IP addresses reserved for Secure Web Proxy. Google recommends a subnet size of /23, or 512 proxy-only addresses. The minimum subnet size supported is a /26, or 64 proxy-only addresses. In this example, we are using a subnet range of 10.0.4.0/23. These addresses are not required to be included in the Machine CIDR of the cluster when specified below.

### Create and configure the Secure Web Proxy

1. Create a Gateway Security Policy by running the following command:  
    ```bash
    cat > ${scratch}/policy.yaml << EOF
    description: Policy to allow required OpenShift Dedicated traffic
    name: projects/${project_id}/locations/${region}/gatewaySecurityPolicies/${prefix}-policy
    EOF
    ```

1. Import the Gateway Security Policy by running the following command:
    ```bash
    gcloud network-security gateway-security-policies import \
        ${prefix}-policy \
        --source=${scratch}/policy.yaml \
        --location=${region}
    ```

1. Create the URL list that includes the domains required for OpenShift Dedicated by running the following command:

    ```bash
    cat > ${scratch}/url-list.yaml << EOF
    name: projects/${project_id}/locations/${region}/urlLists/${prefix}-allowed-list
    values:
      - *.googleapis.com
      - accounts.google.com
      - http-inputs-osdsecuritylogs.splunkcloud.com
      - nosnch.in
      - api.deadmanssnitch.com
      - events.pagerduty.com
      - api.pagerduty.com
      - api.openshift.com
      - mirror.openshift.com
      - observatorium.api.openshift.com
      - observatorium-mst.api.openshift.com
      - console.redhat.com
      - infogw.api.openshift.com
      - api.access.redhat.com
      - cert-api.access.redhat.com
      - catalog.redhat.com
      - sso.redhat.com
      - registry.connect.redhat.com
      - registry.access.redhat.com
      - cdn01.quay.io
      - cdn02.quay.io
      - cdn03.quay.io
      - cdn04.quay.io
      - cdn05.quay.io
      - cdn06.quay.io
      - cdn.quay.io
      - quay.io
      - registry.redhat.io
      - quayio-production-s3.s3.amazonaws.com
    EOF
    ```

1. Import the URL list to be used in our Gateway Security Policy rules by running the following command:

    ```bash
    gcloud network-security url-lists import \
        ${prefix}-allowed-list \
        --location=${region} \
        --source=${scratch}/url-list.yaml
    ```

1. Create a Gateway Security Policy Rule that allows access to the URL list we imported previously by running the following command:

    ```bash
    cat > ${scratch}/rule.yaml << EOF
    name: projects/${project_id}/locations/${region}/gatewaySecurityPolicies/${prefix}-policy/rules/${prefix}-osd-required
    enabled: true
    priority: 1
    description: Allow required OpenShift Dedicated traffic
    basicProfile: ALLOW
    sessionMatcher: "inUrlList(host(), 'projects/${project_id}/locations/${region}/urlLists/${prefix}-allowed-list')"
    EOF
    ```

1. Import the Gateway Security Policy Rule by running the following command:

    ```bash
    gcloud network-security gateway-security-policies rules import \
        ${prefix}-osd-required \
        --source=${scratch}/rule.yaml \
        --location=${region} \
        --gateway-security-policy=${prefix}-policy
    ```

1. Create the Secure Web Proxy Gateway definition by running the following command:

    ```bash
    cat > ${scratch}/gateway.yaml << EOF
    name: projects/${project_id}/locations/${region}/gateways/${prefix}-gateway
    type: SECURE_WEB_GATEWAY
    ports: [80,443]
    routingMode: NEXT_HOP_ROUTING_MODE
    gatewaySecurityPolicy: projects/${project_id}/locations/${region}/gatewaySecurityPolicies/${prefix}-policy
    network: projects/${project_id}/global/networks/${prefix}-vpc
    subnetwork: projects/${project_id}/regions/${region}/subnetworks/${prefix}-worker
    EOF
    ```

1. Import the Secure Web Proxy Gateway definition by running the following command:

    ```bash
    gcloud network-services gateways import \
        ${prefix}-swp \
        --source=${scratch}/gateway.yaml \
        --location=${region}
    ```

### Deploy OpenShift Dedicated Cluster

Because we are unable to predict the unique ID of the cluster before it is created, we must create the cluster and then immediately add the necessary static route to the VPC. Failing to add the static immediately after you trigger the cluster deployment can result in a cluster deployment failure. 

1. Create the cluster following the [OpenShift Dedicated documentation](https://docs.openshift.com/dedicated/osd_install_access_delete_cluster/creating-a-gcp-cluster.html). An example command to install a WIF cluster using the OCM CLI is included below:
    ```bash
    ocm create cluster ${cluster_name} --subscription-type=marketplace-gcp --marketplace-gcp-terms=true --provider=gcp --ccs=true --wif-config=${prefix}-wif --version=4.17.2 --region=${region} --secure-boot-for-shielded-vms=true --compute-machine-type=n2-standard-4 --multi-az=true --control-plane-subnet=${prefix}-control-plane --compute-subnet=${prefix}-worker
    ```

1. Immediately after you create the cluster, run the following command to capture the network tags used on the cluster nodes:
    ```bash
    while ocm get cluster $(ocm list cluster -p cluster_name=${cluster_name} --columns ID --no-headers) | jq -re '.infra_id'; do
        export cluster_tag_prefix=$(ocm get cluster $(ocm list cluster -p cluster_name=${cluster_name} --columns ID --no-headers) | jq -r '.infra_id')
        break
    done
    ```

    This command may take a minute or two to complete, as the cluster's infrastructure ID needs to be provisioned for the next steps.


### Create Static Routes for Worker and Control Plane Subnets

1. Create the static routes necessary to route internet traffic to the Secure Web Proxy by running the following commands:
    ```bash
    gcloud compute routes create ${prefix}-control-plane-route \
        --network="projects/${project_id}/global/networks/${prefix}-vpc" \
        --next-hop-ilb=$(gcloud network-services gateways describe ${prefix}-swp --location=${region} --format json | jq -r '.addresses[0]') \
        --destination-range=0.0.0.0/0 \
        --priority=900 \
        --project=$project_id \
        --tags ${cluster_tag_prefix}-control-plane
    gcloud compute routes create ${prefix}-worker-route \
        --network="projects/${project_id}/global/networks/${prefix}-vpc" \
        --next-hop-ilb=$(gcloud network-services gateways describe ${prefix}-swp --location=${region} --format json | jq -r '.addresses[0]') \
        --destination-range=0.0.0.0/0 \
        --priority=900 \
        --project=$project_id \
        --tags ${cluster_tag_prefix}-worker
    ```