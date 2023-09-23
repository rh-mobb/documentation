---
date: '2022-09-30'
title: Security Reference Architecture for ROSA
tags: ["AWS", "ROSA"]
authors:
  - Tyler Stacey
  - Connor Wooley
---

The **Security Reference Architecture for ROSA** is a set of guidelines for deploying Red Hat OpenShift on AWS (ROSA) clusters to support high-security production workloads that align with Red Hat and AWS best practices.

This overall architectural guidance compliments detailed, specific recommendations for AWS services and Red Hat OpenShift Container Platform.

The Security Reference Architecture (SRA) for ROSA is a living document and is updated periodically based on new feature releases, customer feedback and evolving security best practices.

![security-ra](./rosa-security-ra.png)

This document is divided into the following sections:

- ROSA Day 1 Configuration
- ROSA Day 2 Security and Operations

## ROSA Day 1 Configuration

ROSA Day 1 configurations are applied to the cluster at the time it is created; they cannot be modified after the cluster has been deployed.

### AWS PrivateLink Networking

ROSA provides 3 network deployment patterns: public, private and PrivateLink. Choosing the PrivateLink option provides the most secure configuration and is recommended for customers with sensitive workloads or strict compliance requirements. The PrivateLink option uses [AWS PrivateLink](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html) to allow Red Hat Site Reliability Engineering (SRE) teams to manage the cluster using a private subnet connected to the cluster's PrivateLink endpoint in an existing VPC.

![private-link](./rosa-privatelink.svg)

When using the PrivateLink model, a VPC with Private Subnets must exist in the AWS account where ROSA will be deployed. The subnets are provided to the installer via CLI flags.

Details on the PrivateLink Architecture can be found in the Red Hat and AWS documentation:

