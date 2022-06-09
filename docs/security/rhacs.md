# Deploying Red Hat Advanced Cluster Security in ARO/ROSA

**Author: Roberto Carratalá**

*Updated: 09/06/2022*

This document is based in the [RHACS workshop](https://redhat-scholars.github.io/acs-workshop/acs-workshop/index.html) and in the [RHACS official documentation](https://docs.openshift.com/acs/3.70/installing/install-ocp-operator.html).

## Prerequisites

1. [An ARO cluster](/docs/quickstart-aro) or [a ROSA cluster](/docs/quickstart-rosa).

### Set up the OpenShift CLI (oc)

1. Download the OS specific OpenShift CLI from [Red Hat](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)

2. Unzip the downloaded file on your local machine

3. Place the extracted `oc` executable in your OS path or local directory

## Login to ARO / ROSA

* Login to your ARO / ROSA clusters with user with cluster-admin privileges.

## Installing Red Hat Advanced Cluster Security in ARO/ROSA

### RHACS Operator Installation

1. Follow the steps within the [RHACS Operator Installation Workshop](https://redhat-scholars.github.io/acs-workshop/acs-workshop/02-getting_started.html#install_acs_operator) to install the RHACS Operator.

### RHACS Central Cluster Installation

2. Follow the steps within the [RHACS Central Cluster Installation Workshop](https://redhat-scholars.github.io/acs-workshop/acs-workshop/02-getting_started.html#install_acs_central) to install the RHACS Central Cluster.

### RHACS Secured Cluster Configuration

3. Follow the steps in the [RHACS Secured Cluster Configuration](https://redhat-scholars.github.io/acs-workshop/acs-workshop/02-getting_started.html#config_acs_securedcluster), to import the ARO/ROSA cluster into RHACS.

## Deploying Example Apps for demo RHACS

4. Deploy some example apps for demo RHACS policies and violations:

```bash
oc new-project test

oc run shell --labels=app=shellshock,team=test-team \
--image=vulnerables/cve-2014-6271 -n test

oc run samba --labels=app=rce \
--image=vulnerables/cve-2017-7494 -n test
```