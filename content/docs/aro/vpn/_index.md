---
date: '2022-09-14T22:07:08.574151'
title: Setup a VPN Connection into an ARO Cluster with OpenVPN
---

**Kevin Collins**

*06/20/2022*

When you configure an Azure Red Hat OpenShift (ARO) cluster with a private only configuration, you will need connectivity to this private network in order to access your cluster. This guide will show you how to configute a point-to0-site VPN connection so you won't need to setup and configure Jump Boxes.

## Prerequisites

* a private ARO Cluster
* git
* openssl

## Create certificates to use for your VPN Connection
There are many ways and methods to create certificates for VPN, the guide below is one of the ways that works well.  Note, that whatever method you use, make sure it supports "X509v3 Extended Key Usage".

1. Clone OpenVPN/easy-rsa

   ```bash
   git clone https://github.com/OpenVPN/easy-rsa.git
   ```

1. Change to the easyrsa directory

   ```bash
   cd easy-rsa/easyrsa3
   ```

1. Initialize the PKI

   ```bash
   ./easyrsa init-pki
   ```

1. Edit certificate parameters

   Uncomment and edit the copied template with your values
   ```bash
   vim pki/vars
   ```

   ```
   set_var EASYRSA_REQ_COUNTRY   "US"
   set_var EASYRSA_REQ_PROVINCE  "California"
   set_var EASYRSA_REQ_CITY      "San Francisco"
   set_var EASYRSA_REQ_ORG       "Copyleft Certificate Co"
   set_var EASYRSA_REQ_EMAIL     "me@example.net"
   set_var EASYRSA_REQ_OU        "My Organizational Unit"
   ```

   Uncomment (remove the #) the folowing field
   ```
   #set_var EASYRSA_KEY_SIZE        2048
   ```

1. Create the CA:

   ```bash
   ./easyrsa build-ca nopass
   ```

1. Generate the Server Certificate and Key

   ```bash
   ./easyrsa build-server-full server nopass
   ```

1. Generate Diffie-Hellman (DH) parameters

   ```bash
   ./easyrsa gen-dh
   ```

1. Generate client credentials

   ```bash
   ./easyrsa build-client-full azure nopass
   ```

1. Set environment variables for the CA certificate you just created.

   ```bash
   CACERT=$(openssl x509 -in pki/ca.crt -outform der | base64)
   ```


## Set Envrionment Variables
```
AROCLUSTER=<cluster name>

ARORG=<resource group the cluster is in>

UNIQUEID=$RANDOM

LOCATION=$(az aro show --name $AROCLUSTER --resource-group $ARORG --query location -o tsv)

VNET_NAME=$(az network vnet list -g $ARORG --query '[0].name' -o tsv)

GW_NAME=${USER}_${VNET_NAME}

GW_SUBNET_PREFIX=e.g. 10.0.7.0/24 choose a new available subnet in the VNET your cluster is in.

VPN_PREFIX=172.18.0.0/24
```

## Create an Azure Virtual Network Gateway
1. Request a public IP Address

   ```bash
   az network public-ip create \
   -n $USER-pip-$UNIQUEID \
   -g $ARORG \
   --allocation-method Static \
   --sku Standard \
   --zone 1 2 3

   pip=$(az network public-ip show -g $ARORG --name $USER-pip-$UNIQUEID --query "ipAddress" -o tsv)
   ```

1. Create a Gateway Subnet

   ```bash
   az network vnet subnet create \
   --vnet-name $VNET_NAME \
   -n GatewaySubnet \
   -g $ARORG \
   --address-prefix $GW_SUBNET_PREFIX
   ```

1. Create a virtual network gateway

   ```bash
   az network vnet-gateway create \
   --name  $GW_NAME \
   --location $LOCATION \
   --public-ip-address $USER-pip-$UNIQUEID \
   --resource-group $ARORG \
   --vnet $VNET_NAME \
   --gateway-type Vpn \
   --sku VpnGw3AZ \
   --address-prefixes $VPN_PREFIX \
   --root-cert-data $CACERT \
   --root-cert-name $USER-p2s \
   --vpn-type RouteBased \
   --vpn-gateway-generation Generation2 \
   --client-protocol IkeV2 OpenVPN
   ```
> go grab a coffee, this takes about 15 - 20 minutes

## Configure your OpenVPN Client
1. Retrieve the VPN Settings

   From the Azure Portal - navigate to your Virtual Network Gateway, point to site configuration, and then click Download VPN Client.
   ![screenshot of download VPN client](./images/p2s.png)
   This will download a zip file containing the VPN Client

1. Create a VPN Client Configuration

   Uncompress the file you downloaded in the previous step and edit the OpenVPN\vpnconfig.ovpn file.
   >Note: The next two commands assume you are still in the easyrsa3 directory.

   In the vpnconfig.ovpn replace the $CLIENTCERTIFICATE line with the entire contents of:

   ```bash
   openssl x509 -in pki/issued/azure.crt
   ```
   Make sure to copy the -----BEGIN CERTIFICATE----- and the -----END CERTIFICATE----- lines.<br><br>

   also replace $PRIVATEKEY line with the output of:
   ```bash
   cat pki/private/azure.key
   ```
   Make sure to copy the -----BEGIN PRIVATE KEY----- and the -----END PRIVATE KEY----- lines.

1. add the new OpenVPN configuration file to your OpenVPN client.
   > mac users - just double click on the vpnserver.ovpn file and it will be automatically imported.

1. Connect your VPN.

   ![screenshot of Vpn Connected](./images/connect-vpn-settings.png)
