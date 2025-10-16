---
date: '2025-10-15'
title: Migrating Azure VMs to OpenShift Virtualization on ARO
tags: ["ARO", "VIRT"]
authors:
  - Kevin Collins
  - Kumudu Herath
---

Migrating virtual machines (VMs) from Azure to OpenShift Virtualization on Azure Red Hat OpenShift (ARO) is a powerful step toward unifying your traditional and cloud-native workloads on a single, enterprise-grade application platform. This guide will walk you through the process, which is designed to be surprisingly straightforward despite current technical constraints. At present, Azure primarily supports exporting VM disks in the Virtual Hard Disk (VHD) format. While Red Hat's Migration Toolkit for Virtualization (MTV) is rapidly evolving to formally support this scenario, we will detail a practical method to bridge this gap and get your VMs running on ARO quickly.

The core benefit of this migration is transforming your VM infrastructure into an integral part of a modern application platform. Azure Red Hat OpenShift offers a fully managed application platform that brings enterprise features to your workloads, including seamless integration of VMs and containers, centralized management, and a clear path for future application modernization. 

## Pre-requisites

1. You will need an 4.18+ ARO Cluster with OpenShift Virtualization installed and configured.   Follow this [guide](/experts/aro/aro-virt/) to get started

2. CLIs and Command Line Tools Needed
  >Important: The virt-v2v tool currently operates exclusively on Linux. If you do not have a Linux environment available, please deploy a Linux VM in Azure for this process.

  * oc (logged into the ARO cluster)
  * az
  * virtctl
  * virt-v2v 

3. An Azure VM you want to migrate

4. Environment Variables

```bash
  export SCRATCH_DIR="/Users/kevincollins/scratch/aro-virt"
  export AZURE_VM_RESOURCE_GROUP="AZURE_VM_RG"
  export AZURE_VM_NAME="AZURE_VM_NAME"
  export PVC_NAME="AZURE_VM_PVC"
  export UPLOAD_PROXY_URL=$(oc get route cdi-uploadproxy -n openshift-cnv -o jsonpath='{.spec.host}')
  TARGET_VM_PROJECT="my-vms-project"
  
  mkdir -p ${SCRATCH_DIR}
```

5. Create the project for the VMs if not already created.

```bash
oc new-project ${TARGET_VM_PROJECT}
```

## Export an Azure Virtual Machine to VHD format

1. Deallocate the VM (Required for OS Disk)

You must deallocate the VM to ensure a clean, consistent snapshot of the OS disk, and to be able to export it.	

```bash
 az vm deallocate --resource-group ${AZURE_VM_RESOURCE_GROUP}$ --name ${AZURE_VM_NAME}
```

2. Get the OS Disk Name

You need the name of the operating system disk attached to the VM.

```bash
osDiskName=$(az vm show --resource-group ${AZURE_VM_RESOURCE_GROUP} --name  ${AZURE_VM_NAME} --query "storageProfile.osDisk.name" -o tsv)
```

3. Generate a Shared Access Signature (SAS) URL

You need to generate a read-only SAS for the managed disk, which provides a temporary, secure URL to the underlying VHD file. The --duration-in-seconds specifies how long the URL will be valid (e.g., 3600 seconds = 1 hour).

```bash
sasUri=$(az disk grant-access --resource-group ${AZURE_VM_RESOURCE_GROUP} --name ${osDiskName} --duration-in-seconds 3600 --access-level Read --query [accessSas] -o tsv)
```

4. Download the VHD File

Use the generated SAS URI with a tool like AzCopy.  AzCopy is generally recommended for large files as it is optimized for high-performance data transfer.

```bash
azcopy copy "$sasUri" "${SCRATCH_DIR}/azure-migrate-vm.vhd"
```

5. Get the disk size and set an environment variable

```bash
az disk show \
    -resource-group ${AZURE_VM_RESOURCE_GROUP} \
    --name $osDiskName \
    --query "diskSizeGb" \
    --output tsv
```

Set the following environment variable to a size greater than the above output

```bash
export PVC_SIZE="100Gi"
```

## Convert the VHD image to QCOW format
Use the virt-v2v command-line interface to convert the Azure VM's VHD disk image into a QCOW2 file format, placing the final result in the local ./output directory.

```bash
mkdir ${SCRATCH_DIR}/output

virt-v2v -i disk ${SCRATCH_DIR}/azure-migrate-vm.vhd -o local -os ${SCRATCH_DIR}/output -of qcow2
```

## Migrate the VM into OpenShift Virtualization

Import the QCOW2 image of the Azure Virtual Machine into OpenShift Virtualization.

>Note: This process assumes you are using OpenShift Data Foundation; if you are using a different storage class, remember to modify the --storage-class option accordingly.

```bash
virtctl image-upload   --namespace $TARGET_VM_PROJECT   --pvc-name=$PVC_NAME   --pvc-size=$PVC_SIZE   --image-path=$IMAGE_PATH   --uploadproxy-url=$UPLOAD_PROXY_URL   --access-mode=ReadWriteOnce --storage-class=ocs-storagecluster-ceph-rbd
```

## Create a VM in OpenShift Virtualization

Using the uploaded image, create a virtual machine in OpenShift Virtualization.

```bash
cat << EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${AZURE_VM_NAME}
  namespace: ${TARGET_VM_PROJECT}
spec:
  running: true
  template:
    metadata:
      labels:
        app: ${AZURE_VM_NAME}
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          # --- 1. Define the virtual hardware (Interface and Disk) ---
          interfaces:
            - name: default               # Interface name (must match name in networks block)
              masquerade: {}              # Defines the type of connectivity (NAT to Pod Network)
              model: virtio
          disks:
            - name: rootdisk
              disk:
                bus: virtio

      # --- 2. Define the networks the VM connects to ---
      networks:
        - name: default                   # Network name (must match name in interfaces block)
          pod: {}                         # Connects the 'default' interface to the Pod network

      # --- 3. Link the disk definition to the uploaded PVC ---
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
```

Congratulations, you have now successfully imported an Azure VM into OpenShift Virtualization.