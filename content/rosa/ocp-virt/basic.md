---
date: '2024-05-14'
title: Deploying OpenShift Virtualization on ROSA (CLI)
tags: ["ROSA", "STS"]
authors:
  - Paul Czarkowski
---

OpenShift Virtualization is a feature of OpenShift that allows you to run virtual machines alongside your containers.  This is useful for running legacy applications that can't be containerized, or for running applications that require special hardware or software that isn't available in a container.

In this tutorial, I'll show you how to deploy OpenShift Virtualization on Red Hat OpenShift on AWS (ROSA).  I'll show you how to create a ROSA cluster, deploy the OpenShift Virtualization operator, and create a virtual machine.

It's important to keep in mind that this tutorial is designed to show you the quickest way to get started with OpenShift Virtualization on ROSA.  It's not designed to be a production-ready deployment. If you're planning to deploy OpenShift Virtualization in a production environment, you should follow the official documentation and best practices.

If you don't want to deploy the resources yourself, you can watch the video below to see how it's done.

{{< youtube 9vjVMowuaX0 >}}

## Pre-requisites

1. You will need a A ROSA Cluster (see [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/) if you need help creating one).

1. Set the cluster name as an environment variable (in the example we re-use the variable from the Terraform guide).

    ```bash
    export CLUSTER="${TF_VAR_cluster_name}"
    export METAL_AZ=$(terraform output -json private_subnet_azs | jq -r '.[0]')
    ```

1. Create a bare metal machine pool
	> Note bare metal machines are not cheap, so be warned!

    ```
     rosa create machine-pool -c $CLUSTER \
       --replicas 1 --availability-zone $METAL_AZ \
       --instance-type m5zn.metal --name virt
    ```

{{< readfile file="/content/rosa/ocp-virt/deploy-operator-cli.md" markdown="true" >}}

## Create a Virtual Machine

1. Create a project and a secret containing your public SSH key

    ```
    oc new-project my-vms
    oc create secret generic authorized-keys --from-file=ssh-publickey=$HOME/.ssh/id_rsa.pub
    ```

1. Create a VM

    ```
    cat << EOF | oc apply -f -
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: example-vm
    spec:
      dataVolumeTemplates:
      - apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: example-vm-disk
        spec:
          sourceRef:
            kind: DataSource
            name: rhel9
            namespace: openshift-virtualization-os-images
          storage:
            resources:
              requests:
                storage: 30Gi
      running: false
      template:
        metadata:
          labels:
            kubevirt.io/domain: example-vm
        spec:
          domain:
            cpu:
              cores: 1
              sockets: 2
              threads: 1
            devices:
              disks:
              - disk:
                  bus: virtio
                name: rootdisk
              - disk:
                  bus: virtio
                name: cloudinitdisk
              interfaces:
              - masquerade: {}
                name: default
              rng: {}
            features:
              smm:
                enabled: true
            firmware:
              bootloader:
                efi: {}
            resources:
              requests:
                memory: 8Gi
          evictionStrategy: LiveMigrate
          networks:
          - name: default
            pod: {}
          volumes:
            - name: rootdisk
              dataVolume:
                name: example-vm-disk
            - cloudInitConfigDrive:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: not-a-secure-password
                  chpasswd: { expire: False }
              name: cloudinitdisk
          accessCredentials:
            - sshPublicKey:
                propagationMethod:
                  configDrive: {}
                source:
                  secret:
                    secretName: authorized-keys
    EOF
    ```

1. Start the VM

    ```
    virtctl start example-vm
    ```

1. Watch for the VM to be ready

    ```bash
    watch oc get vm example-vm

    ```
    Every 2.0s: oc get vm
    NAME         AGE     STATUS         READY
    example-vm   3m16s   Running   False
    ```

1. SSH into the VM

    ```bash
    virtctl ssh cloud-user@example-vm -i ~/.ssh/id_rsa
    ```

    ```output
    Register this system with Red Hat Insights: insights-client --register
    Create an account or view all your systems at https://red.ht/insights-dashboard
    Last login: Fri May 17 16:35:39 2024 from 10.130.0.41
    [cloud-user@example-vm ~]$
    ```

1. Congratulations! You now have a virtual machine running on OpenShift Virtualization on ROSA!

## Cleanup

1. Delete the VM

    ```
    oc delete vm example-vm
    ```

1. Delete the ROSA Cluster

    ```
    terraform destroy
    ```
