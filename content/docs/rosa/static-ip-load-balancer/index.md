---
date: '2022-10-05'
title: Configure a load balancer service to use a static public IP
tags: ["AWS", "ROSA"]
authors:
  - Michael McNeill
  - Connor Wooley
---

This guide demonstrates how to create and assign a static public IP address to an OpenShift service in Azure Red Hat OpenShift (ARO). By default, the public IP address assigned to an OpenShift service with a type of LoadBalancer created by an ARO cluster is only valid for the lifespan of that resource. If you delete the OpenShift service, the associated load balancer and IP address are also deleted. If you want to assign a specific IP address or retain an IP address for redeployed OpenShift services, you can create and use a static public IP address.

This guide will walk through the following steps:

1. Create a new static public IP address.
2. Grant the Azure Red Hat OpenShift (ARO) cluster's service principal access to the parent resource group.
3. Create the load balancer service and assign the static public IP address.

## Prerequisites

- An existing ARO cluster. If you need an ARO cluster, see the quickstart [here](https://mobb.ninja/docs/quickstart-aro.html).
- The Azure CLI. If you need to install the Azure CLI, see the Microsoft documentation [here](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli).

## Before you begin

Before we begin, we need to set a few environment variables that will help us run the commands included in the guide.

```bash
RESOURCE_GROUP=example-rg # Replace this with the name of your ARO cluster's resource group
CLUSTER_NAME=example-cluster # Replace this with the name of your ARO cluster
PUBLIC_IP_NAME=example-pip # Replace this with the name you want your static public IP to have
```

## Create a new static public IP address

Create a static public IP address by using the `az network public ip create` command. The following command creates a static IP resource using the name you specified above in the parent resource group of the cluster object. To create the IP, run the following command:

```bash
az network public-ip create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${PUBLIC_IP_NAME} \
    --sku Standard \
    --allocation-method static
```

The static public IP address provisioned is displayed as a part of the output of the command. It will look something like this:

```json
{
  "publicIp": {
    ...
    "ipAddress": "40.121.183.52",
    ...
  }
}
```

## Grant the Azure Red Hat OpenShift (ARO) cluster's service principal access to the parent resource group

Next, we must grant the Azure Red Hat OpenShift (ARO) cluster's service principal access to the network resources of the parent resource group where we've created the static public IP. This must be done because the public IP lives outside of the cluster's managed resource group (which starts with `aro-`). To grant the necessary access, run the following command:

```bash
CLIENT_ID=$(az aro show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER_NAME} --query "servicePrincipalProfile.clientId" --output tsv)
SUB_ID=$(az account show --query "id" --output tsv)
az role assignment create \
    --assignee ${CLIENT_ID} \
    --role "Network Contributor" \
    --scope /subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}
```

## Create the load balancer service and assign the static public IP address.

Finally, we need to create a LoadBalancer service inside of OpenShift that specifies the static public IP address, as well as the parent resource group. Next, generate the necessary YAML for the LoadBalancer service with the loadBalancerIP property and resource group annotation set. To do so, run the following command, making sure to replace the variables specified:

```bash
PUBLIC_IP=$(az network public-ip show --resource-group ${RESOURCE_GROUP} --name ${PUBLIC_IP_NAME} --query ipAddress --output tsv)
cat << EOF > pip-service.yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: ${RESOURCE_GROUP}
  name: static-ip-lb
spec:
  loadBalancerIP: ${PUBLIC_IP}
  type: LoadBalancer
  ports:
  - port: 443
  selector:
    app: static-ip-lb
EOF
```

Feel free to further modify this output (which is saved in your current directory as `pip-service.yaml`).

Finally, apply the service configuration to the cluster by running the following command (note this will deploy the service directly into the current namespace):

```bash
oc apply -f ./pip-service.yaml
```

The cluster should provision the load balancer within a minute or two. You can verify this by running the following command:

```bash
oc describe service static-ip-lb
```

The output will look similar to this:

```
Name:                     static-ip-lb
Namespace:                example
Labels:                   <none>
Annotations:              service.beta.kubernetes.io/azure-load-balancer-resource-group: example-rg
Selector:                 app=static-ip-lb
Type:                     LoadBalancer
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       172.30.74.108
IPs:                      172.30.74.108
IP:                       20.168.220.211
LoadBalancer Ingress:     20.168.220.211
Port:                     port-8080  443/TCP
TargetPort:               8080/TCP
NodePort:                 port-8080  31616/TCP
Endpoints:                10.129.2.10:8080
Session Affinity:         None
External Traffic Policy:  Cluster
Events:
  Type    Reason                Age   From                Message
  ----    ------                ----  ----                -------
  Normal  EnsuringLoadBalancer  31m   service-controller  Ensuring load balancer
  Normal  EnsuredLoadBalancer   31m   service-controller  Ensured load balancer
```

You can now access your load balancer using the IP address provided!

