---
date: '2023-01-20'
title: AWS EFS on ROSA
tags: ["AWS", "ROSA"]
---

## Intro
Amazon [Elastic File Service](https://aws.amazon.com/efs/) (EFS) is a dynamic filesystem available for storing files easily across multiple pods in a cluster.

## Heads up!
There are currently multiple operators available for EFS. This section details them and how to install the correct one.

### If you are running OpenShift 4.10 or older:

The EFS CSI driver is now Generally Available (GA) as shown [in the documentation](https://docs.openshift.com/container-platform/4.10/storage/container_storage_interface/persistent-storage-csi-aws-efs.html). Please use the guide found [here to install the EFS CSI driver](./aws-efs-csi-operator-on-rosa)

### If you are running OpenShift 4.9 or below:

Please use the guide for the now unsupported AWS EFS Operator (note this lacks the CSI). We do not recommend you follow this procedure for production workloads, as it is unsupported by Red Hat Support/SRE, however we are keeping this here for clarity between the operators and posterity..

The guide can be found [here](./aws-efs-operator-on-rosa)

