# Documentation from the MOBB/MOST team

## Quickstarts / Getting Started

* [Red Hat OpenShift on AWS (ROSA)](./docs/quickstart-rosa.md)
* [Azure Red Hat OpenShift (ARO)](./docs/quickstart-aro.md)

## Advanced Managed OpenShift

### ROSA

* [Deploying ROSA in Private Link mode](./docs/rosa/private-link)
  * [Add Public Ingress to Private Link Cluster](./docs/rosa/private-link/public-ingress)
* [Deploying ROSA in STS mode](./docs/rosa/sts)
* [Deploying ROSA in STS mode with Private Link](./docs/rosa/sts-with-private-link)
* [Deploying ROSA in STS mode with custom KMS Key](./docs/rosa/kms)
* [Installing the AWS Load Balancer Controller (ALB) on ROSA](./docs/rosa/alb-sts)
* [Adding AWS WAF in front of ROSA / OSD](./docs/aws/waf)
* [Use AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)
* [Use AWS CloudWatch Agent to push prometheus metrics to AWS CloudWatch](./docs/rosa/metrics-to-cloudwatch-agent)
* [Federating ROSA metrics to Prometheus with customer alerting](./docs/rosa/federated-metrics-prometheus)
* [Configuring Alerts for User Workloads in ROSA 4.9.x](./docs/rosa/custom-alertmanager)
* [Using Amazon Web Services Elastic File System (EFS) on ROSA](./docs/rosa/aws-efs-operator-on-rosa)
* [Using the AWS EFS CSI Driver Operator on ROSA 4.10.x](./docs/rosa/aws-efs-csi-operator-sts)
* [Configuring a ROSA cluster to pull images from AWS Elastic Container Registry (ECR)](./docs/rosa/ecr)
* [Configuring a ROSA cluster to use ECR secret operator](./docs/rosa/ecr-secret-operator)
* [Deploy and use the AWS Kubernetes Controller S3 controller](./docs/rosa/ack)

### ARO

* [Deploying private ARO Cluster with Jump Host access](./docs/aro/private-cluster)
  * [Using the Egressip Ipam Operator with a Private ARO Cluster](./docs/aro/egress-ipam-operator)
* [Considerations for Disaster Recovery with ARO](./docs/aro/disaster-recovery)
* [Getting Started with the Azure Key Vault CSI Driver](./docs/aro/key-vault-csi)
* [Deploy and use the Azure Service Operator V1(ASO)](./docs/aro/azure-service-operator-v1)
* [Deploy and use the Azure Service Operator V2(ASO)](./docs/aro/azure-service-operator-v2)
* [Create an additional Ingress Controller for ARO](./docs/aro/additional-ingress-controller)
* [Configure the Managed Upgrade Operator](./docs/aro/managed-upgrade-operator)
* [Configure ARO with Azure NetApp Trident Operator](./docs/aro/trident)
* [IBM Cloud Paks for Data Operator Setup](./docs/aro/ibm-cloud-paks-for-data)
* [Install ARO with Custom Domain using LetsEncrypt with cert manager](./docs/aro/cert-manager)
* [Configure ARO for Nvidia GPU Workloads](./docs/aro/gpu)
* [Configure ARO with Azure Front Door](./docs/aro/frontdoor)
* [Create a point to site VPN connection for an ARO Cluster](./docs/aro/vpn)
* [Configure access to ARO Image Registry](./docs/aro/registry)
* [Configure ARO with OpenShift Data Foundation](./docs/aro/odf)
* Setting Up Quay on an ARO Cluster using Azure Container Storage
  * [via CLI ](./docs/aro/setup-quay/quay-cli.md)
  * [via GUI ](./docs/aro/setup-quay/quay-console.md)
* [Configure ARO with Azure Policy](./docs/aro/azure-policy)
* [Create infrastructure nodes on an ARO Cluster](./docs/aro/add-infra-nodes)

### GCP

