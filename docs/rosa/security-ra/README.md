# Security Reference Architecture for ROSA

**Tyler Stacey**

*Last updated 30 Sep 2022*

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
- [Deploy ROSA with a Custom KMS Key](https://mobb.ninja/docs/rosa/kms/)

### Multi-Availability Zone

ROSA clusters that will be used for production workloads should be deployed across multiple availability zones. In this configuration, control plane nodes are distributed across availability zones and at least one worker node is required in each availability zone.

This provides the highest level of fault tolerance and protects against the loss of a single availability zone in an AWS region.

### ROSA CLI Example to Deploy Day 1 ROSA SRA

## ROSA Day 2 Security and Operations

### Configure an Identity Provider

### Configure CloudWatch Log Forwarding

### Configure Custom Ingress TLS Profile

### Compliance Operator

### OpenShift Service Mesh

### Backup and Restore / Disaster Recovery

### Configure AWS WAF for Application Ingress

### Observability and Alerting
