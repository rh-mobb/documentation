# Documentation from the MOBB/MOST team

## Quickstarts / Getting Started

* [Red Hat OpenShift on AWS (ROSA)](./docs/quickstart-rosa.md)
* [Azure RedHat OpenShift (ARO)](./docs/quickstart-aro.md)

## Advanced Managed OpenShift

### ROSA

* [Deploying ROSA in Private Link mode](./docs/rosa/private-link)
* [Deploying ROSA in STS mode](./docs/rosa/sts)
* [Deploying ROSA in STS mode with Private Link](./docs/rosa/sts-with-private-link)
* [Adding AWS WAF in front of ROSA / OSD](./docs/aws/waf)
* [USE AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)

### ARO

* [Deploying private ARO Cluster with Jump Host access](./docs/aro/private-cluster)
    * [Using the Egressip Ipam Operator with a Private ARO Cluster](./docs/aro/egress-ipam-operator)
* [Considerations for Disaster Recovery with ARO](./docs/aro/disaster-recovery)
* [Getting Started with the Azure Key Vault CSI Driver](./docs/aro/key-vault-csi)

## Observability

* [Federating ROSA metrics to S3](./docs/rosa/federated-metrics)
* [Federating ARO metrics to Azure Files](./docs/aro/federated-metrics)
* [Sending ARO cluster logs to Azure Log Analytics](./docs/aro/clf-to-azure)

## Security

### Kubernetes Secret Store CSI Driver

* [Just the CSI itself](./docs/security/secrets-store-csi)
    * [+ HashiCorp CSI](./docs/security/secrets-store-csi/hashicorp-vault)
    * [+ AWS Secrets CSI with ROSA in STS mode](./docs/rosa/aws-secrets-manager-csi)
    * [+ Azure Key Vault CSI Driver](./docs/security/secrets-store-csi/azure-key-vault)

## Applications

* [Deploying Astronomer to OpenShift](./docs/aro/astronomer/)


## Operations - DevOps/GitOps

* [Demonstrating GitOps - ArgoCD](./docs/demos/gitops/)
* [Migrate Kubernetes Applications with Konveyer Crane](./docs/demos/crane/)
