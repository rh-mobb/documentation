# Using the egress-ip Operator with a Private ARO Cluster

## Prerequisites

* [A private ARO cluster with a VPN Connection](./private-cluster)

## Deploy the Operator

1. Log into the ARO cluster's Console

1. Switch to the Administrator view

1. Click on Operators -> Operator Hub

1. Search for "Egressip Ipam Operator"

1. Install it with the default settings

## Configure EgressIP

1. Create an EgressIPAM resource for your cluster.  Update the CIDR to reflect the worker node subnet.

    ```
    cat << EOF | kubectl apply -f -
    apiVersion: redhatcop.redhat.io/v1alpha1
    kind: EgressIPAM
    metadata:
      name: egressipam-azure
    spec:
      # Add fields here
      cidrAssignments:
        - labelValue: ""
          CIDR: 10.0.2.0/23
          reservedIPs: []
      topologyLabel: "node-role.kubernetes.io/worker"
      nodeSelector:
        matchLabels:
          node-role.kubernetes.io/worker: ""
    EOF
      ```