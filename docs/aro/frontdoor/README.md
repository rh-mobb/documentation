# Azure Front Door with ARO ( Azure Red Hat OpenShift )

# **** DRAFT ****
**Kevin Collins**
*Adopted from [ARO Reference Architecture](https://github.com/UmarMohamedUsman/aro-reference-architecturel)

*06/16/2022*

## Prerequisites

* a custom domain
* a DNS zone that you can easily modify

to build and deploy the application
[maven cli](https://maven.apache.org/install.html)
[quarkus cli](https://quarkus.io/guides/cli-tooling)
[OpenJDK Java 8](https://www.azul.com/downloads/?package=jdk) 

## Get Started

  * Create a private ARO cluster.<br>

    Follow this guide to [Create a private ARO cluster](https://mobb.ninja/docs/aro/private-cluster)
    or simply run this [bash script](
    https://github.com/rh-mobb/documentation/blob/main/docs/aro/private-cluster/create-cluster.sh)

## Set Evironment Variables

1. Manually set environment variables

   ```
   AROCLUSTER=<cluster name>

   ARORG=<cluster resource group>

   AFD_NAME=<name you want to use for the front door instance>

   ARO_APP_FQDN='e.g. minesweeper.custom.com'
   (note - we will be deploying an application called ratings app to test front door.  Select a domain you would like to use for the application.  For example minesweeper.aro.kmobb.com ... where kmobb.com is the domain you manage and have DNS access to.)

   AFD_MINE_CUSTOM_DOMAIN_NAME='minesweeper-aro-kmobb-com'
   (note - this should be your domain name without and .'s for example minesweeper-aro-kmobb-com)

   PRIVATEENDPOINTSUBNET_PREFIX= subnet in the VNET you cluster is in.  If you following the example above to create a custer where you virtual network is 10.0.0.0/20 then you can use '10.0.6.0/25' 

   PRIVATEENDPOINTSUBNET_NAME='PrivateEndpoint-subnet'
   ```

1. Set environment variables with Bash

   ```
   uniqueId=$RANDOM

   location=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query location -o tsv)

   aro_rgName='aro-'$(az aro show -n $AROCLUSTER -g $ARORG --query "clusterProfile.domain" -o tsv)

   internal_LbName=$(az network lb list --resource-group $aro_rgName --query "[? contains(name, 'internal')].name" -o tsv)

   worker_subnetName=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query 'workerProfiles[0].subnetId' -o tsv | sed 's/.*\///')

   worker_subnetId=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query 'workerProfiles[0].subnetId' -o tsv)

   vnet_name=$(az network vnet list -g $ARORG --query '[0].name' -o tsv)

   lbconfig_id=$(az network lb frontend-ip list -g $aro_rgName --lb-name $internal_LbName --query "[? contains(subnet.id,'$worker_subnetId')].id" -o tsv)

   lbconfig_ip=$(az network lb frontend-ip list -g $aro_rgName --lb-name $internal_LbName --query "[? contains(subnet.id,'$worker_subnetId')].privateIpAddress" -o tsv)

   ```
## Create a Private Link Service

1. Disable the worker subnet private link service network policy for the worker subnet

   ```
   az network vnet subnet update \
   --disable-private-link-service-network-policies true \
   --name $worker_subnetName \
   --resource-group $ARORG \
   --vnet-name $vnet_name
   ```

1. Create a private link service targeting the worker subnets
   ```
   az network private-link-service create \
   --name $AROCLUSTER-pls \
   --resource-group $ARORG \
   --private-ip-address-version IPv4 \
   --private-ip-allocation-method Dynamic \
   --vnet-name $vnet_name \
   --subnet $worker_subnetName \
   --lb-frontend-ip-configs $lbconfig_id

   privatelink_id=$(az network private-link-service show -n $AROCLUSTER-pls -g $ARORG --query 'id' -o tsv)
   ```

## Create and Configure an instance of Azure Front Door
1. Create a Front Door Instance  
   ```
   az afd profile create \
   --resource-group $ARORG \
   --profile-name $AFD_NAME \
   --sku Premium_AzureFrontDoor

   afd_id=$(az afd profile show -g $ARORG --profile-name $AFD_NAME --query 'id' -o tsv)
   ```

1. Create an endpoint for the ARO Internal Load Balancer
   ```
   az afd endpoint create \
   --resource-group $ARORG \
   --enabled-state Enabled \
   --endpoint-name 'aro-ilb'$uniqueId \
   --profile-name $AFD_NAME
   ```

1. Create a Front Door Origin Group that will point to the ARO Internal Loadbalancer
   ```
   az afd origin-group create \
   --origin-group-name 'afdorigin' \
   --probe-path '/' \
   --probe-protocol Http \
   --probe-request-type GET \
   --probe-interval-in-seconds 100 \
   --profile-name $AFD_NAME \
   --resource-group $ARORG \
   --probe-interval-in-seconds 120 \
   --sample-size 4 \
   --successful-samples-required 3 \
   --additional-latency-in-milliseconds 50
   ```

1. Create a Front Door Origin with the above Origin Group that will point to the ARO Internal Loadbalancer
   ```
   az afd origin create \
   --enable-private-link true \
   --private-link-resource $privatelink_id \
   --private-link-location $location \
   --private-link-request-message 'Private link service from AFD' \
   --weight 1000 \
   --priority 1 \
   --http-port 80 \
   --https-port 443 \
   --origin-group-name 'afdorigin' \
   --enabled-state Enabled \
   --host-name $lbconfig_ip \
   --origin-name 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG
   ```

1. Approve the private link connection
   ```
   privatelink_pe_id=$(az network private-link-service show -n $AROCLUSTER-pls -g $ARORG --query 'privateEndpointConnections[0].id' -o tsv)

   az network private-endpoint-connection approve \
   --description 'Approved' \
   --id $privatelink_pe_id
   ```

1. Add your custom domain to Azure Front Door
   ```
   az afd custom-domain create \
   --certificate-type ManagedCertificate \
   --custom-domain-name $AFD_MINE_CUSTOM_DOMAIN_NAME \
   --host-name $ARO_APP_FQDN \
   --minimum-tls-version TLS12 \
   --profile-name $AFD_NAME \
   --resource-group $ARORG

1. Add an Azure Front Door route for your custom domain
   ```
   az afd route create \
   --endpoint-name 'aro-mine-'$uniqueId \ 
   --forwarding-protocol HttpOnly \
   --https-redirect Disabled \
   --origin-group 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG \ 
   --route-name 'aro-mine-route' \
   --supported-protocols Http Https \ 
   --patterns-to-match '/*' \
   --custom-domains $AFD_MINE_CUSTOM_DOMAIN_NAME
   ```

1. Update DNS
   Get a validation token from Front Door so Front Door can validate your domain 

   ```
   az afd custom-domain show \
   --resource-group $ARORG \
   --profile-name $AFD_NAME \
   --custom-domain-name $AFD_MINE_CUSTOM_DOMAIN_NAME \
   --query "validationProperties.validationToken"
   ```

1. Create a new text record in your DNS server

   ```
   name: _dnsauth.minesweeper
   type: text
   value: <validation token from the previous command>
   ```

1. Check if the domain has been validated:
   ** Note this can take several hours **  
   Your FQDN will not resolve until Front Door validates your domain, this can several hours.

   ```
   az afd custom-domain list -g $ARORG --profile-name $AFD_NAME --query "[? contains(hostName, 'minesweeper.aro.kmobb.com')].domainValidationState"
   ```


## Deploy an application

1. Create a Azure Database for PostgreSQL servers service
   ```
   az postgres server create --name microsweeper-database --resource-group $ARORG --location $location --admin-user quarkus --admin-password r3dh4t1! --sku-name GP_Gen5_2

   POSTGRES_ID=$(az postgres server show -n microsweeper-database -g $ARORG --query 'id' -o tsv)
   ```


1. Create a private endpoint connecction for the database
   ```
   az network vnet subnet create \
   --resource-group $ARORG \
   --vnet-name $vnet_name \
   --name $PRIVATEENDPOINTSUBNET_NAME \
   --address-prefixes $PRIVATEENDPOINTSUBNET_PREFIX \
   --disable-private-endpoint-network-policies true

   az network private-endpoint create \
   --name 'postgresPvtEndpoint' \
   --resource-group $ARORG \
   --vnet-name $vnet_name \
   --subnet $PRIVATEENDPOINTSUBNET_NAME \
   --private-connection-resource-id $POSTGRES_ID \
   --group-id 'postgresqlServer' \
   --connection-name 'postgresdbConnection'
   ```
1. Create and configure a private DNS Zone for the Postgres database
   ```
   az network private-dns zone create \
   --resource-group $ARORG \
   --name 'privatelink.postgres.database.azure.com'

   az network private-dns link vnet create \
   --resource-group $ARORG \
   --zone-name 'privatelink.postgres.database.azure.com' \
   --name 'PostgresDNSLink' \
   --virtual-network $vnet_name\
   --registration-enabled false

   az network private-endpoint dns-zone-group create \
   --resource-group $ARORG \
   --name 'PostgresDb-ZoneGroup' \
   --endpoint-name 'postgresPvtEndpoint' \
   --private-dns-zone 'privatelink.postgres.database.azure.com' \
   --zone-name 'postgresqlServer'

   networkInterfaceId=$(az network private-endpoint show --name myPrivateEndpoint --resource-group myResourceGroup --query 'networkInterfaces[0].id' -o tsv)

   POSTGRES_IP=$(az resource show --ids $networkInterfaceId --api-version 2019-04-01 --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o tsv)

   az network private-dns record-set a create --name microsweeper-database --zone-name privatelink.postgres.database.azure.com --resource-group $ARORG  

   az network private-dns record-set a add-record --record-set-name microsweeper-database --zone-name privatelink.postgres.database.azure.com --resource-group $ARORG -a $POSTGRES_IP
   ```

1. Create a postgres database that will contain scores for the minesweeper application
   ```
   az postgres db create \
   --resource-group $ARORG \
   --name score \
   --server-name microsweeper-database
   ```


## Deploy the [minesweeper application](https://github.com/redhat-mw-demos/microsweeper-quarkus/tree/ARO)
1. Clone the git repository
   ```
   git clone -b ARO https://github.com/redhat-mw-demos/microsweeper-quarkus.git
   ```

1. Ensure Java 1.8 is set at your Java version
   ```
   mvn --version
   ``` 

   Look for Java version - 1.8XXXX
   if not set to Java 1.8 you will need to set your JAVA_HOME variable to Java 1.8 you have installed.  To find your java versions run:
   ```
   java -version
   ```
   then export your JAVA_HOME variable
   ```
   export JAVA_HOME=`/usr/libexec/java_home -v 1.8.0_332`
   ```

1. Log into your openshift cluster
   ```
   kubeadmin_password=$(az aro list-credentials --name $AROCLUSTER --resource-group $ARORG --query kubeadminPassword --output tsv)
   apiServer=$(az aro show -g $ARORG -n $AROCLUSTER --query apiserverProfile.url -o tsv)

   oc login $apiServer -u kubeadmin -p $kubeadmin_password
   ```

1. add the openshift extension to quarkus
   ```
   quarkus ext add openshift
   ```

1. Edit microsweeper-quarkus/src/main/resources/application.properties

   Make sure your file looks like the one below, changing the IP address on line 3 to private ip address of your postgres instance.
 
   To find your Postgres private IP address run the following commands:
   
   ```
   networkInterfaceId=$(az network private-endpoint show --name myPrivateEndpoint --resource-group myResourceGroup --query 'networkInterfaces[0].id' -o tsv)

   az resource show --ids $networkInterfaceId --api-version 2019-04-01 --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o ts
   ```

   Sample microsweeper-quarkus/src/main/resources/application.properties
   ```
   # Database configurations
   %prod.quarkus.datasource.db-kind=postgresql
   %prod.quarkus.datasource.jdbc.url=jdbc:postgresql://10.1.6.9:5432/score
   %prod.quarkus.datasource.jdbc.driver=org.postgresql.Driver
   %prod.quarkus.datasource.username=quarkus@microsweeper-database
   %prod.quarkus.datasource.password=r3dh4t1!
   %prod.quarkus.hibernate-orm.database.generation=drop-and-create
   %prod.quarkus.hibernate-orm.database.generation=update

   # OpenShift configurations
   %prod.quarkus.kubernetes-client.trust-certs=true
   %prod.quarkus.kubernetes.deploy=true
   %prod.quarkus.kubernetes.deployment-target=openshift
   #%prod.quarkus.kubernetes.deployment-target=knative
   %prod.quarkus.openshift.build-strategy=docker
   %prod.quarkus.openshift.expose=true

   # Serverless configurations
   #%prod.quarkus.container-image.group=microsweeper-%prod.quarkus
   #%prod.quarkus.container-image.registry=image-registry.openshift-image-registry.svc:5000

   # macOS configurations
   %prod.quarkus.native.container-build=true
   ```

1. Build and deploy the quarkus application to OpenShift
   ```
   quarkus build --no-tests
   ```
1. Update the route
   ```
   oc delete route microsweeper-appservice
   ```
   <B>Change the snippet below replacing your hostname for the host:</B>
   ```
   cat << EOF | oc apply -f -
   apiVersion: route.openshift.io/v1
   kind: Route
   metadata:
     labels:
       app.kubernetes.io/name: microsweeper-appservice
       app.kubernetes.io/version: 1.0.0-SNAPSHOT
       app.openshift.io/runtime: quarkus
     name: microsweeper-appservice
     namespace: microsweeper-quarkus
   spec:
     host: minesweeper.aro.kmobb.com
     to:
       kind: Service
       name: microsweeper-appservice
       weight: 100
       targetPort:
         port: 8080
     wildcardPolicy: None
   EOF
   ```

## Test the application
Point your browswer to your domain!!
<img src="images/minesweeper.png">

## Clean up
To clean up everything you created, simply delete the resource group
```
az group delete -g $ARORG
```