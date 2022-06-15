# ARO Custom domain with cert-manager and LetsEncrypt

ARO guide to deploying an ARO cluster with custom domain and automating certificate management with cert-manager and letsencrypt certificates.

Author: [Byron Miller](https://twitter.com/byron_miller)

## Prerequisites

* az cli
* oc cli
* jq
* gettext
* OpenShift 4.10
* domain name to use

I'm going to be running this setup through Fedora in WSL2. Be sure to always use the same terminal/session for all commands since we'll reference environment variables set or created through the steps.

**Fedora Linux**

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

1. Install jq & gettext

I'm going to reply on using shell variables interpolated into Kubernetes config and jq to build variables. Installing or ensuring the gettext & jq package is installed will allow us to use envsubst to simplify some of our configuration so we can use output of CLI's as input into Yamls to reduce the complexity of manual editing.


    ```bash
sudo dnf install gettext jq
    ```

### Prepare Azure Account for Azure OpenShift

1. Log into the Azure CLI by running the following and then authorizing through your Web Browser

    ```bash
az login
    ```

1. Register resource providers

    ```bash
az provider register -n Microsoft.RedHatOpenShift --wait
az provider register -n Microsoft.Compute --wait
az provider register -n Microsoft.Storage --wait
az provider register -n Microsoft.Authorization --wait
    ```

### Get Red Hat pull secret

1. Log into cloud.redhat.com

1. Browse to https://cloud.redhat.com/openshift/install/azure/aro-provisioned

1. click the **Download pull secret** button and remember where you saved it, you'll reference it later.


## Deploy Azure OpenShift

### Variables and Resource Group

Set some environment variables to use later, and create an Azure Resource Group.

1. Set the following environment variables

These should already be set from above, but if you opened a new shell - please set/verify.

    > Change the values to suit your environment, but these defaults should work.

    ```bash
PULL_SECRET=./pull-secret.txt    # the path to pull-secret
LOCATION=southcentralus          # the location of your cluster
RESOURCEGROUP=aro-rg             # the name of the resource group where you want to create your cluster
CLUSTER=aro-cluster              # the name of your cluster
DOMAIN=lab.openshiftdemo.dev     # Domain or subdomain zone for cluster & cluster api
    ```

1. Create an Azure resource group

    ```bash
az group create \
  --name $RESOURCEGROUP \
  --location $LOCATION
    ```


### Networking

Create a virtual network with two empty subnets

1. Create virtual network

    ```bash
az network vnet create \
   --resource-group $RESOURCEGROUP \
   --name aro-vnet \
   --address-prefixes 10.0.0.0/22
    ```

1. Create control plane subnet

    ```bash
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name master-subnet \
  --address-prefixes 10.0.0.0/23 \
  --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create machine subnet

    ```bash
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name worker-subnet \
  --address-prefixes 10.0.2.0/23 \
  --service-endpoints Microsoft.ContainerRegistry
    ```

1. Disable network policies on the control plane subnet

    > This is required for the service to be able to connect to and manage the cluster.

    ```bash
az network vnet subnet update \
  --name master-subnet \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --disable-private-link-service-network-policies true
    ```

1. Create the cluster

    > This will take between 30 and 45 minutes.

    ```bash
az aro create \
  --resource-group $RESOURCEGROUP \
  --name $CLUSTER \
  --vnet aro-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --pull-secret @$AZR_PULL_SECRET \
  --domain $DOMAIN
      ```


1. Wait until the ARO cluster is fully provisioned.

1. Get OpenShift console URL

    > set these variables to match the ones you set at the start.

    ```bash
az aro show -g $RESOURCEGEOUP -n $CLUSTER --query "consoleProfile.url" -o tsv
    ```

1. Get OpenShift credentials

    ```bash
az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP
    ```

## Create DNS Zones & Service Principal

In order for cert-manager to work with AzureDNS, we need to create the zone and add a CAA record as well as create a Service Principal that we can use to manage records in this zone so CertManager can use DNS01 authentication for validating requests.

This zone should be a public zone since letsencrypt will need to be able to read records created here.

1. Set Env

    Set environment variables we'll use as we progress through installation.

    * DOMAIN = your domain name.
        I use lab.openshiftdemo.dev  - My API will be api.lab.openshiftdemo.dev and my apps will be
        apps.lab.openshiftdemo.dev
    * PULL_SECRET = reference to saved pull secret text file in current working directory
    * LOCATION = Azure Region
    * RESOURCEGROUP = ARO Resource Group
    * DNSRESOURCEGROUP = DNS resource group - can be same or different.
    * CLUSTER = Cluster Name
  

    ```bash
    DOMAIN=lab.openshiftdemo.dev
    PULL_SECRET=./pull-secret.txt
    LOCATION=southcentralus
    RESOURCEGROUP=aro-rg
    DNSRESOURCEGROUP=aro-dns
    CLUSTER=aro-cluster
    ```


2. Create Resource Group for zone

    ```bash
    az group create --name $DNSRESOURCEGROUP --location $LOCATION
    ```


3. Create Zone

    ```bash
    az network dns zone create -g $DNSRESOURCEGROUP -n $DOMAIN
    ```


4. Add CAA Record

    ```bash
    az network dns record-set caa add-record -g $DNSREOURCEGROUP -z $DOMAIN \
    -n MyRecordSet --flags 0 --tag "issuewild" --value "letsencrypt.org"
    ```

5. Set environment variables to build new service principal and credentials to allow cert-manager to create records in this zone.

    AZURE_CERT_MANAGER_NEW_SP_NAME = the name of the service principal created to manage these dns records.


    ```bash
    AZURE_CERT_MANAGER_NEW_SP_NAME=ar-dns-sp
    DNS_SP=$(az ad sp create-for-rbac --name $AZURE_CERT_MANAGER_NEW_SP_NAME --output json)
    AZURE_CERT_MANAGER_SP_APP_ID=$(echo $DNS_SP | jq -r '.appId')
    AZURE_CERT_MANAGER_SP_PASSWORD=$(echo $DNS_SP | jq -r '.password')
    AZURE_TENANT_ID=$(echo $DNS_SP | jq -r '.tenant')
    AZURE_SUBSCRIPTION_ID=$(az account show --output json | jq -r '.id')
    ```

6. Restrict service principal - remove contributor role.

    ```bash
    az role assignment delete --assignee $AZURE_CERT_MANAGER_SP_APP_ID --role Contributor
    ```

7. Assign SP to DNS zone

    ```bash
    $ DNS_ID=$(az network dns zone show --name $DOMAIN --resource-group $DNSRESOURCEGROUP --query "id" --output tsv)
    az role assignment create --assignee $AZURE_CERT_MANAGER_SP_APP_ID --role "DNS Zone Contributor" --scope $DNS_ID
    ```

8. Create azuredns-config secret for storing service principal creds to manage zone.

    ```bash
    kubectl create secret generic azuredns-config --from-literal=client-secret=$AZURE_CERT_MANAGER_SP_PASSWORD -n openshift-cert-manager
    ```

## Set up Cert-Manager

We'll install cert-manager and configure the DNS01 authorization for certificate automation. We use DNS01 authorization so we don't have to manage or expose a public web service, but rely on a public DNS zone.


1. Create namespace

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
    annotations:
        openshift.io/display-name:  Red Hat Certificate Manager Operator
    labels:
        openshift.io/cluster-monitoring: 'true'
    name: openshift-cert-manager-operator
    EOF
    ```

1. Create Group

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
    name: openshift-cert-manager-operator
    spec: {}
    EOF
    ```

1. Create subscription for cert-manager operator

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
    name: openshift-cert-manager-operator
    namespace: openshift-cert-manager-operator
    spec:
    channel: tech-preview
    installPlanApproval: Automatic
    name: openshift-cert-manager-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    EOF
    ```

### Configure Certificate Requestor

1. Set ENV

    AZURE_CERT_MANAGER_NEW_SP_NAME=ar-dns-sp
    LETSENCRYPTEMAIL=your@work.com
    DNS_SP=$(az ad sp create-for-rbac --name $AZURE_CERT_MANAGER_NEW_SP_NAME --output json)
    AZURE_CERT_MANAGER_SP_APP_ID=$(echo $DNS_SP | jq -r '.appId')
    AZURE_CERT_MANAGER_SP_PASSWORD=$(echo $DNS_SP | jq -r '.password')
    AZURE_TENANT_ID=$(echo $DNS_SP | jq -r '.tenant')
    AZURE_SUBSCRIPTION_ID=$(az account show --output json | jq -r '.id')

1. Create Cluster Issuer

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
    name: letsencrypt-prod
    spec:
    acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: $LETSENCRYPTEMAIL
        # This key doesn't exist, cert-manager creates it
        privateKeySecretRef:
        name: prod-openshiftdemo-issuer-account-key
        solvers:
        - dns01:
            azureDNS:
            clientID: $AZURE_CERT_MANAGER_SP_APP_ID
            clientSecretSecretRef:
            # The following is the secret we created in Kubernetes. Issuer will use this to present challenge to Azure DNS.
                name: azuredns-config
                key: client-secret
            subscriptionID: $AZURE_SUBSCRIPTION_ID
            tenantID: $AZURE_TENANT_ID
            resourceGroupName: $DNSRESOURCEGROUP
            hostedZoneName: $DOMAIN
            # Azure Cloud Environment, default to AzurePublicCloud
            environment: AzurePublicCloud
    EOF
    ```

1. Configure API certificate

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
    name: openshift-api
    namespace: openshift-config
    spec:
    secretName: openshift-api-certificate
    issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer
    dnsNames:
    - api.$DOMAIN
    EOF
    ```


1.  Configure Wildcard Certificate

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
    name: openshift-wildcard
    namespace: openshift-ingress
    spec:
    secretName: openshift-wildcard-certificate
    issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer
    commonName: '*.apps.$DOMAIN'
    dnsNames:
    - '*.apps.$DOMAIN'
    EOF
    ```

    This will generate our API and wildcard certificate requests.  We'll now create two jobs that will install these certificates.

### Install API certificate job

1. Create cluster api cert job

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
    name: patch-cluster-api-cert
    rules:
    - apiGroups:
        - ""
        resources:
        - secrets
        verbs:
        - get
        - list
    - apiGroups:
        - config.openshift.io
        resources:
        - apiservers
        verbs:
        - get
        - list
        - patch
        - update
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
    name: patch-cluster-api-cert
    roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: patch-cluster-api-cert
    subjects:
    - kind: ServiceAccount
        name: patch-cluster-api-cert
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
    name: patch-cluster-api-cert
    ---
    apiVersion: batch/v1
    kind: Job
    metadata:
    name: patch-cluster-api-cert
    annotations:
        argocd.argoproj.io/hook: PostSync
        argocd.argoproj.io/hook-delete-policy: HookSucceeded
    spec:
    template:
        spec:
        containers:
            - image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            env:
                - name: API_HOST_NAME
                value: api.home.ocplab.com
            command:
                - /bin/bash
                - -c
                - |
                #!/usr/bin/env bash
                if oc get secret openshift-api-certificate -n openshift-config; then
                    oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates": [{"names": ["'$API_HOST_NAME'"], "servingCertificate": {"name": "openshift-api-certificate"}}]}}}'
                else
                    echo "Could not execute sync as secret 'openshift-api-certificate' in namespace 'openshift-config' does not exist, check status of CertificationRequest"
                    exit 1
                fi
            name: patch-cluster-api-cert
        dnsPolicy: ClusterFirst
        restartPolicy: Never
        terminationGracePeriodSeconds: 30
        serviceAccount: patch-cluster-api-cert
        serviceAccountName: patch-cluster-api-cert
    EOF
    ```

1. Install Wildcard Certificate Job

    ```yaml
    cat <<EOF | oc apply -f -
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
    name: patch-cluster-wildcard-cert
    rules:
    - apiGroups:
        - operator.openshift.io
        resources:
        - ingresscontrollers
        verbs:
        - get
        - list
        - patch
    - apiGroups:
        - ""
        resources:
        - secrets
        verbs:
        - get
        - list
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
    name: patch-cluster-wildcard-cert
    roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: patch-cluster-wildcard-cert
    subjects:
    - kind: ServiceAccount
        name: patch-cluster-wildcard-cert
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
    name: patch-cluster-wildcard-cert
    ---
    apiVersion: batch/v1
    kind: Job
    metadata:
    name: patch-cluster-wildcard-cert
    annotations:
        argocd.argoproj.io/hook: PostSync
        argocd.argoproj.io/hook-delete-policy: HookSucceeded
    spec:
    template:
        spec:
        containers:
            - image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            command:
                - /bin/bash
                - -c
                - |
                #!/usr/bin/env bash
                if oc get secret openshift-wildcard-certificate -n openshift-ingress; then
                    oc patch ingresscontroller default -n openshift-ingress-operator --type=merge --patch='{"spec": { "defaultCertificate": { "name": "openshift-wildcard-certificate" }}}'
                else
                    echo "Could not execute sync as secret 'openshift-wildcard-certificate' in namespace 'openshift-config' does not exist, check status of CertificationRequest"
                    exit 1
                fi
            name: patch-cluster-wildcard-cert
        dnsPolicy: ClusterFirst
        restartPolicy: Never
        terminationGracePeriodSeconds: 30
        serviceAccount: patch-cluster-wildcard-cert
        serviceAccountName: patch-cluster-wildcard-cert
    EOF
    ```


## Delete Cluster

Once you're done its a good idea to delete the cluster to ensure that you don't get a surprise bill.

1. Delete the cluster

    ```bash
    az aro delete -y \
      --resource-group $AZR_RESOURCE_GROUP \
      --name $AZR_CLUSTER
    ```

1. Delete the Azure resource group

    > Only do this if there's nothing else in the resource group.

    ```bash
    az group delete -y \
      --name $AZR_RESOURCE_GROUP
    ```