- [ROSA PrivateLink Architecture](https://docs.openshift.com/rosa/rosa_architecture/rosa_architecture_sub/rosa-architecture-models.html#osd-aws-privatelink-architecture.adoc_rosa-architecture-models)
- [ROSA PrivateLink Prerequisites](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa-aws-privatelink-creating-cluster.html)
- [Firewall Egress Requirements](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#osd-aws-privatelink-firewall-prerequisites_rosa-sts-aws-prereqs)
- [Deploy a VPC and PrivateLink Cluster](https://docs.aws.amazon.com/ROSA/latest/userguide/getting-started-private-link.html)

### AWS Security Token Service (STS) Mode

There are two supported methods for providing AWS permissions to ROSA:

- Using static IAM user credentials with AdministratorAccess policy - “ROSA with IAM Users” (not recommended)
- Using AWS Security Token Service (STS) with short-lived, dynamic tokens (preferred) - “ROSA with STS”

The STS method uses least-privilege predefined roles and policies to grant ROSA minimal permissions in the AWS account for the service to operate and is the recommended option.

As stated in the [AWS documentation](https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html) AWS STS “enables you to request temporary, limited-privilege credentials for AWS Identity and Access Management (IAM) users or for users you authenticate (federated users)”. In this case, AWS STS can be used to grant the ROSA service, limited, short-term access, to resources in your AWS account. After these credentials expire (typically an hour after being requested), they are no longer recognized by AWS and they no longer have any kind of account access from API requests made with them.

Details on ROSA with STS can be found in Red Hat documentation and blogs:

- [ROSA with STS Explained](https://cloud.redhat.com/blog/what-is-aws-sts-and-how-does-red-hat-openshift-service-on-aws-rosa-use-sts)
- [AWS prerequisites for ROSA with STS](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html)
- [IAM Resources for Clusters that Use STS](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)

### Customer-Supplied KMS Key

By default, ROSA encrypts all [Elastic Block Store (EBS)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AmazonEBS.html) volumes used for node storage and Persistent Volumes (PVs) with an AWS-managed [Key Management Service (KMS)](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html) key.

Using a [Customer Managed KMS](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#key-mgmt) key allows you to have full control over the KMS key including key policies, key rotation and deletion.

To configure a cluster with a custom KMS Key, consider the following references:

- [ROSA STS Customizations](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa-sts-creating-a-cluster-with-customizations.html#rosa-sts-creating-cluster-customizations_rosa-sts-creating-a-cluster-with-customizations)
- [Deploy ROSA with a Custom KMS Key](https://mobb.ninja/experts/rosa/kms/)

### Multi-Availability Zone

ROSA clusters that will be used for production workloads should be deployed across multiple availability zones. In this configuration, control plane nodes are distributed across availability zones and at least one worker node is required in each availability zone.

This provides the highest level of fault tolerance and protects against the loss of a single availability zone in an AWS region.

### Deploy the Day 1 ROSA SRA via ROSA CLI

The Day 1 ROSA SRA can be deployed quickly using the AWS CLI and the ROSA CLI. To deploy the cluster, the following prerequisites must be met:

- AWS Account:
    - Access to an AWS account with [sufficient permissions](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html) to deploy a ROSA cluster.
    - If using AWS Organizations and Service Control Policies (SCPs), the SCPs must not be more restrictive than the minimum permissions required to operate the service.
    - [Sufficient quota](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-required-aws-service-quotas.html#rosa-sts-required-aws-service-quotas) to support the cluster deployment.
- Networking: An AWS VPC, with 3 private subnets across 3 availability zones and outbound internet access. Make note of the AWS VPC Subnet IDs as they will be needed for the installer.
- Tooling:
    - [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
    - [ROSA CLI](https://github.com/openshift/rosa/releases/tag/v1.2.6) v1.2.6

#### Prepare the ROSA Workload Account

Log in to the AWS account with a user that has been assigned AdministratorAccess and run the following command using the `aws` CLI:

```bash
export AWS_REGION="ca-central-1"
aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"
 ```

#### Create the required ROSA Account Roles

Creation of the account roles is a one-time activity, create them with the following command:

```bash
rosa create account-roles --mode auto -y
```

#### Create the Required KMS Key and Initial Policy

The custom KMS key is used to encrypt EC2 EBS node volumes and the EBS volumes that are created by the default `StorageClass` on OpenShift.

Create a new Symmetric KMS Key for EBS Encryption:

```bash
KMS_ARN=$(aws kms create-key --region $AWS_REGION --description 'rosa-ebs-key' --query KeyMetadata.Arn --output text)
```

Generate the necessary key policy to allow the ROSA STS roles to access the key. Use the below command to populate a sample policy, or create your own.

```bash
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text); cat << EOF > rosa-key-policy.json
{
    "Version": "2012-10-17",
    "Id": "rosa-key-policy-1",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT}:root"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow ROSA use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Support-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Allow attachment of persistent resources",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Support-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:CreateGrant",
                "kms:ListGrants",
                "kms:RevokeGrant"
            ],
            "Resource": "*",
            "Condition": {
                "Bool": {
                    "kms:GrantIsForAWSResource": "true"
                }
            }
        }
    ]
}
EOF
```

Apply the newly generated key policy to the custom KMS key.

```bash
aws kms put-key-policy --key-id $KMS_ARN \
--policy file://rosa-key-policy.json \
--policy-name default
```

#### Deploy a multi-AZ, single subnet, PrivateLink, STS ROSA cluster

To deploy the cluster, you must gather the following info:

- `--subnet-ids`: AWS subnet IDs that the cluster will be deployed in
- `--machine-cidr`: The VPC CIDR

Deploy the cluster with the following command:

```bash
ROSA_CLUSTER_NAME=rosa-ct1
rosa create cluster --cluster-name $ROSA_CLUSTER_NAME --sts --private-link \
--region ca-central-1 --version 4.11.4 \
--machine-cidr 10.0.0.0/20 \
--subnet-ids subnet-058aa558a63da3d51,subnet-058aa558a63da3d52,subnet-058aa558a63da3d53 \
--enable-customer-managed-key --kms-key-arn $KMS_ARN -y --mode auto
```

To complete the KMS key policy, you must retrieve the Cluster CSI and Machine API operator role names:

```bash
rosa describe cluster -c $ROSA_CLUSTER_NAME
```

The operator role names will be similar to:

```text
arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-cluster-csi-drivers-ebs-cloud-credenti
arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-machine-api-aws-cloud-credentials
```

Replace the role names in the following script with your **EXACT** Operator Role names:

```bash
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text); cat << EOF > rosa-key-policy.json
{
    "Version": "2012-10-17",
    "Id": "rosa-key-policy-1",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT}:root"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow ROSA use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Support-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Installer-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Worker-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-cluster-csi-drivers-ebs-cloud-credent",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-machine-api-aws-cloud-credentials"
                ]
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Allow attachment of persistent resources",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Support-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Installer-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-Worker-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/ROSA-ControlPlane-Role",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-cluster-csi-drivers-ebs-cloud-credent",
                    "arn:aws:iam::${AWS_ACCOUNT}:role/<CLUSTERNAME>-<IDENTIFIER>-openshift-machine-api-aws-cloud-credentials"
                ]
            },
            "Action": [
                "kms:CreateGrant",
                "kms:ListGrants",
                "kms:RevokeGrant"
            ],
            "Resource": "*",
            "Condition": {
                "Bool": {
                    "kms:GrantIsForAWSResource": "true"
                }
            }
        }
    ]
}
EOF
```

Apply the newly updated key policy to the custom KMS key.

```bash
aws kms put-key-policy --key-id $KMS_ARN \
--policy file://rosa-key-policy.json \
--policy-name default
```

After creating the operator roles, create the required OIDC provider:

```bash
rosa create oidc-provider --mode auto --cluster $ROSA_CLUSTER_NAME
```

Wait for the cluster deployment to finish.


## ROSA Day 2 Security and Operations

This section of the SRA describes tasks that are completed once the cluster has been deployed. These configurations enhance the security of the cluster and are often requirements for customers operating in regulated environments.

### Configure an Identity Provider

ROSA provides an easy way to access clusters immediately after deployment through the creation of a `cluster-admin` user through the ROSA CLI. This method creates an HTPASSWORD identity provider on the cluster. This is good if you need quick access to the cluster, but should not be used for clusters that will host any workloads.

The recommended approach is to use a formal identity provider (IDP) to access the cluster (and then grant that user admin privileges, if desired).

ROSA supports several commercially available IDPs and common protocols. The full listing can be found in the ROSA documentation:
- [https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa-sts-config-identity-providers.html#understanding-idp-supported_rosa-sts-config-identity-providers](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa-sts-config-identity-providers.html#understanding-idp-supported_rosa-sts-config-identity-providers)

Some examples of how to configure an IDP can be found on the `mobb.ninja` website:
- [Configure Azure AD as an identity provider for ROSA/OSD](https://mobb.ninja/experts/idp/azuread)
- [Configure GitLab as an identity provider for ROSA/OSD](https://mobb.ninja/experts/idp/gitlab)
- [Configure Azure AD as an identity provider for ROSA with group claims](https://mobb.ninja/experts/idp/group-claims/rosa/)

### Configure CloudWatch Log Forwarding

ROSA does not provide persistent logging by default, but it can be enabled through the `cluster-logging` operator from the OpenShift Marketplace. This add-on service offers an optional application log-forwarding solution based on AWS CloudWatch. This logging solution can be installed after the ROSA cluster is provisioned.

To capture all logging events in AWS CloudWatch, all three log types should be enabled:

- **Applications logs**: Permits the Operator to collect application logs, which includes everything that is not deployed in the `openshift-`, `kube-`, and default namespaces.
- **Infrastructure logs**: Permits the Operator to collect logs from OpenShift Container Platform, Kubernetes, and some nodes.
- **Audit logs**: Permits the Operator to collect node logs related to security audits. By default, Red Hat stores audit logs outside the cluster through a separate mechanism that does not rely on the Cluster Logging Operator. For more information about default audit logging, see the ROSA Service Definition.

After the operator has been enabled the logs can be viewed in the AWS Console, and persistently stored based on the CloudWatch configuration of the AWS Account.

The cluster-logging operator has the following limits when configured for CloudWatch log forwarding:

| **Message Size (bytes)** | **Maximum logging rate (messages/second/node)** |
|--------------------------|-------------------------------------------------|
| 512                      | 1,000                                           |
| 1,024                    | 650                                             |
| 2,048                    | 450                                             |

Details on this configuration can be found at the following links:
- [Configuring the Cluster Log Forwarder for CloudWatch Logs and STS](https://mobb.ninja/experts/rosa/clf-cloudwatch-sts/)
- [Viewing cluster logs in the AWS Console](https://docs.openshift.com/rosa/rosa_cluster_admin/rosa_logging/rosa-viewing-logs.html)

### Configure Custom Ingress TLS Profile

By default, ROSA supports multiple versions of TLS on the Ingress COntrollers used for applications to support the broadest set of clients and libraries. To support specific versions of TLS, the `tlsSecurityProfile` value on cluster ingress controllers can be modified.

Review the OpenShift Documentation that explains the options for the `tlsSecurityProfile` to determine which profile meets your organization's needs. By default, ingress controllers are configured to use the Intermediate profile, which corresponds to the Intermediate Mozilla profile:

- [OpenShift documentation on tlsSecurityProfile](https://docs.openshift.com/container-platform/4.11/networking/ingress-operator.html#configuring-ingress-controller-tls)
- [Intermediate Mozilla Profile](https://wiki.mozilla.org/Security/Server_Side_TLS#Intermediate_compatibility_.28recommended.29)

The `tlsSecurityProfile` can be modified by following these instructions:

- [Configure ROSA/OSD to use custom TLS ciphers on the ingress controllers](https://mobb.ninja/experts/ingress/tls-cipher-customization/)

### Compliance Operator

The Compliance Operator lets ROSA administrators describe the required compliance state of a cluster and provides them with an overview of gaps and ways to remediate them. The Compliance Operator assesses compliance of both the Kubernetes API resources of ROSA, as well as the nodes running the cluster. The Compliance Operator uses OpenSCAP, a NIST-certified tool, to scan and enforce security policies provided by the content.

There are several profiles available as part of the Compliance Operator installation. These profiles represent different compliance benchmarks. Each profile has the product name that it applies to added as a prefix to the profile’s name. `ocp4-e8` applies the Essential 8 benchmark to the OpenShift Container Platform product, while `rhcos4-e8` applies the Essential 8 benchmark to the Red Hat Enterprise Linux CoreOS (RHCOS) product.

> **Important note:** The compliance benchmarks are continuously updated and maintained by Red Hat based on each control profile. ROSA-specific benchmarks are under development to account for the managed service components.

To understand and install the compliance operator, read the Red Hat documentation:

- [Installing the Compliance Operator](https://docs.openshift.com/container-platform/4.11/security/compliance_operator/compliance-operator-installation.html)
- [Understanding the Compliance Operator](https://docs.openshift.com/container-platform/4.11/security/compliance_operator/compliance-operator-understanding.html)
- [Supported compliance profiles](https://docs.openshift.com/container-platform/4.11/security/compliance_operator/compliance-operator-supported-profiles.html)

### OpenShift Service Mesh

Red Hat OpenShift Service Mesh addresses a variety of problems in a microservice architecture by creating a centralized point of control in an application. It adds a transparent layer on existing distributed applications without requiring any changes to the application code.

Red Hat OpenShift Service Mesh provides a number of key capabilities uniformly across a network of services:

- **Traffic Management** - Control the flow of traffic and API calls between services, make calls more reliable, and make the network more robust in the face of adverse conditions.
- **Service Identity and Security** - Provide services in the mesh with a verifiable identity and provide the ability to protect service traffic as it flows over networks of varying degrees of trustworthiness.
- **Policy Enforcement** - Apply an organizational policy to the interaction between services, ensure access policies are enforced and resources are fairly distributed among consumers. Policy changes are made by configuring the mesh, not by changing application code.
- **Telemetry** - Gain an understanding of the dependencies between services and the nature and flow of traffic between them, providing the ability to quickly identify issues.

To learn more about OpenSHift Service Mesh and to install the Service Mesh, read the OpenShift documentation:

- [Understanding Service Mesh](https://docs.openshift.com/container-platform/4.11/service_mesh/v2x/ossm-architecture.html)
- [Installing the Service Mesh Operator](https://docs.openshift.com/container-platform/4.11/service_mesh/v2x/installing-ossm.html)
- [Adding workloads to the Service Mesh](https://docs.openshift.com/container-platform/4.11/service_mesh/v2x/ossm-create-mesh.html)
- [Service Mesh Security](https://docs.openshift.com/container-platform/4.11/service_mesh/v2x/ossm-security.html)

### Backup and Restore / Disaster Recovery

An important part of any platform used to host business and user workloads is data protection. Data protection may include operations including on-demand backup, scheduled backup and restore. These operations allow the objects within a cluster to be backed up to a storage provider, either locally or on a public cloud and restore that cluster from the backup in the event of a failure or scheduled maintenance.

As part of the Shared Responsibility Model for ROSA, consumers of the service are responsible for backing up cluster and application data when the STS option is used. To implement a backup and disaster recovery solution, administrators can use OpenShift APIs for Data Protection (OADP). OADP is an operator that Red Hat has created to create backup and restore APIs in the OpenShift cluster. OADP provides the following APIs:

- Backup
- Restore
- Schedule
- BackupStorageLocation
- VolumeSnapshotLocation

You can learn how to install and use OADP from the following resources:

- [OADP features and plug-ins](https://docs.openshift.com/container-platform/4.11/backup_and_restore/application_backup_and_restore/oadp-features-plugins.html)
- [Deploying OpenShift Advanced Data Protection on a ROSA cluster](https://mobb.ninja/experts/misc/oadp/rosa-sts/)

### Configure AWS WAF and CloudFront for Application Ingress

ROSA does not provide advanced firewall or DDoS protection by default, however, this can easily be achieved by combining three AWS services to protect the cluster and applications:

- **AWS WAF** is a web application firewall that helps protect web applications from attacks by allowing you to configure rules that allow, block, or monitor (count) web requests based on conditions that you define. These conditions include IP addresses, HTTP headers, HTTP body, URI strings, SQL injection and cross-site scripting.
- **Amazon CloudFront** is a web service that gives businesses and web application developers an easy and cost effective way to distribute content with low latency and high data transfer speeds.
- **AWS Shield** is a managed service that provides protection against Distributed Denial of Service (DDoS) attacks for applications running on AWS.

To learn more about these services and how to configure them for ROSA, read the documentation below:

- [AWS WAF FAQ](https://aws.amazon.com/waf/faqs/)
- [Amazon CloudFront FAQ](https://aws.amazon.com/cloudfront/faqs/)
- [AWS Shield FAQ](https://aws.amazon.com/shield/faqs/)
- [Using CloudFront + WAF on ROSA](https://mobb.ninja/experts/aws/waf/cloud-front.html)
- [Using ALB + WAF on ROSA](https://mobb.ninja/experts/aws/waf/alb.html)

### Use and Store Secrets Securely in AWS

Kubernetes Secrets are insecure by default, this is described in the Kubernetes documentation:

> Kubernetes Secrets are, by default, stored unencrypted in the API server's underlying data store (etcd). This design is not unique to ROSA and affects all Kubernetes distributions. Anyone with API access can retrieve or modify a Secret, and so can anyone with access to etcd. Additionally, anyone who is authorized to create a Pod in a namespace can use that access to read any Secret in that namespace; this includes indirect access such as the ability to create a Deployment.

Customers looking for secure ways to manage application secrets often chose to use a third-party tool to manage secrets due to this behavior.

The AWS Secrets and Configuration Provider (ASCP) provides a way to expose AWS Secrets as Kubernetes storage volumes. With the ASCP, you can store and manage your secrets in AWS Secrets Manager and then retrieve them through your workloads running on ROSA.

This is made even easier / more secure through the use of AWS STS and Kubernetes PodIdentity.

To use the AWS Secrets Manager CSI with ROSA and STS, follow this guide:
- [Using AWS Secrets Manager CSI on Red Hat OpenShift on AWS with STS](https://mobb.ninja/experts/rosa/aws-secrets-manager-csi/)

### Provide External Persistent Storage to Applications on ROSA

ROSA supports both Amazon Elastic Block Storage (EBS) and Elastic File Storage (EFS) for persistent application data.

When applications require ReadWriteMany capabilities, or when multiple applications must read the same data, EFS should be used.

With the release of OpenShift 4.10 the EFS CSI Driver is now GA and available.

To learn more, or to install the EFS CSI driver, review the following documentation:

- [Persistent Storage using EFS](https://docs.openshift.com/rosa/storage/persistent_storage/osd-persistent-storage-aws.html)
- [Persistent Storage using EBS](https://docs.openshift.com/rosa/storage/persistent_storage/rosa-persistent-storage-aws-ebs.html)
- [Enabling the AWS EFS CSI Driver Operator on ROSA](https://mobb.ninja/experts/rosa/aws-efs-csi-operator-sts/)
