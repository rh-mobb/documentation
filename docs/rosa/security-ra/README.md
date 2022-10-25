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
- AWS Landing Zone Recommendations

## ROSA Day 1 Configuration

### AWS PrivateLink Networking

### STS Mode

### Customer Supplied KMS Key

### Multi-Availability Zone

## ROSA Day 2 Security and Operations

### Configure an Identity Provider

### Configure CloudWatch Log Forwarding

### Configure Custom Ingress TLS Profile

### Compliance Operator

### OpenShift Service Mesh

### Backup and Restore / Disaster Recovery

### Configure AWS WAF for Application Ingress

### Observability and Alerting

## AWS Landing Zone Recommendations

Customers seeking the highest

