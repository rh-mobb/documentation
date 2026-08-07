---
date: '2023-03-29'
title: Azure Front Door with ARO ( Azure Red Hat OpenShift )
tags: ["ARO"]
authors:
  - Kevin Collins
  - Diana Sari
---
Securely expose an Internet facing application on a private ARO Cluster using Azure Front Door.

When you create a cluster on ARO you have several options in making the cluster public or private.  With a public cluster you are allowing Internet traffic to the api and *.apps endpoints.  With a private cluster you can make either or both the api and .apps endpoints private.

How can you allow Internet access to an application running on your private cluster where the .apps endpoint is private?  This document will guide you through using Azure Front Door to expose your applications to the Internet.  There are several advantages of this approach, namely your cluster and all the resources in your Azure account can remain private, providing you an extra layer of security.  Azure Front Door operates at the edge so we are controlling traffic before it even gets into your Azure account.  On top of that, Azure Front Door also offers WAF and DDoS protection, certificate management and SSL offloading just to name a few benefits.

This guide uses SNI (Server Name Indication) so that Azure Front Door sends the correct hostname to the OpenShift router, allowing the router to match the request to the correct route.

*Adopted from [ARO Reference Architecture](https://github.com/UmarMohamedUsman/aro-reference-architecture)*


## Prerequisites
* az cli
* oc cli
* a custom domain
* a DNS zone that you can easily modify

Make sure to use the same terminal session while going through this guide for all commands as we will reference environment variables set or created throughout the guide.

## Get Started

  * Create a private ARO cluster.

    Follow this guide to [Create a private ARO cluster](/experts/aro/private-cluster)
    or simply run this [bash script](../private-cluster/create-cluster.sh)

## Set Environment Variables

1. Manually set environment variables

   ```bash
   AROCLUSTER=<cluster name>

   ARORG=<resource group for the cluster>

   AFD_NAME=<name you want to use for the front door instance>

   DOMAIN='e.g. aro.kmobb.com'

   ARO_APP_FQDN='e.g. hello.aro.kmobb.com'

   AFD_CUSTOM_DOMAIN_NAME='hello-aro-kmobb-com'
   ```

   > `DOMAIN` is the domain you will be adding to Azure DNS to manage.
   >
   > `ARO_APP_FQDN` is the FQDN you want for your application, e.g. `hello.aro.kmobb.com`.
   >
   > `AFD_CUSTOM_DOMAIN_NAME` is your FQDN with dots replaced by dashes, e.g. `hello-aro-kmobb-com`.

1. Set environment variables with Bash

   ```bash
   UNIQUEID=$RANDOM

   ARO_RGNAME=$(az aro show -n $AROCLUSTER -g $ARORG --query "clusterProfile.resourceGroupId" -o tsv | sed 's/.*\///')

   LOCATION=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query location -o tsv)

   INTERNAL_LBNAME=$(az network lb list --resource-group $ARO_RGNAME --query "[? contains(name, 'internal')].name" -o tsv)

   WORKER_SUBNET_NAME=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query 'workerProfiles[0].subnetId' -o tsv | sed 's/.*\///')

   WORKER_SUBNET_ID=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query 'workerProfiles[0].subnetId' -o tsv)

   VNET_NAME=$(az network vnet list -g $ARORG --query '[0].name' -o tsv)

   LBCONFIG_ID=$(az network lb frontend-ip list -g $ARO_RGNAME --lb-name $INTERNAL_LBNAME --query "[? contains(subnet.id,'$WORKER_SUBNET_ID')].id" -o tsv)

   LBCONFIG_IP=$(az network lb frontend-ip list -g $ARO_RGNAME --lb-name $INTERNAL_LBNAME --query "[? contains(subnet.id,'$WORKER_SUBNET_ID')].privateIPAddress" -o tsv)

   APPS_DOMAIN=$(az aro show -n $AROCLUSTER -g $ARORG --query 'consoleProfile.url' -o tsv | sed 's|https://console-openshift-console.||;s|/||')

   ARO_ROUTE_HOST=hello-openshift.$APPS_DOMAIN
   ```
## Create a Private Link Service
After we have the cluster up and running, we need to create a private link service.  The private link service will provide private and secure connectivity between the Front Door Service and our cluster.

1. Disable the worker subnet private link service network policy for the worker subnet

   ```bash
   az network vnet subnet update \
   --disable-private-link-service-network-policies true \
   --name $WORKER_SUBNET_NAME \
   --resource-group $ARORG \
   --vnet-name $VNET_NAME
   ```

1. Create a private link service targeting the worker subnets

   ```bash
   az network private-link-service create \
   --name $AROCLUSTER-pls \
   --resource-group $ARORG \
   --private-ip-address-version IPv4 \
   --private-ip-allocation-method Dynamic \
   --vnet-name $VNET_NAME \
   --subnet $WORKER_SUBNET_NAME \
   --lb-frontend-ip-configs $LBCONFIG_ID

   privatelink_id=$(az network private-link-service show -n $AROCLUSTER-pls -g $ARORG --query 'id' -o tsv)
   ```

## Create and Configure an instance of Azure Front Door
1. Create a Front Door Instance

   ```bash
   az afd profile create \
   --resource-group $ARORG \
   --profile-name $AFD_NAME \
   --sku Premium_AzureFrontDoor

   afd_id=$(az afd profile show -g $ARORG --profile-name $AFD_NAME --query 'id' -o tsv)
   ```

1. Create an endpoint for the ARO Internal Load Balancer

   ```bash
   az afd endpoint create \
   --resource-group $ARORG \
   --enabled-state Enabled \
   --endpoint-name 'aro-ilb'$UNIQUEID \
   --profile-name $AFD_NAME
   ```

1. Create a Front Door Origin Group that will point to the ARO Internal Loadbalancer

   ```bash
   az afd origin-group create \
   --origin-group-name 'afdorigin' \
   --probe-path '/' \
   --probe-protocol Https \
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

   Both `--host-name` and `--origin-host-header` must use the cluster's apps wildcard domain (e.g. `hello-openshift.apps.<cluster-domain>`). Azure Front Door requires certificate name verification (`enforceCertificateNameCheck`) for private link origins, and the OpenShift router's wildcard certificate only covers `*.apps.<cluster-domain>`, not your custom domain or the load balancer's IP address. Using the apps domain ensures the certificate check passes and the OpenShift router can match the request via SNI.

   ```bash
   az afd origin create \
   --enable-private-link true \
   --private-link-resource $privatelink_id \
   --private-link-location $LOCATION \
   --private-link-request-message 'Private link service from AFD' \
   --weight 1000 \
   --priority 1 \
   --http-port 80 \
   --https-port 443 \
   --origin-group-name 'afdorigin' \
   --enabled-state Enabled \
   --host-name $ARO_ROUTE_HOST \
   --origin-host-header $ARO_ROUTE_HOST \
   --origin-name 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG
   ```

   > **Note:** If your az CLI version does not recognize `--enable-private-link`, use the `--shared-private-link-resource` parameter instead:
   > ```
   > --shared-private-link-resource "{\"private-link\":{\"id\":\"$privatelink_id\"},\"private-link-location\":\"$LOCATION\",\"request-message\":\"Private link service from AFD\"}"
   > ```

1. Approve the private link connection

   ```bash
   privatelink_pe_id=$(az network private-link-service show -n $AROCLUSTER-pls -g $ARORG --query 'privateEndpointConnections[0].id' -o tsv)

   az network private-endpoint-connection approve \
   --description 'Approved' \
   --id $privatelink_pe_id
   ```

1. Add your custom domain to Azure Front Door

   ```bash
   az afd custom-domain create \
   --certificate-type ManagedCertificate \
   --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME \
   --host-name $ARO_APP_FQDN \
   --minimum-tls-version TLS12 \
   --profile-name $AFD_NAME \
   --resource-group $ARORG

   custom_domain_id=$(az afd custom-domain show -g $ARORG \
   --profile-name $AFD_NAME \
   --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME \
   --query 'id' -o tsv)
   ```

1. Create an Azure Front Door endpoint for your custom domain

   ```bash
   az afd endpoint create \
   --resource-group $ARORG \
   --enabled-state Enabled \
   --endpoint-name 'aro-hello-'$UNIQUEID \
   --profile-name $AFD_NAME
   ```

1. Add an Azure Front Door route for your custom domain

   The `--forwarding-protocol HttpsOnly` ensures Front Door connects to the origin over HTTPS, which is required for SNI: the OpenShift router uses the TLS SNI extension to match incoming requests to the correct route.

   ```bash
   az afd route create \
   --endpoint-name 'aro-hello-'$UNIQUEID \
   --forwarding-protocol HttpsOnly \
   --https-redirect Enabled \
   --origin-group 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG \
   --route-name 'aro-hello-route' \
   --supported-protocols "[Http,Https]" \
   --patterns-to-match "[/*]" \
   --formatted-custom-domains "[{\"id\":\"$custom_domain_id\"}]"
   ```

1. Update DNS

   Get a validation token from Front Door so Front Door can validate your domain

   ```bash
   afdToken=$(az afd custom-domain show \
   --resource-group $ARORG \
   --profile-name $AFD_NAME \
   --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME \
   --query "validationProperties.validationToken" \
   -o tsv)
   ```

1. Create a DNS Zone

   ```bash
   az network dns zone create -g $ARORG -n $DOMAIN
   ```

   > You will need to configure your nameservers to point to Azure. The output of running this zone create will show you the nameservers for this record that you will need to set up within your domain registrar.

   Create a new text record in your DNS server

   ```bash
   az network dns record-set txt add-record \
   -g $ARORG -z $DOMAIN \
   -n _dnsauth.$(echo $ARO_APP_FQDN | sed 's/\..*//') \
   --value $afdToken \
   --record-set-name _dnsauth.$(echo $ARO_APP_FQDN | sed 's/\..*//')
   ```

1. Check if the domain has been validated:

   > Note: this can take several hours. Your FQDN will not resolve until Front Door validates your domain.

   ```bash
   az afd custom-domain list -g $ARORG --profile-name $AFD_NAME \
   --query "[? contains(hostName, '$ARO_APP_FQDN')].domainValidationState"
   ```

1. Add a CNAME record to DNS

   Get the Azure Front Door endpoint:

   ```bash
   afdEndpoint=$(az afd endpoint show -g $ARORG --profile-name $AFD_NAME \
   --endpoint-name aro-hello-$UNIQUEID --query "hostName" -o tsv)
   ```

   Create a CNAME record for the application

   ```bash
   az network dns record-set cname set-record -g $ARORG -z $DOMAIN \
   -n $(echo $ARO_APP_FQDN | sed 's/\..*//') -z $DOMAIN -c $afdEndpoint
   ```
## Deploy an Application

Now let's deploy a simple application to verify the Front Door configuration.

1. Log into your OpenShift cluster

   > Before you deploy your application, you will need to be connected to a private network that has access to the cluster.

   A great way to establish this connectivity is with a VPN connection.  Follow this [guide](/experts/aro/vpn/) to setup a VPN connection with your Azure account.

   ```bash
   kubeadmin_password=$(az aro list-credentials --name $AROCLUSTER --resource-group $ARORG --query kubeadminPassword --output tsv)

   apiServer=$(az aro show -g $ARORG -n $AROCLUSTER --query apiserverProfile.url -o tsv)

   oc login $apiServer -u kubeadmin -p $kubeadmin_password
   ```

1. Create a new OpenShift project and deploy the hello-openshift application

   ```bash
   oc new-project hello-openshift

   oc new-app --image=quay.io/openshift/origin-hello-openshift --name=hello-openshift
   ```

1. Create a TLS edge-terminated route using the apps wildcard domain

   The route uses the cluster's apps wildcard domain as its hostname. This matches what Front Door sends via SNI (`--origin-host-header`) and is covered by the OpenShift router's wildcard TLS certificate. Front Door handles the translation from your custom domain to this hostname automatically.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: route.openshift.io/v1
   kind: Route
   metadata:
     name: hello-openshift
     namespace: hello-openshift
   spec:
     host: $ARO_ROUTE_HOST
     tls:
       termination: edge
       insecureEdgeTerminationPolicy: Redirect
     to:
       kind: Service
       name: hello-openshift
       weight: 100
     port:
       targetPort: 8080-tcp
     wildcardPolicy: None
   EOF
   ```

1. Check the DNS settings of your application

   > Notice that the application URL is routed through Azure Front Door at the edge.  The only way this application running on your cluster can be accessed is through Azure Front Door which is connected to your cluster through a private endpoint.

   ```bash
   nslookup $ARO_APP_FQDN
   ```

   Sample output:

   ```
   Non-authoritative answer:
   hello.aro.kmobb.com	canonical name = aro-hello-13947-dxh0ahd7fzfyexgx.z01.azurefd.net.
   aro-hello-13947-dxh0ahd7fzfyexgx.z01.azurefd.net	canonical name = star-azurefd-prod.trafficmanager.net.
   star-azurefd-prod.trafficmanager.net	canonical name = dual.part-0013.t-0009.t-msedge.net.
   dual.part-0013.t-0009.t-msedge.net	canonical name = part-0013.t-0009.t-msedge.net.
   Name:	part-0013.t-0009.t-msedge.net
   Address: 13.107.213.41
   ```

## Test the Application

Point your browser to your custom domain (e.g. `https://hello.aro.kmobb.com`). You should see "Hello OpenShift!".

## Verify SNI is Working

To prove that SNI is the mechanism allowing the OpenShift router to match the request, temporarily change the `--origin-host-header` to a hostname that doesn't match any route. Without a matching hostname, the OpenShift router cannot route the request.

1. Set the origin-host-header to a non-matching hostname

   ```bash
   az afd origin update \
   --origin-name 'afdorigin' \
   --origin-group-name 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG \
   --origin-host-header 'does-not-exist.'$APPS_DOMAIN
   ```

1. Test the application (it should fail)

   ```bash
   curl -s -o /dev/null -w "%{http_code}" https://$ARO_APP_FQDN
   ```

   You should receive a `503` (Service Unavailable) because the OpenShift router cannot match the incoming hostname to any route.

1. Restore the origin-host-header

   ```bash
   az afd origin update \
   --origin-name 'afdorigin' \
   --origin-group-name 'afdorigin' \
   --profile-name $AFD_NAME \
   --resource-group $ARORG \
   --origin-host-header $ARO_ROUTE_HOST
   ```

1. Test again (it should work)

   ```bash
   curl -s -o /dev/null -w "%{http_code}" https://$ARO_APP_FQDN
   ```

   You should receive a `200` confirming that SNI is what allows the OpenShift router to correctly route traffic from Azure Front Door to your application.

## How SNI Works in This Configuration

The SNI flow through Azure Front Door to your private ARO cluster works as follows:

1. **Client → Front Door**: The client connects to Azure Front Door using your custom domain (e.g. `hello.aro.kmobb.com`). Front Door terminates TLS and presents its managed certificate for your custom domain.
2. **Front Door → Origin (Private Link)**: Front Door opens a new HTTPS connection to the origin (the ARO internal load balancer) over the private link. Because `--origin-host-header` is set to the app's route hostname under the cluster's apps wildcard domain, Front Door sends that hostname in both the TLS SNI extension and the HTTP Host header. The OpenShift router's wildcard certificate (`*.apps.<cluster-domain>`) matches this hostname, satisfying Front Door's mandatory certificate name check for private link origins.
3. **OpenShift Router**: The OpenShift router receives the connection, reads the SNI hostname, and matches it to the correct route (your `hello-openshift` route with `host: hello-openshift.apps.<cluster-domain>`).
4. **Router → Pod**: The router terminates TLS (edge termination) and forwards the request as HTTP to the hello-openshift pod.

The custom domain (`hello.aro.kmobb.com`) is only used between the client and Front Door. Between Front Door and the origin, the apps wildcard domain is used so the OpenShift router's TLS certificate is valid for the connection.

## Clean Up

To clean up everything you created, simply delete the resource group

```bash
az group delete -g $ARORG
```
