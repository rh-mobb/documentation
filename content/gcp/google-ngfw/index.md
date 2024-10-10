---
date: '2024-10-09T0:00:00.0000'
title: Limit Egress with Google Cloud NGFW Standard
tags: ["OSD", "Google", "NGFW", "GCP"]
authors:
  - Michael McNeill
---

In this guide, we will implement egress restrictions for OpenShift Dedicated by using Google's [Cloud Next Generation Firewall (NGFW) Standard](https://cloud.google.com/firewall/docs/about-firewalls). Cloud NGFW is a fully distributed firewall service that allows fully qualified domain name (FQDN) objects in firewall policy rules. This is necessary for many of the external endpoints that OpenShift Dedicated relies on. 

{{% alert state="warning" %}}
The ability to restrict egress traffic using a firewall or other network device is only supported with OpenShift Dedicated clusters deployed using Google Private Service Connect (not yet generally available). Clusters that do not use Google Private Service Connect require a support exception to use this functionality. For additional assistance, please [open a support case](https://access.redhat.com/support/cases/#/case/new).
{{% /alert %}}

### Prerequisites

* Ensure that you have the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`) installed.
* Ensure that you are logged in to the Google Cloud CLI and that you are in the correct project where you plan to deploy OpenShift Dedicated.
* Confirm that you have the minimum necessary permissions in Google Cloud, including:
    * Compute Network Admin
    * DNS Administrator
* Confirm you have the `networksecurity.googleapis.com`, `networkservices.googleapis.com`, and `servicenetworking.googleapis.com` services enabled. To enable them, run the following command:
    ```bash
    gcloud services enable networksecurity.googleapis.com
    gcloud services enable networkservices.googleapis.com
    gcloud services enable servicenetworking.googleapis.com
    ```

### Environment

Prepare the environment variables:
```bash
export project_id=$(gcloud config list --format="value(core.project)")
export region=us-east1
export prefix=osd-ngfw
export service_cidr="172.30.0.0/16"
export machine_cidr="10.0.0.0/22"
export pod_cidr="10.128.0.0/14"
```

In this example, we will use us-east1 as the region to deploy into and we will prefix all of our resources with `osd-ngfw`. We will use the default CIDR ranges for the service and pod networks, and will configure our machine CIDR to be based on our subnet ranges we set below. Modify the parameters to meet your needs.

### Create the VPC and Subnets

Before we can deploy a Cloud NGFW, we must first create a VPC and subnets that we will use for OpenShift Dedicated:
1. Create the VPC by running the following command:
    ```bash
    gcloud compute networks create ${prefix}-vpc --subnet-mode=custom
    ```
1. Create the worker, control plane, and Private Service Connect subnets by running the following commands:
    ```bash
    gcloud compute networks subnets create ${prefix}-worker \
        --range=10.0.1.0/23 \
        --network=${prefix}-vpc \
        --region=${region} \
        --enable-private-ip-google-access
    gcloud compute networks subnets create ${prefix}-control-plane \
        --range=10.0.0.0/23 \
        --network=${prefix}-vpc \
        --region=${region} \
        --enable-private-ip-google-access
    gcloud compute networks subnets create ${prefix}-psc \
        --network=${prefix}-vpc \
        --region=${region} \
        --stack-type=IPV4_ONLY \
        --range=10.0.2.0/29 \
        --purpose=PRIVATE_SERVICE_CONNECT
    ```
    In this example, we are using subnet ranges of `10.0.0.0/23` for the control plane subnet, `10.0.1.0/23` for the worker subnets, and `10.0.2.0/29` for the PSC subnet. Modify the parameters to meet your needs. Ensure these values are contained within the machine CIDR you set above.

### Deploy a global network firewall policy

1. Create a global network firewall policy by running the following command:
    ```bash
    gcloud compute network-firewall-policies create \
        ${prefix} \
        --description "OpenShift Dedicated Egress Firewall" \
        --global
    ```

1. Associate the newly created global network firewall policy to your VPC you created above by running the following command:
    ```bash
    gcloud compute network-firewall-policies associations create \
        --firewall-policy ${prefix} \
        --network ${prefix}-vpc \
        --global-firewall-policy
    ```

### Create a Cloud NAT and Cloud Router Instance

1. Reserve an IP address for Cloud NAT by running the following command:
    ```bash
    gcloud compute addresses create ${prefix}-${region}-cloudnatip \
        --region=${region}        
    ```

1. Store the IP address you created above in a variable by running the following command:
    ```bash
    export cloudnatip=$(gcloud compute addresses list --filter=name:${prefix}-${region}-cloudnatip --format="value(address)")
    ```

1. Create a Cloud Router by running the following command:
    ```bash
    gcloud compute routers create ${prefix}-router \
        --region=${region} \
        --network=${prefix}-vpc
    ```

1. Create a Cloud NAT by running the following command:
    ```bash
    gcloud compute routers nats create ${prefix}-cloudnat-${region} \
        --router=${prefix}-router --router-region ${region} \
        --nat-all-subnet-ip-ranges \
        --nat-external-ip-pool=${prefix}-${region}-cloudnatip
    ```

### Create private DNS records for Google Private Access

1. Create a private DNS zone for the `googleapis.com` domain by running the following command:
    ```bash
    gcloud dns managed-zones create ${prefix}-googleapis \
        --visibility=private \
        --networks=https://www.googleapis.com/compute/v1/projects/${project_id}/global/networks/${prefix}-vpc \
        --description="Private Google Access" \
        --dns-name=googleapis.com
    ```

1. Begin a record set transaction by running the following command:
    ```bash
    gcloud dns record-sets transaction start \
        --zone=${prefix}-googleapis
    ```

1. Stage the DNS records for Google APIs under the googleapis.com domain by running the following command:
    ```bash
    gcloud dns record-sets transaction add --name="serviceusage.googleapis.com." \
        --type=CNAME private.googleapis.com. \
        --zone=${prefix}-googleapis \
        --ttl=300
    gcloud dns record-sets transaction add 199.36.153.8 199.36.153.9 199.36.153.10 199.36.153.11 \
        --name=private.googleapis.com. \
        --type=A \
        --zone=${prefix}-googleapis \
        --ttl=300
    gcloud dns record-sets transaction add --name=".googleapis.com." \
        --type=CNAME restricted.googleapis.com. \
        --zone=${prefix}-googleapis \
        --ttl=300
    gcloud dns record-sets transaction add 199.36.153.4 199.36.153.5 199.36.153.6 199.36.153.7 \
        --name=restricted.googleapis.com. \
        --type=A \
        --zone=${prefix}-googleapis \
        --ttl=300
    ```
    {{% alert state="info" %}}
    OpenShift Dedicated relies on the Service Usage API (`serviceusage.googleapis.com`) which is [not provided by the Google Private Access restricted VIP](https://cloud.google.com/vpc-service-controls/docs/restricted-vip-services). To circumvent this, we expose the Service Usage API using the [Google Private Access private VIP](https://cloud.google.com/vpc/docs/configure-private-google-access#domain-options). This is the only service exposed by the Google Private Access private VIP in this tutorial. 
    {{% /alert %}}

1. Apply the staged record set transaction you started above by running the following command:
    ```bash
    gcloud dns record-sets transaction execute \
        --zone=$prefix-googleapis
    ```

### Create the Firewall Rules

1. Create a blanket allow rule for east/west and intra-cluster traffic by running the following command:
    ```bash
    gcloud compute network-firewall-policies rules create 500 \
        --description "Allow east/west and intra-cluster connectivity" \
        --action=allow \
        --firewall-policy=${prefix} \
        --global-firewall-policy \
        --direction=EGRESS \
        --layer4-configs all \
        --dest-ip-ranges=${service_cidr},${machine_cidr},${pod_cidr}
    ```

1. Create an allow rule for HTTPS (`tcp/443`) domains required for OpenShift Dedicated by running the following command:
    ```bash
    gcloud compute network-firewall-policies rules create 600 \
        --description "Allow egress to OpenShift Dedicated required domains (tcp/443)" \
        --action=allow \
        --firewall-policy=${prefix} \
        --global-firewall-policy \
        --direction=EGRESS \
        --layer4-configs tcp:443 \
        --dest-fqdns accounts.google.com,pull.q1w2.quay.rhcloud.com,http-inputs-osdsecuritylogs.splunkcloud.com,nosnch.in,api.deadmanssnitch.com,events.pagerduty.com,api.pagerduty.com,api.openshift.com,mirror.openshift.com,observatorium.api.openshift.com,observatorium-mst.api.openshift.com,console.redhat.com,infogw.api.openshift.com,api.access.redhat.com,cert-api.access.redhat.com,catalog.redhat.com,sso.redhat.com,registry.connect.redhat.com,registry.access.redhat.com,cdn01.quay.io,cdn02.quay.io,cdn03.quay.io,cdn04.quay.io,cdn05.quay.io,cdn06.quay.io,cdn.quay.io,quay.io,registry.redhat.io,quayio-production-s3.s3.amazonaws.com
    ```
    > These domains are sourced from internal documentation. These domains will be published in general documentation when the Private Service Connect feature is released. 

1. Create an allow rule for TCP (`tcp/9997`) domains required for OpenShift Dedicated by running the following command:
    ```bash
    gcloud compute network-firewall-policies rules create 601 \
        --description "Allow egress to OpenShift Dedicated required domains (tcp/9997)" \
        --action=allow \
        --firewall-policy=${prefix} \
        --global-firewall-policy \
        --direction=EGRESS \
        --layer4-configs tcp:9997 \
        --dest-fqdns inputs1.osdsecuritylogs.splunkcloud.com,inputs2.osdsecuritylogs.splunkcloud.com,inputs4.osdsecuritylogs.splunkcloud.com,inputs5.osdsecuritylogs.splunkcloud.com,inputs6.osdsecuritylogs.splunkcloud.com,inputs7.osdsecuritylogs.splunkcloud.com,inputs8.osdsecuritylogs.splunkcloud.com,inputs9.osdsecuritylogs.splunkcloud.com,inputs10.osdsecuritylogs.splunkcloud.com,inputs11.osdsecuritylogs.splunkcloud.com,inputs12.osdsecuritylogs.splunkcloud.com,inputs13.osdsecuritylogs.splunkcloud.com,inputs14.osdsecuritylogs.splunkcloud.com,inputs15.osdsecuritylogs.splunkcloud.com
    ```
    > These domains are sourced from internal documentation. These domains will be published in general documentation when the Private Service Connect feature is released. 

1. Create an allow rule for Google Private Access endpoints by running the following command:
    ```bash
    gcloud compute network-firewall-policies rules create 602 \
        --description "Allow egress to Google APIs via Private Google Access" \
        --action=allow \
        --firewall-policy=$prefix \
        --global-firewall-policy \
        --direction=EGRESS \
        --layer4-configs tcp:443 \
        --dest-ip-ranges=199.36.153.8/30,199.36.153.4/30,34.126.0.0/18
    ```

1. Create a blanket deny rule by running the following command:
    ```bash
    gcloud compute network-firewall-policies rules create 1000 \
        --description "Deny all egress to the internet" \
        --action=deny \
        --firewall-policy=${prefix} \
        --global-firewall-policy \
        --direction=EGRESS \
        --enable-logging \
        --layer4-configs=all \
        --dest-ip-ranges=0.0.0.0/0 
    ```

You are now ready to deploy your cluster following the [OpenShift Dedicated documentation](https://docs.openshift.com/dedicated/osd_install_access_delete_cluster/creating-a-gcp-cluster.html).