# ARO Integration with Azure AD

A Quickstart guide to deploying an Azure Red Hat OpenShift cluster and integrating it with Azure AD.

Author: [Sohaib Azed]

## Prerequisites

### Azure CLI

**MacOS**

> See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos) for alternative install options.

1. Install Azure CLI using homebrew

    ```bash
    brew update && brew install azure-cli
    ```

**Linux**

> See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=dnf) for alternative install options.

1. Import the Microsoft Keys

    ```bash
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    ```

1. Add the Microsoft Yum Repository

    ```bash
    cat << EOF | sudo tee /etc/yum.repos.d/azure-cli.repo
    [azure-cli]
    name=Azure CLI
    baseurl=https://packages.microsoft.com/yumrepos/azure-cli
    enabled=1
    gpgcheck=1
    gpgkey=https://packages.microsoft.com/keys/microsoft.asc
    EOF
    ```

1. Install Azure CLI

    ```bash
    sudo dnf install -y azure-cli
    ```


### Prepare Azure Account for Azure OpenShift

1. Log into the Azure CLI by running the following and then authorizing through your Web Browser

    ```bash
    az login
    ```

1. Make sure you have enough Quota (change the location if you're not using `East US`)

    ```bash
    az vm list-usage --location "East US" -o table
    ```

    see [Addendum - Adding Quota to ARO account](#adding-quota-to-aro-account) if you have less than `36` Quota left for `Total Regional vCPUs`.

1. Register resource providers

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    ```

### Get Red Hat pull secret

> This step is optional, but highly recommended

1. Log into <https://console.redhat.com>

1. Browse to <https://console.redhat.com/openshift/install/azure/aro-provisioned>

1. click the **Download pull secret** button and remember where you saved it, you'll reference it later.

## Deploy Azure OpenShift

### Variables and Resource Group

Set some environment variables to use later, and create an Azure Resource Group.

1. Set the following environment variables

    > Change the values to suit your environment, but these defaults should work.

    ```bash
    RESOURCE_LOCATION=eastus
    RESOURCE_GROUP=openshift
    CLUSTER_NAME=cluster
    PULL_SECRET=~/pull-secret.txt
    SUBSCRIPTION_ID=xxxx-xxxx-xxxx-xxxx
    ```

1. Create an Azure resource group

    ```bash
    az group create \
    --name $RESOURCE_GROUP \
    --location $RESOURCE_LOCATION
    ```


### Networking

Create a virtual network with two empty subnets

1. Create virtual network

    ```bash
    az network vnet create \
      --address-prefixes 10.0.0.0/22 \
      --name "$CLUSTER_NAME-aro-vnet-$RESOURCE_LOCATION" \
      --resource-group $RESOURCE_GROUP
    ```

1. Create control plane subnet

    ```bash
    az network vnet subnet create \
      --resource-group $RESOURCE_GROUP \
      --vnet-name "$CLUSTER_NAME-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$CLUSTER_NAME-aro-control-subnet-$RESOURCE_LOCATION" \
      --address-prefixes 10.0.0.0/23 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create \
      --resource-group $RESOURCE_GROUP \
      --vnet-name "$CLUSTER_NAME-aro-vnet-$RESOURCE_LOCATION" \
      --name "$CLUSTER_NAME-aro-machine-subnet-$RESOURCE_LOCATION" \
      --address-prefixes 10.0.2.0/23 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Disable network policies on the control plane subnet

    > This is required for the service to be able to connect to and manage the cluster.

    ```bash
    az network vnet subnet update \
      --name "$CLUSTER_NAME-aro-control-subnet-$RESOURCE_LOCATION" \
      --resource-group $RESOURCE_GROUP \
      --vnet-name "$CLUSTER_NAME-aro-vnet-$RESOURCE_LOCATION" \
      --disable-private-link-service-network-policies true
    ```

### Create a Service Principal

1. Create service principal

    ```bash
    az ad sp create-for-rbac --role Contributor --name all-in-one-sp --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP
    ```
This command will return the "appID" and "Password" information of the service principal that we will need for the ARO4 create command later.

    ```
    {
    "appId": "8fcbe6c7-ee29-4061-bdea-9fbddc4f1a41",
    "displayName": "all-in-one-sp",
    "password": "q6w8Q~RFsjdrWgLP2s9LeL9czVF84PAuLvWtucx_",
    "tenant": "64dc69e4-d083-49fc-9569-ebece1dd1408"
    }
    ```
2. Add API permission to the service principal

    - Log in to Azure Portal
    - Go to Azure Active Directory
    - Click App registrations
    - Click "All applications"
    - Search for "all-in-one-sp"
    - Click "API permission"
    - Click "Add a permission"
    - Click "Microsoft Graph"
    - Click "Delegated Permissions"
    - Check "User.Read"
    - Click the "Add permission" button at the bottom.
    - Click "Grant admin consent ..."

### Create Cluster
1. Create the cluster

    > This will take between 30 and 45 minutes.

    ```bash
    az aro create \
      --resource-group $RESOURCE_GROUP \
      --name $CLUSTER_NAME \
      --vnet "$CLUSTER_NAME-aro-vnet-$RESOURCE_LOCATION" \
      --master-subnet "$CLUSTER_NAME-aro-control-subnet-$RESOURCE_LOCATION" \
      --worker-subnet "$CLUSTER_NAME-aro-machine-subnet-$RESOURCE_LOCATION" \
      --pull-secret @$PULL_SECRET
    ```

2. Get OpenShift console URL

    ```bash
    az aro show \
      --name $CLUSTER_NAME \
      --resource-group $RESOURCE_GROUP \
      -o tsv --query consoleProfile
    ```

3. Get OpenShift credentials

    ```bash
    az aro list-credentials \
      --name $CLUSTER_NAME \
      --resource-group $RESOURCE_GROUP \
      -o tsv
    ```

4. Use the URL and the credentials provided by the output of the last two commands to log into OpenShift via a web browser.


## Azure Active Driectory Integration 

1. Login to ARO via CLI
    ```bash
    oc login -u kubeadmin -p <password> https://api.<DNS domain>:6443/
    ```

2. Getting OAUTH callback URL
    ```bash
    oauthCallBack=`oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}'`
    oauthCallBackURL=https://$oauthCallBack/oauth2callback/AAD
    echo $oauthCallBackURL
    ```

**NOTE** 
AAD is the name of the identity provider when configuring OAuth on OpenShift


3. Add OAUTH Callback URL to the same service principal
    - Go to Azure Active Directory
    - Click App registration
    - Click on "all-in-one-sp" under all applications
    - Under Overview, click right top corner link for "Add a Redirect URI"
    - Click Web Application from the list of Configure platforms
    - Enter the value of the $oauthCallBackURL from the previous step to the "Redirect URIs"
    - Click configure

4. Update Service Principal with manifest
    ```
    az ad app update \
    --set optionalClaims.idToken=@manifest.json \
    --id <Service Principal appId>
    ```

5. Create a secret to stroe Service Principal Password
    ```
    oc create secret generic openid-client-secret-azuread \
    --namespace openshift-config \
    --from-literal=clientSecret=<service principal password>
    ```

6. Create an OAUTH configuration
    ```
    apiVersion: config.openshift.io/v1
    kind: OAuth
    metadata:
      name: cluster
    spec:
    identityProviders:
    - name: AAD
        mappingMethod: claim
        type: OpenID
        openID:
        clientID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        clientSecret:
            name: openid-client-secret-azuread
        extraScopes:
        - email
        - profile
        extraAuthorizeParameters:
            include_granted_scopes: "true"
        claims:
            preferredUsername:
            - email
            - upn
            name:
            - name
            email:
            - email
        issuer: https://login.microsoftonline.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ```

**NOTE**

    - The clientID is the AppId of your registered application.
    - Issuer URL is https://login.microsoftonline.com/<tenant id>.
    - The clientSecret is using the secret (openid-client-secret-azuread) that you created from the previous step.


7. Update ARO OAUTH configuration
    ```
    oc apply -f oauth
    ```

8. Login Openshift console VIA ADD
![](../images/ARO%2BADD.png)

### Grant users admin privilages.

Openshift cluster comes with a preconfigured role called "cluster-admin". You can create rolebinding to assign "cluster-admin" role to a Azure AD

    ```
    oc create clusterrolebinding azure-ad-cluster-admin --clusterrole=cluster-admin --user=<<Azure AD username>>
    ```

## Delete Cluster

Once you're done its a good idea to delete the cluster to ensure that you don't get a surprise bill.

1. Delete the cluster

    ```bash
    az aro delete -y \
      --resource-group $RESOURCE_GROUP \
      --name $CLUSTER_NAME
    ```

1. Delete the Azure resource group

    > Only do this if there's nothing else in the resource group.

    ```bash
    az group delete -y \
      --name $RESOURCE_GROUP
    ```