* [Deploy OSD in GCP using Pre-Existent VPC and Subnets](./docs/gcp/osd_preexisting_vpc.md)
* [Using Filestore with OpenShift Dedicated in GCP](./docs/gcp/filestore.md)

## Advanced Cluster Manager (ACM)

* [Deploy ACM Observability to a ROSA cluster](./docs/acm/observability/rosa)

## Observability

* [Configuring Alerts for User Workloads in ROSA 4.9.x](./docs/rosa/custom-alertmanager)
* [Federating ROSA metrics to S3](./docs/rosa/federated-metrics)
* [Federating ROSA metrics to Prometheus with customer alerting](./docs/rosa/federated-metrics-prometheus)
* [Federating ROSA metrics to AWS Prometheus](./docs/rosa/cluster-metrics-to-aws-prometheus)
* [Configure ROSA STS Cluster Logging to CloudWatch](./docs/rosa/clf-cloudwatch-sts)
* [Federating ARO metrics to Azure Files](./docs/aro/federated-metrics)
* [Sending ARO cluster logs to Azure Log Analytics](./docs/aro/clf-to-azure)
* [Use AWS CloudWatch Agent to push prometheus metrics to AWS CloudWatch](./docs/rosa/metrics-to-cloudwatch-agent)

## Security

### Kubernetes Secret Store CSI Driver

* [Just the CSI itself](./docs/security/secrets-store-csi)
  * [+ HashiCorp CSI](./docs/security/secrets-store-csi/hashicorp-vault)
  * [+ AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)
  * [+ Azure Key Vault CSI Driver](./docs/security/secrets-store-csi/azure-key-vault)

## Configuring Specific Identity Providers

* [Configure GitLab as an identity provider for ROSA/OSD](./docs/idp/gitlab)
* [Configure GitLab as an identity provider for ARO](./docs/idp/gitlab-aro)
* [Configure Azure AD as an identity provider for ARO](./docs/idp/azuread-aro)
* [Configure Azure AD as an identitiy provider for ARO with group claims](./docs/idp/group-claims/aro/)
* [Configure Azure AD as an identitiy provider for ROSA with group claims](./docs/idp/group-claims/rosa/)
* [Configure Azure AD as an identity provider for ROSA/OSD](./docs/idp//azuread)
* [Configure Azure AD as an identity provider for ARO via the CLI](./docs/idp//azuread-aro-cli)

## Configuring Group Synchronization

* [Using Group Sync Operator with Azure Active Directory and ROSA/OSD](./docs/idp/az-ad-grp-sync)
* [Using Group Sync Operator with Okta and ROSA/OSD](./docs/idp/okta-grp-sync)

### Deploying Advanced Security for Kubernetes in ROSA/ARO

* [Deploying ACS in ROSA/ARO](./docs/security/rhacs.md)

## Applications

* [Deploying Astronomer to OpenShift](./docs/aro/astronomer/)
* [Deploying 3scale API Management to ROSA/OSD](./docs/app-services/3scale)

## Ingress
* [Configure a custom ingress TLS profile for ROSA/OSD](./docs/ingress/tls-cipher-customization/)

## Data Science on Jupyter Notebook on OpenShift
* [Prerequistes and Concepts](./docs/jup/1-Prereq-concept.md)
  * [Build minimal notebook](./docs/jup/2-BuildNotebook.md)
  * [JupyterHub notebook with GPU](./docs/jup/3-OpenDataHub-GPU.md)

## Miscellaneous

* [Demonstrating GitOps - ArgoCD](./docs/demos/gitops/)
* [Migrate Kubernetes Applications with Konveyor Crane](./docs/demos/crane/)
* [Red Hat Cost Management for Cloud Services](./docs/misc/cost-management/)

## Fixes / Workarounds

**Here be dragons - use at your own risk**

* [Fix Cluster Logging Operator Addon for ROSA STS Clusters](./docs/rosa/sts-cluster-logging-addon)
* [Stop default router from serving custom domain routes](./docs/ingress/default-router-custom-domain/README.md)

