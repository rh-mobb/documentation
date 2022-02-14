# Documentation from the MOBB/MOST team

## Quickstarts / Getting Started

* [Red Hat OpenShift on AWS (ROSA)](./docs/quickstart-rosa.md)
* [Azure Red Hat OpenShift (ARO)](./docs/quickstart-aro.md)

## Advanced Managed OpenShift

### ROSA

* [Deploying ROSA in Private Link mode](./docs/rosa/private-link)
* [Deploying ROSA in STS mode](./docs/rosa/sts)
* [Deploying ROSA in STS mode with Private Link](./docs/rosa/sts-with-private-link)
* [Adding AWS WAF in front of ROSA / OSD](./docs/aws/waf)
* [Use AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)
* [Use AWS CloudWatch Agent to push prometheus metrics to AWS CloudWatch](./docs/rosa/metrics-to-cloudwatch-agent)
* [Federating ROSA metrics to Prometheus with customer alerting](./docs/rosa/federated-metrics-prometheus)
* [Configuring Alerts for User Workloads in ROSA 4.9.x](./docs/rosa/custom-alertmanager)
* [Using Amazon Web Services Elastic File System (EFS) on ROSA](./docs/rosa/aws-efs-operator-on-rosa)

### ARO

* [Deploying private ARO Cluster with Jump Host access](./docs/aro/private-cluster)
    * [Using the Egressip Ipam Operator with a Private ARO Cluster](./docs/aro/egress-ipam-operator)
* [Considerations for Disaster Recovery with ARO](./docs/aro/disaster-recovery)
* [Getting Started with the Azure Key Vault CSI Driver](./docs/aro/key-vault-csi)

## Advanced Cluster Manager (ACM)

* [Deploy ACM Observability to a ROSA cluster](./docs/acm/observability/rosa)

## Observability

* [Configuring Alerts for User Workloads in ROSA 4.9.x](./docs/rosa/custom-alertmanager)
* [Federating ROSA metrics to S3](./docs/rosa/federated-metrics)
* [Federating ROSA metrics to Prometheus with customer alerting](./docs/rosa/federated-metrics-prometheus)
* [Federating ROSA metrics to AWS Prometheus](./docs/rosa/cluster-metrics-to-aws-prometheus)
* [Federating ARO metrics to Azure Files](./docs/aro/federated-metrics)
* [Sending ARO cluster logs to Azure Log Analytics](./docs/aro/clf-to-azure)
* [Use AWS CloudWatch Agent to push prometheus metrics to AWS CloudWatch](./docs/rosa/metrics-to-cloudwatch-agent)

## Security

### Kubernetes Secret Store CSI Driver

* [Just the CSI itself](./docs/security/secrets-store-csi)
    * [+ HashiCorp CSI](./docs/security/secrets-store-csi/hashicorp-vault)
    * [+ AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)
    * [+ Azure Key Vault CSI Driver](./docs/security/secrets-store-csi/azure-key-vault)

### Configure Identity provider
* [OpenShift - Configuring Identity Providers](./docs/idp/README.md)

## Applications

* [Deploying Astronomer to OpenShift](./docs/aro/astronomer/)
* [Deploying 3scale API Management to ROSA/OSD](./docs/app-services/3scale)


## Operations - DevOps/GitOps

* [Demonstrating GitOps - ArgoCD](./docs/demos/gitops/)
* [Migrate Kubernetes Applications with Konveyer Crane](./docs/demos/crane/)

## Fixes / Workarounds

**Here be dragons - use at your own risk**

* [Fix Cluster Logging Operator Addon for ROSA STS Clusters](./docs/rosa/sts-cluster-logging-addon)
