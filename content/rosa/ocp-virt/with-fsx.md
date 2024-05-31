---
date: '2024-05-20'
title: Deploying Openshift Virtualization on ROSA with NetApp FSx storage.
tags: ["ROSA", "ocp-virt", "virtualization"]
authors:
  - Paul Czarkowski
---

OpenShift Virtualization is a feature of OpenShift that allows you to run virtual machines alongside your containers.  This is useful for running legacy applications that can't be containerized, or for running applications that require special hardware or software that isn't available in a container.

In this tutorial, I'll show you how to deploy OpenShift Virtualization on Red Hat OpenShift on AWS (ROSA) using the AWS NetApp FSx service (specifically NFS, not ISCSI or SAN) to provide resilience and live migration.  I'll show you how to create a ROSA cluster, deploy the OpenShift Virtualization operator, deploy the NetApp Trident Operator and create a virtual machine.

If you're planning to deploy OpenShift Virtualization in a production environment, you should follow the official documentation and best practices.

## Pre-requisites

* A ROSA Cluster (see [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/))
* An AWS account with permissions to create FSx for ONTAP
* The `git` binary installed on your machine.  You can download it from the [git website](https://git-scm.com/downloads).

> Note: This guide re-uses environment variables from the [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/) guide. If you have an existing cluster, you'll need to set them appropriately for the cluster.

## Prepare the Environment

1. Run this these commands to set some environment variables to use throughout (Terraform commands need to be run in the directory you ran Terraform)

    ```bash
    export CLUSTER=${TF_VAR_cluster_name}
    export FSX_REGION=$(rosa describe cluster -c ${CLUSTER} -o json | jq -r '.region.id')
    export FSX_NAME="${CLUSTER}-FSXONTAP"
    export FSX_SUBNET1="$(terraform output -json private_subnet_ids | jq -r '.[0]')"
    export FSX_SUBNET2="$(terraform output -json private_subnet_ids | jq -r '.[1]')"
    export FSX_VPC="$(terraform output -raw vpc_id)"
    export FSX_VPC_CIDR="$(terraform output -raw vpc_cidr)"
    export FSX_ROUTE_TABLES="$(terraform output -json private_route_table_ids | jq -r '. | join(",")')"
    export FSX_ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo)
    export SVM_ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo)
    export METAL_AZ=$(terraform output -json private_subnet_azs | jq -r '.[0]')
    ```

1. Create a bare metal machine pool

	> Note bare metal machines are not cheap, so be warned!

    ```
     rosa create machine-pool -c $CLUSTER \
       --replicas 2 --availability-zone $METAL_AZ \
       --instance-type m5zn.metal --name virt
    ```

## Provision FSx for ONTAP

1. Change to a directory to clone the FSx for ONTAP CloudFormation template

    ```bash
    mkdir -p ~/rosa-fsx-ontap
    cd ~/rosa-fsx-ontap
    git clone https://github.com/aws-samples/rosa-fsx-netapp-ontap.git
    cd rosa-fsx-netapp-ontap/fsx
    ```

1. Create the CloudFormation Stack

    ```bash
    aws cloudformation create-stack \
      --stack-name "${CLUSTER}-FSXONTAP" \
      --template-body file://./FSxONTAP.yaml \
      --region "${FSX_REGION}" \
      --parameters \
      ParameterKey=Subnet1ID,ParameterValue=${FSX_SUBNET1} \
      ParameterKey=Subnet2ID,ParameterValue=${FSX_SUBNET2} \
      ParameterKey=myVpc,ParameterValue=${FSX_VPC} \
      ParameterKey=FSxONTAPRouteTable,ParameterValue=\"$FSX_ROUTE_TABLES\" \
      ParameterKey=FileSystemName,ParameterValue=ROSA-myFSxONTAP \
      ParameterKey=ThroughputCapacity,ParameterValue=512 \
      ParameterKey=FSxAllowedCIDR,ParameterValue=${FSX_VPC_CIDR} \
      ParameterKey=FsxAdminPassword,ParameterValue=\"${FSX_ADMIN_PASS}\" \
      ParameterKey=SvmAdminPassword,ParameterValue=\"${SVM_ADMIN_PASS}\" \
      --capabilities CAPABILITY_NAMED_IAM
    ```

    This can take some time, so we can go ahead and deploy the OpenShift Virtualization Operator while we wait.

{{< readfile file="/content/rosa/ocp-virt/deploy-operator-cli.md" markdown="true" >}}

## Install and Configure the Trident CSI driver

1. Verify the cloudformation stack is complete

    ```bash
    aws cloudformation wait stack-create-complete --stack-name "${CLUSTER}-FSXONTAP" --region "${FSX_REGION}"
    ```

1. Get the FSx ONTAP filesystem id

    ```bash
    FSX_ID=$(aws cloudformation describe-stacks \
      --stack-name "${CLUSTER}-FSXONTAP" \
      --region "${FSX_REGION}" --query \
      'Stacks[0].Outputs[?OutputKey==`FSxFileSystemID`].OutputValue' \
      --output text)
    ```

1. Get the FSx Management and NFS LIFs

    ```bash
    FSX_MGMT=$(aws fsx describe-storage-virtual-machines \
      --region us-east-1 --output text \
      --query "StorageVirtualMachines[?FileSystemId=='$FSX_ID'].Endpoints.Management.DNSName")

    FSX_NFS=$(aws fsx describe-storage-virtual-machines \
      --region us-east-1 --output text \
      --query "StorageVirtualMachines[?FileSystemId=='$FSX_ID'].Endpoints.Nfs.DNSName")
    ```

1. Add the NetApp Helm Repository

    ```bash
    helm repo add netapp https://netapp.github.io/trident-helm-chart
    helm repo update
    ```

1. Install the Trident CSI driver

    ```bash
    helm install trident-csi netapp/trident-operator \
      --create-namespace --namespace trident
    ```

1. Make sure the trident pods are running

    ```bash
    oc get pods -n trident
    ```

    ```
    NAME                                  READY   STATUS    RESTARTS   AGE
    trident-controller-598db8d797-2rrdw   6/6     Running   0          11m
    trident-node-linux-2hzlq              2/2     Running   0          11m
    trident-node-linux-7vhpz              2/2     Running   0          11m
    trident-operator-67d6fd899b-6xrwk     1/1     Running   0          11m
    ```

1. Create a secret containing the SVM credentials

    ```bash
    oc create secret generic backend-fsx-ontap-nas-secret \
      --namespace trident \
      --from-literal=username=vsadmin \
      --from-literal=password="${SVM_ADMIN_PASS}"
    ```

1. Create a BackendConfig for the FSx ONTAP

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: trident.netapp.io/v1
    kind: TridentBackendConfig
    metadata:
      name: backend-fsx-ontap-nas
      namespace: trident
    spec:
      version: 1
      backendName: fsx-ontap
      storageDriverName: ontap-nas
      managementLIF: $FSX_MGMT
      dataLIF: $FSX_NFS
      svm: SVM1
      credentials:
        name: backend-fsx-ontap-nas-secret
    EOF
    ```

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: trident-csi
    provisioner: csi.trident.netapp.io
    parameters:
      backendType: "ontap-nas"
      fsType: "ext4"
    allowVolumeExpansion: True
    reclaimPolicy: Retain
    EOF
    ```

## Create a Virtual Machine

1. Create a project and a secret containing your public SSH key

    ```
    oc new-project my-vms
    oc create secret generic authorized-keys --from-file=ssh-publickey=$HOME/.ssh/id_rsa.pub
    ```

1. Create a VM

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: my-first-fedora-vm
      finalizers:
        - kubevirt.io/virtualMachineControllerFinalize
      labels:
        app: my-first-fedora-vm
    spec:
      dataVolumeTemplates:
        - metadata:
            name: my-first-fedora-vm
          spec:
            preallocation: false
            sourceRef:
              kind: DataSource
              name: fedora
              namespace: openshift-virtualization-os-images
            storage:
              resources:
                requests:
                  storage: 30Gi
              storageClassName: trident-csi
      running: true
      template:
        metadata:
          annotations:
            vm.kubevirt.io/flavor: small
            vm.kubevirt.io/os: fedora
            vm.kubevirt.io/workload: server
          labels:
            kubevirt.io/domain: my-first-fedora-vm
            kubevirt.io/size: small
        spec:
          accessCredentials:
            - sshPublicKey:
                propagationMethod:
                  noCloud: {}
                source:
                  secret:
                    secretName: authorized-keys
          architecture: amd64
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - bootOrder: 1
                  disk:
                    bus: virtio
                  name: rootdisk
                - bootOrder: 2
                  disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
              networkInterfaceMultiqueue: true
            machine:
              type: pc-q35-rhel9.2.0
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
          volumes:
            - dataVolume:
                name: my-first-fedora-vm
              name: rootdisk
            - cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: fedora
                  password: xtg8-ly36-swy3
                  chpasswd: { expire: False }
              name: cloudinitdisk
    EOF
    ```

1. Watch for the VM to be ready

    ```bash
    watch oc get my-first-fedora-vm

    ```
    Every 2.0s: oc get vm
    NAME         AGE     STATUS         READY
    my-first-fedora-vm   3m16s   Running   False
    ```

1. SSH into the VM

    ```bash
    virtctl ssh fedora@my-first-fedora-vm -i ~/.ssh/id_rsa
    ```

    ```output
    Last login: Wed May 22 19:47:45 2024 from 10.128.2.10
    [fedora@my-first-fedora-vm ~]$ whoami
    fedora
    [fedora@my-first-fedora-vm ~]$ exit
    logout
    ```

1. Check what node the VM is deployed on

    ```bash
     oc get pod -l "kubevirt.io/domain=my-first-fedora-vm" -o jsonpath="{.items[0].metadata.labels.kubevirt\.io/nodeName}"
    ```

    ```output
    ip-10-10-13-196.ec2.internal
    ```

1. Live migrate the VM

    ```bash
    virtctl migrate my-first-fedora-vm
    ```

1. Wait a moment, and check the node again

    ```bash
    oc get pod -l "kubevirt.io/domain=my-first-fedora-vm" -o jsonpath="{.items[0].metadata.labels.kubevirt\.io/nodeName}"
    ```

    ```output
    ip-10-10-5-148.ec2.internal
    ```

Congratulations! You now have a virtual machine running on OpenShift Virtualization on ROSA, and you've successfully live migrated it between hosts.

## Cleanup

1. Delete the VM

    ```bash
    oc delete vm my-first-fedora-vm
    oc delete project my-vms
    ```

1. Uninstall the Trident CSI driver

    ```bash
    oc delete sc trident-csi
    oc -n trident delete TridentBackendConfig backend-fsx-ontap-nas
    helm uninstall trident-csi -n trident
    ```

1. Delete the FSx Storage Volumes (except for "SVM1_root" volume)

      ```bash
      FSX_VOLUME_IDS=$(aws fsx describe-volumes --region $FSX_REGION --output text --query "Volumes[?FileSystemId=='$FSX_ID' && Name!='SVM1_root'].VolumeId")
      for FSX_VOLUME_ID in $FSX_VOLUME_IDS; do
        aws fsx delete-volume --volume-id $FSX_VOLUME_ID --region $FSX_REGION
      done
      ```

1. Wait until the volumes are deleted

    ```bash
    watch "aws fsx describe-volumes --region $FSX_REGION \
      --output text --query \"Volumes[?FileSystemId=='$FSX_ID' \
      && Name!='SVM1_root'].Name\""
    ```

1. Delete the FSx for ONTAP stack

    ```bash
    aws cloudformation delete-stack --stack-name "${CLUSTER}-FSXONTAP" --region "${FSX_REGION}"
    ```

1. Wait for the stack to be deleted

    ```bash
    aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER}-FSXONTAP" --region "${FSX_REGION}"
    ```

1. Delete the ROSA HCP Cluster

    If you used the Terraform from the [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/) guide, you can run the following command to delete the cluster from inside the terraform repository:

    ```bash
    terraform destroy
    ```
