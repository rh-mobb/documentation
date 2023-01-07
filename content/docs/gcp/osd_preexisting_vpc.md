---
date: '2022-09-14T22:07:08.594151'
title: Creating a OSD in GCP with Existing VPCs
aliases: ['/docs/gcp/osd_preexisting_vpc.md']
tags: ["GCP", "OSD"]
---

**Roberto Carratalá, Andrea Bozzoni**

*Last updated 07/06/2022*

> **Tip** The official documentation for installing a OSD cluster in GCP can be found [here](https://docs.openshift.com/dedicated/osd_cluster_create/creating-a-gcp-cluster.html).

For deploy an OSD cluster in GCP using existing Virtual Private Cloud (VPC) you need to implement some prerequisites that you must create before starting the OpenShift Dedicated installation though the OCM.

## Prerequisites

* [gcloud CLI](https://cloud.google.com/sdk/gcloud)
* [jq](https://stedolan.github.io/jq/download/)

NOTE: Also the GCloud Shell can be used, and have the gcloud cli among other tools preinstalled.

## Generate GCP VPC and Subnets
This is a diagram showing the GCP infra prerequisites that are needed for the OSD installation:

![GCP Prereqs](../images/osd-prereqs.png)

To deploy the GCP VPC and subnets among other prerequisites for install the OSD in GCP using the preexisting VPCs you have two options:

* **Option 1** - GCloud CLI
* **Option 2** - Terraform Automation

Please select one of these two options and proceed with the OSD install steps.

### Option 1 - Generate OSD VPC and Subnets using GCloud CLI

As mentioned before, for deploy OSD in GCP using existing GCP VPC, you need to provide and create beforehand a GCP VPC and two subnets (one for the masters and another for the workers nodes).

1. Login and configure the proper GCP project where the OSD will be deployed:

   ```sh
   export PROJECT_NAME=<google project name>
   gcloud auth list
   gcloud config set project $PROJECT_NAME
   gcloud config list project
   ```

2. Export the names of the vpc and subnets:

   ```sh
   export REGION=<region name>
   export OSD_VPC=<vpc name>
   export MASTER_SUBNET=<master subnet name>
   export WORKER_SUBNET=<worker subnet name>
   ```

3. Create a custom mode VPC network:

   ```sh
   gcloud compute networks create $OSD_VPC --subnet-mode=custom
   gcloud compute networks describe $OSD_VPC
   ```

NOTE: we need to create the mode custom for the VPC network, because the auto mode generates automatically the subnets with IPv4 ranges with [predetermined set of ranges](https://cloud.google.com/vpc/docs/subnets#ip-ranges).

4. This example is using the standard configuration for these two subnets:

   ```md
   master-subnet - CIDR 10.0.0.0/17   - Gateway 10.0.0.1
   worker-subnet - CIDR 10.0.128.0/17 - Gateway 10.0.128.1
   ```

5. Create the GCP Subnets for the masters and workers within the previous GCP VPC network:

   ```sh
   gcloud compute networks subnets create $MASTER_SUBNET \
   --network=$OSD_VPC --range=10.0.0.0/17 --region=$REGION

   gcloud compute networks subnets create $WORKER_SUBNET \
   --network=$OSD_VPC --range=10.0.128.0/17 --region=$REGION
   ```

   ![GCP VPC and Subnets](../images/osd-gcp1.png)

6. Once the VPC and the two subnets are provided it is needed to create one [GCP Cloud Router](https://cloud.google.com/network-connectivity/docs/router/how-to/create-router-vpc-on-premises-network):

   ```sh
   export OSD_ROUTER=<router name>

   gcloud compute routers create $OSD_ROUTER \
   --project=$PROJECT_NAME --network=$OSD_VPC --region=$REGION
   ```

   ![GCP Routers](../images/osd-gcp2.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="350" }

7. Then, we will deploy two [GCP Cloud NATs](https://cloud.google.com/nat/docs/set-up-manage-network-address-translation#gcloud) and attach them within the GCP Router:

    * Generate the GCP Cloud Nat for the Master Subnets:

    ```sh
    export NAT_MASTER=<master subnet name>

   gcloud compute routers nats create $NAT_MASTER \
   --region=$REGION                               \
   --router=$OSD_ROUTER                           \
   --auto-allocate-nat-external-ips               \
   --nat-custom-subnet-ip-ranges=$MASTER_SUBNET
    ```

   ![GCP Nat Master](../images/osd-gcp3.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="350" }

    * Generate the GCP Cloud NAT for the Worker Subnets:

    ```sh
    export NAT_WORKER=<worker subnet name>

   gcloud compute routers nats create $NAT_WORKER \
       --region=$REGION                           \
       --router=$OSD_ROUTER                       \
       --auto-allocate-nat-external-ips           \
       --nat-custom-subnet-ip-ranges=$WORKER_SUBNET
   ```

   ![GCP Nat Worker](../images/osd-gcp4.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="350" }

8. As you can check the Cloud NATs GW are attached now to the Cloud Router:

   ![GCP Nat Master](../images/osd-gcp5.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="350" }

### Option 2 - Deploy OSD VPC and Subnets using Terraform

You can use also [automation code in Terraform](https://github.com/rh-mobb/tf-osd-gcp) to deploy all the GCP infrastructure required to deploy the OSD in preexistent VPCs.

* Clone the tf-osd-gcp repository:

```bash
git clone https://github.com/rh-mobb/tf-osd-gcp.git
cd tf-osd-gcp
```

* Copy and modify the tfvars file in order to custom to your scenario:

```bash
cp -pr terraform.tfvars.example terraform.tfvars
```

* Deploy the network infrastructure in GCP needed for deploy the OSD cluster:

```bash
make all
```

## Install the OSD cluster using pre-existent VPCs

These steps are based in the [official OSD installation documentation](https://docs.openshift.com/dedicated/osd_install_access_delete_cluster/creating-a-gcp-cluster.html#osd-create-gcp-cluster-ccs_osd-creating-a-cluster-on-gcp).

1. Log in to OpenShift Cluster Manager and click Create cluster.

2. In the Cloud tab, click Create cluster in the Red Hat OpenShift Dedicated row.

3. Under Billing model, configure the subscription type and infrastructure type
![OSD Install](../images/osd-gcp6.png){:style="display:block; margin-left:auto; margin-right:auto"}

4. Select Run on Google Cloud Platform.

5. Click Prerequisites to review the prerequisites for installing OpenShift Dedicated on GCP with CCS.

6. Provide your GCP service account private key in JSON format. You can either click Browse to locate and attach a JSON file or add the details in the Service account JSON field.
![OSD Install](../images/osd-gcp7.png){:style="display:block; margin-left:auto; margin-right:auto"}

7. Validate your cloud provider account and then click Next.
On the Cluster details page, provide a name for your cluster and specify the cluster details:
![OSD Install](../images/osd-gcp8.png){:style="display:block; margin-left:auto; margin-right:auto"}

> NOTE: the Region used to be installed needs to be the same as the VPC and Subnets deployed in the early step.

8. On the Default machine pool page, select a Compute node instance type and a Compute node count:
![OSD Install](../images/osd-gcp9.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="600" }

9. In the Cluster privacy section, select **Public** endpoints and application routes for your cluster.

10. Select Install into an existing VPC to install the cluster in an existing GCP Virtual Private Cloud (VPC):
![OSD Install](../images/osd-gcp10.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="600" }

11. Provide your Virtual Private Cloud (VPC) subnet settings, that you deployed as prerequisites in the previous section:
![OSD Install](../images/osd-gcp11.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="600" }

12. In the CIDR ranges dialog, configure custom classless inter-domain routing (CIDR) ranges or use the defaults that are provided:
![OSD Install](../images/osd-gcp12.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="600" }

13. On the Cluster update strategy page, configure your update preferences.

14. Review the summary of your selections and click Create cluster to start the cluster installation. Check that the **Install into Existing VPC** is enabled and the VPC and Subnets are properly selected and defined:
![OSD Install](../images/osd-gcp13.png){:style="display:block; margin-left:auto; margin-right:auto"}{: width="600" }

## Cleanup

Deleting a ROSA cluster consists of two parts:

1. Deleting the OSD cluster can be done using the OCM console described in the [official OSD docs](https://docs.openshift.com/dedicated/osd_install_access_delete_cluster/creating-a-gcp-cluster.html).

2. Deleting the GCP infrastructure resources (VPC, Subnets, Cloud NAT, Cloud Router).
Depending of which option you selected you must perform:

3. **Option 1**: Delete GCP resources using GCloud CLI:

   ```sh
   gcloud compute routers nats delete $NAT_WORKER \
   --region=$REGION --router=$OSD_ROUTER --quiet

   gcloud compute routers nats delete $NAT_MASTER \
   --region=$REGION --router=$OSD_ROUTER --quiet

   gcloud compute routers delete $OSD_ROUTER --region=$REGION --quiet

   gcloud compute networks subnets delete $MASTER_SUBNET --region=$REGION --quiet
   gcloud compute networks subnets delete $WORKER_SUBNET --region=$REGION --quiet

   gcloud compute networks delete $OSD_VPC --quiet
   ```

4. **Option 2**: Delete GCP resources using Terraform:

   ```sh
   make destroy
   ```
