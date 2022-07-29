# Configure ARO to use Azure AD Group Claims #

**Michael McNeill**

*28 July 2022*

This guide demonstrates how to utilize the OpenID Connect group claim functionality implemented in OpenShift 4.10. This functionality allows an identity provider to provide a user's group membership for use within OpenShift. This guide will walk through the creation of an Azure Active Directory (Azure AD) application, configure the necessary Azure AD groups, and configure Azure Red Hat OpenShift (ARO) to authenticate and manage authorization using Azure AD. 

This guide will walk through the following steps:

1. Register a new application in Azure AD for authentication. 
2. Configure the application registration in Azure AD to include optional and group claims in tokens.
3. Configure the Azure Red Hat OpenShift (ARO) cluster to use Azure AD as the identity provider.

## Before you Begin

Create a set of security groups and assign users by following [the Microsoft documentation](https://docs.microsoft.com/en-us/azure/active-directory/fundamentals/active-directory-groups-create-azure-portal).

## 1. Register a new application in Azure AD for authenitcation

### Capture the OAuth callback URL
First, construct the cluster's OAuth callback URL and make note of it. To do so, run the following command, making sure to replace the variables specified:

The "AAD" directory at the end of the the OAuth callback URL should match the OAuth identity provider name you'll setup later.

```bash
RESOURCE_GROUPO=example-rg # Replace this with the name of your ARO cluster's resource group
CLUSTER_NAME=example-cluster # Replace this with the name of your ARO cluster
domain=$(az aro show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query clusterProfile.domain -o tsv)
location=$(az aro show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query location -o tsv)
echo "OAuth callback URL: https://oauth-openshift.apps.$domain.$location.aroapp.io/oauth2callback/AAD"
```

### Register a new application in Azure AD

Second, you need to create the Azure AD application itself. To do so, login to the Azure portal, and navigate to [App registrations blade](https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade), then click on "New registration" to create a new application.

[IMAGE]

Provide a name for the application, for example `openshift-auth`, and fill in the Redirect URI using the value of the OAuth callback URL you retrieved in step 1a earlier. Once you fill in the necessary information, click "Register" to create the application.

[IMAGE]

Then, click on the "Certificates & secrets" sub-blade and select "New client secret". Fill in the details request and make note of the generated secret key, as you'll use it in a later step. You won't be able to retrieve it again.

[IMAGE]

Then, click on the "Overview" sub-blade and make note of the "Application (client) ID" and "Directory (tenant) ID". You'll need those values in a later step as well.

## 2. Configure optional claims (for optional and group claims)

In order to provide OpenShift with enough information about the user to create their account, we will configure Azure AD to provide two optional claims, specifically "email" and "upn", as well as a group claim when a user logs in. For more information on optional claims in Azure AD, see [the Microsoft documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/active-directory-optional-claims).

Click on the "Token configuration" sub-blade and select the "Add optional claim" button. 

[IMAGE]

Select ID then check the "email" and "upn" claims and click the "Add" button to configure them for your Azure AD application. 

[IMAGE]

Next, select the "Add groups claim" button. 

[IMAGE]

Select the "Security groups" option and click the "Add" button to configure group claims for your Azure AD application. 

> **Note:** In this example, we are providing all security groups a user is a member of via the group claim. In a real production environment, we highly recommend _scoping the groups provided by the group claim to _only those groups which are applicable to OpenShift_.

[IMAGE]

## 3. Configure the OpenShift cluster to use Azure AD as the identity provider

Finally, we need to configure OpenShift to use Azure AD as its identity provider. 

To do so, ensure you are logged in to the OpenShift command line interface (`oc`) by running the following command, making sure to replace the variables specified:

```bash
RESOURCE_GROUPO=example-rg # Replace this with the name of your ARO cluster's resource group
CLUSTER_NAME=example-cluster # Replace this with the name of your ARO cluster
oc login \
    $(az aro show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query apiserverProfile.url -o tsv) \
    -u $(az aro list-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME --query kubeadminUsername -o tsv) \
    -p $(az aro list-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME --query kubeadminPassword -o tsv)
```

Next, create a secret that contains the client secret that you captured in step 2 above. To do so, run the following command, making sure to replace the variable specified:

```bash
CLIENT_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx # Replace this with the Client Secret
oc create secret generic openid-client-secret --from-literal=clientSecret=${CLIENT_SECRET} -n openshift-config
```

Next, generate the necessary YAML for the cluster's OAuth provider to use Azure AD as its identity provider. To do so, run the following command, making sure to replace the variables specified:

```bash
IDP_NAME=AAD # Replace this with the name you used in the OAuth callback URL
APP_ID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy # Replace this with the Application (client) ID
TENANT_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz # Replace this with the Directory (tenant) ID
cat << EOF > cluster-oauth-config.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - mappingMethod: claim
    name: ${IDP_NAME}
    openID:
      claims:
        email:
        - email
        groups:
        - groups
        name:
        - name
        preferredUsername:
        - upn
      clientID: ${APP_ID}
      clientSecret:
        name: openid-client-secret
      extraScopes: []
      issuer: https://login.microsoftonline.com/${TENANT_ID}/v2.0
    type: OpenID
EOF
```

Feel free to further modify this output (which is saved in your current directory as `cluster-oauth-config.yaml`).

Finally, apply the new configuration to the cluster's OAuth provider by running the following command:

```bash
oc apply -f ./cluster-oauth-config.yaml
```

> **Note:** It is normal to receive an error that says an annotation is missing when you run `oc apply` for the first time. This can be safely ignored.

Once the cluster authentication operator reconciles your changes (generally within a few minutes), you will be able to login to the cluster using Azure AD. In addition, the cluster OAuth provider will automatically create or update the membership of groups the user is a member of (using the group ID). The provider **does not** automatically create RoleBindings and ClusterRoleBindings for the groups that are created, you are responsible for creating those via your own processes. 