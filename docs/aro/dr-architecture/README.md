# ARO Disaster Recovery Architecture

This is a high level overview of a basic disaster recovery architecture for Azure Red Hat OpenShift. It is not a detailed design, but rather a starting point for a basing a custom disaster recovery solution to suit your needs.

## Multi-Region Disaster Recovery

An ARO cluster can be deployed into Multiple Availability Zones (AZs) in a single region. To protect your applications from region failure you must deploy your application into multiple ARO clusters across different regions. Here are some considerations:

* Start with a solid and tested Backup/Restore manual cutover DR solution
* Decide on RPO/RTO (Recovery Point Objective / Recovery Time Objective) for DR
* Decide whether your regions should be hot/hot, hot/warm, or hot/cold.
* Choose regions close to your consumers.
* choose two ["paired" regions](https://docs.microsoft.com/en-us/azure/best-practices-availability-paired-regions).
* Use global virtual network peering to connect your networks together.
* Use Front Door or Traffic Manager to route *public* traffic to the correct region.
* Enable geo-replication for container images (If using ACR).
* Remove service state from inside containers.
* Create a storage migration plan.

## Backup and Restore - Manual Cutover ( Hot / Cold )

Do you currently have the ability to do a point in time restore of Backups of your applications?

1. Create a backup of your Kubernetes cluster

    Using a tool like Velero or Portworx, you can create a backup of the current state of your Kubernetes resources and their persistent volumes. If you restore these backups to a new cluster and manually cutover the DNS, will your applications be full functional?

1. Create backups of any regionally co-located resources (like Redis, Postgres, etc.).

    Some Azure PaaS services such as Azure Container Registry can replicate to another region which may assist in performing backups or restore. This replication is often one way, therefore a new replication relationship must be created from the new region to another for the next DR event.

1. If using DNS based failover, make sure TTLs are set to a suitable value.

1. Determine if Non-regionally co-located resources (such as SaaS products) have appropriate failover plans and ensure that any special networking arrangements are available at the DR region.


## Failover to an existing cluster in the DR region (Hot / Warm)

In a Hot / Warm situation the destination cluster should be similar to the the source cluster, but for financial reasons may be smaller, or be single AZ. If this is the case you may either run the DR cluster with lower expectations on performance and resiliance with the idea of failing back to the original cluster ASAP, or you will expand the DR cluster to match the original cluster and turn the original cluster into the next DR site.

The following examples assume a Hot / Warm scenario where the clusters are the same size.

### Create a Primary Cluster

1. Set the following environment variables:

    ```
    AZR_RESOURCE_LOCATION=eastus
    AZR_RESOURCE_GROUP=ARO-DR-1
    AZR_CLUSTER=ARODR1
    AZR_PULL_SECRET=~/Downloads/pull-secret.txt
    NETWORK_SUBNET=10.0.0.0/20
    CONTROL_SUBNET=10.0.0.0/24
    MACHINE_SUBNET=10.0.1.0/24
    FIREWALL_SUBNET=10.0.2.0/24
    JUMPHOST_SUBNET=10.0.3.0/24

    ```

1. Complete the rest of the step to create networks and cluster following the [Private ARO cluster](../private-cluster.md)

### Create a Secondary Cluster


1. Set the following environment variables:

    ```
    AZR_RESOURCE_LOCATION=centralus
    AZR_RESOURCE_GROUP=ARO-DR-2
    AZR_CLUSTER=ARODR2
    AZR_PULL_SECRET=~/Downloads/pull-secret.txt
    NETWORK_SUBNET=10.1.0.0/20
    CONTROL_SUBNET=10.1.0.0/24
    MACHINE_SUBNET=10.1.1.0/24
    FIREWALL_SUBNET=10.1.2.0/24
    JUMPHOST_SUBNET=10.1.3.0/24
    ```

1. Complete the rest of the step to create networks and cluster following the [Private ARO cluster](../private-cluster.md)

### Connect the clusters via Virtual Network Peering

Virtual network peering allows two Azure regions to connect to each other via a virtual network. Ideally you will use a [Hub-Spoke](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/hybrid-networking/hub-spoke?tabs=cli) topology and create appropriate [firewalling in the Hub network](https://docs.microsoft.com/en-us/azure/firewall-manager/secure-hybrid-network) but that is an excercise left for the reader and here we're creating a simple open peering between the two networks.

1. Get the ID of the two networks you created in the previous step.

    ```
    DR1_VNET=$(az network vnet show \
      --resource-group ARO-DR-1 \
      --name ARODR1-aro-vnet-eastus \
      --query id --out tsv)
    echo $DR1_VNET

    DR2_VNET=$(az network vnet show \
      --resource-group ARO-DR-2 \
      --name ARODR2-aro-vnet-centralus \
      --query id --out tsv)
    echo $DR2_VNET
    ```

1. Create peering from the Primary network to the Secondary network.

    ```
    az network vnet peering create \
      --name primary-to-secondary \
      --resource-group ARO-DR-1 \
      --vnet-name ARODR1-aro-vnet-eastus \
      --remote-vnet $DR2_VNET \
      --allow-vnet-access
    ```

1. Create peering from the Secondary network to the Primary network.

    ```
    az network vnet peering create \
      --name secondary-to-primary \
      --resource-group ARO-DR-2 \
      --vnet-name ARODR2-aro-vnet-centralus \
      --remote-vnet $DR1_VNET \
      --allow-vnet-access
    ```

1. Verify that the Jump Host in the Primary region is able to reach the Jump Host in the Secondary region.

    ```
    ssh -i $HOME/.ssh/id_rsa aro@$JUMP_IP ping 10.1.3.4
    ```

    ```
    PING 10.1.3.4 (10.1.3.4) 56(84) bytes of data.
    64 bytes from 10.1.3.4: icmp_seq=1 ttl=64 time=23.8 ms
    64 bytes from 10.1.3.4: icmp_seq=2 ttl=64 time=23.10 ms
    ```

1. ssh to jump host forwarding port 1337 as a socks proxy.

    ```
    ssh -D 1337 -C -i $HOME/.ssh/id_rsa aro@$JUMP_IP
    ```

1. configure localhost:1337 as a socks proxy in your browser and access the two consoles.

From here the two clusters are visible to each other via their frontends. This means they can access eachother's ingress endpoints, routes and Load Balancers, but not pod-to-pod. A PostgreSQL pod in the primary cluster could replicate to a PostgreSQL pod in the secondary cluster via a service of type LoadBalancer.

### Cross Region Registry Replication

Openshift comes with a local registry that is used for local builds etc, but it is likely
that you use a centralized registry for your own applications and images. Ensure that your registry supports replication to the DR region. Ensure that you understand if it supports active/active replication or if its a one way replication.

In a Hot/Warm scenario where you'll only ever use the DR region as a backup to the primary region its likely okay for one-way replication to be used.

* [Redhat Quay](https://access.redhat.com/documentation/en-us/red_hat_quay/2.9/html/manage_red_hat_quay/georeplication-of-storage-in-quay)
* [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-geo-replication) (must use Premium SKU for geo-replication)

#### Example - Create a ACR in the Primary Region

1. Create a new ACR in the primary region.

    ```
    az acr create --resource-group ARO-DR-1 \
      --name acrdr1 --sku Premium
    ```

1. Log into and push an Image to the ACR.

    ```bash
    az acr login --name acrdr1
    docker pull mcr.microsoft.com/hello-world
    docker tag mcr.microsoft.com/hello-world acrdr1.azurecr.io/hello-world:v1
    docker push acrdr1.azurecr.io/hello-world:v1
    ```

1. Replicate the registry to the DR2 region.

    ```
    az acr replication create --location centralus --registry acrdr1
    ```

1. Wait a few moments and then check the replication status.

    ```
    az acr replication show --name centralus  --registry acrdr1 --query status
    ```

### Red Hat Advanced Cluster Management

Advanced Cluster Management (ACM) is a set of tools that can be used to manage the lifecycle of multiple OpenShift clusters. ACM gives you a single view into your clusters and provides
gitops style management of you workloads and also has compliance features.

You can run ACM from a central infrastructure (or your Primary DR) cluster and connect your ARO clusters to it.

### DR for Application Ingress

If you want to expose your Applications to the internet you can use Azure's Front Door or Traffic Manager resources which you can use to fail the routing over to the DR site.

However if you are running private clusters your choices are a bit more limited.

* You could provide people with the application ingress URL for each cluster and expect them to know to use the DR one if the Primary is down
* You can add a custom domain (and TLS certificate) and use your internal DNS to switch from the Primary to the DR site.
* You can provision a Load Balancer in your network that you can point the custom domain at and use that to switch from the Primary to the DR site as needed.

Example using simple DNS:

1. Create a new wildcard DNS record with a low TTL pointing to the Primary Cluster's Ingress/Route ExternalIP in your private DNS zone. (in our case it was *.aro-dr.mobb.ninja)

1. Modify the route for both apache examples to use the new wildcard DNS record.

1. Test access

1. Update the DNS record to point to the DR site's Ingress/Route ExternalIP.

1. Test access

