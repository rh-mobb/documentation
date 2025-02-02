---
date: '2024-05-14'
title: Deploying OpenShift Virtualization on ROSA (GUI)
tags: ["ROSA", "STS"]
authors:
  - Paul Czarkowski
---

OpenShift Virtualization is a feature of OpenShift that allows you to run virtual machines alongside your containers.  This is useful for running legacy applications that can't be containerized, or for running applications that require special hardware or software that isn't available in a container.

In this tutorial, I'll show you how to deploy OpenShift Virtualization on Red Hat OpenShift on AWS (ROSA) using the OpenShift Console.  I'll show you how to deploy the OpenShift Virtualization operator, and create a virtual machine all from inside the Red Hat Cluster Manager and OpenShift Console

It's important to keep in mind that this tutorial is designed to show you the quickest way to get started with OpenShift Virtualization on ROSA.  It's not designed to be a production-ready deployment. If you're planning to deploy OpenShift Virtualization in a production environment, you should follow the official documentation and best practices.

If you don't want to deploy the resources yourself, you can watch the video below to see how it's done.

{{< youtube 9vjVMowuaX0 >}}

## Pre-requisites

1. You will need a A ROSA Cluster (see [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/) if you need help creating one).

1. Browse to the [OpenShift Cluster Manager](https://console.redhat.com/openshift) and select your cluster, then click on the "Machine Pools" tab.

    ![OCM - Clusters](../ocm-clusters.png)

1. Click on the "Add Machine Pool" button, give it a name, and select a Bare Metal instance type such as `m5zn.metal`, set replicas to `1` and click `Add machine pool`.

    ![OCM - Add machine pool](../ocm-add-machine-pool.png)

1. When that's done, click on the `Open Console` button to open the OpenShift Console, then go to the Operators -> OperatorHub page and search for `Virtualization`.

    ![OCP - OCP-virt operator](../ocp-virt-operator.png)

1. Accept all the defaults and click the blue "Install" button.  Once installed it should prompt you to Create a `HyperConverged` instance, click the blue `Create HyperConverged` button.  Once again accept all of the defaults.

    ![OCP hyperconverged create](../ocp-create-hcv.png)

1. Once deployed it should notify you that you should refresh your browser, after which there will be a new `Virtualization` menu item in the left-hand navigation, click on that and then `Catalog` -> `Template catalog`.

    > Note: Make sure you're in the `default` project (or create  a new one)

    ![OCP Virt catalog](../ocp-virt-catalog.png)

1. Pick your preferred OS, in this case, we'll use `CentOS Stream 8 VM`, click on that and then click `Customize VirtualMachine`.

    ![ocp virt - centos 8](../ocp-virt-centos8.png)

1. Click on the `Scripts` tab, and click the `Edit` button next to the `Public SSH Key` title.  Click "Add new" and paste in your public SSH key, check the `Automatically apply this key to any new Virtual Machine you create in this project` then click `Save`.

    ![ssh key](../ssh-key.png)

1. Click `Create VirtualMachine`

    ![ocp - creating vm](../ocp-creating-vm.png)

1. After a while the VM will be running and you'll see a preview of the VNC console.

    ![ocp - vm created](../ocp-vm-created.png)

1. From here you can click `Open web console` to get an interactive VNC console, or you can SSH into the VM using the `virtctl` command.

    ![ssh into vm](../ssh.png)


1. Congratulations! You now have a virtual machine running on OpenShift Virtualization on ROSA!
