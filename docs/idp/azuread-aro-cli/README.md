# Configure Azure AD as an OIDC identity provider in ARO #

*30 June 2022*

## Prerequisites

* [az cli](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
* [oc cli](https://docs.openshift.com/container-platform/4.10/cli_reference/openshift_cli/getting-started-cli.html)
* [jq](https://stedolan.github.io/jq/download/)
* [An Azure Red Hat OpenShift (ARO) cluster](https://mobb.ninja/docs/quickstart-aro.html)

### Variables


Set the following environment variables
 > Replace the values to suit your environment, particulary the cluster name & resource group.

    ```bash
    AZ_ARO_CLUSTER=aro-cluster-name
    AZ_ARO_RESOURCE_GROUP=aro-resource-group
    AZ_AD_APP_DISPLAY_NAME=aar-adapp
    ```

### Configure Azure Active Directory Application

Log into the Azure CLI by running the following and then authorizing through your Web Browser. Skip this step if you're already logged in.

    ```bash
    az login
    ```

Fetch the ARO API URL

    ```bash
    AZ_ARO_API_URL=$(az aro show \
        --name $AZ_ARO_CLUSTER \
        --resource-group $AZ_ARO_RESOURCE_GROUP \
        --query apiserverProfile.url -o tsv)
    ```

Get the cluster’s kubeadmin password 

    ```bash
    AZ_ARO_KUBE_PWD=$(az aro list-credentials \
        --name $AZ_ARO_CLUSTER \
        --resource-group $AZ_ARO_RESOURCE_GROUP \
        --query kubeadminPassword -o tsv)
    ```

Login to OpenShift API server using the above retrieved API URL and kubeadmin password

    ```bash
    oc login $AZ_ARO_API_URL \
        --username kubeadmin \
        --password $AZ_ARO_KUBE_PWD
    ```

Now that we’ve logged in to the cluster, let’s grab the oAuth route and construct the oAuth Call Back URL for the Azure AD Web App that we’ll create shortly.

    ```bash
    AZ_AD_CALLBACK_URL=https://`{oc get route oauth-openshift \
         -n openshift-authentication -o json \
         | jq -r .spec.host}`/oauth2callback/AAD
    ```

Azure AD app registration

    ```bash
    AZ_AD_APP_ID=$(az ad app create \
        --display-name $AZ_AD_APP_DISPLAY_NAME \
        --web-redirect-uris $AZ_AD_CALLBACK_URL \
        --query appId -o tsv)
    ```

Azure AD app may be configured to send optional claims to the client application in the oauth token. In the example here let's configure upn & email as additional optional claims. Later, while configuring OpnShift’s oAuth, we’ll use email as the preferred user name and if empty, then to use upn.

    ```bash
    cat > manifest.json << EOF
    {
        "idToken": [
            {
                "name": "upn",
                "essential": false
            },
            {
                "name": "email",
                "essential": false
            }
        ]
    }
    EOF
    ```

Update the Azure AD app to apply the manifest.json

    ```bash
    az ad app update \
        --id $AZ_AD_APP_ID \
        --optional-claims @manifest.json
    ```

Get the Azure AD Microsoft Graph App ID, which can then be used to assign the required oAuth API permissions to the Azure AD App.

    ```bash
    AZ_AD_MICROSOFT_GRAPH_APP_ID=$(az ad sp list \
        --filter "displayName eq 'Microsoft Graph'" \
        --query '[].appId' -o tsv)
    ```

Get the API ID for User.Read Permission

    ```bash
    AZ_AD_API_PERMISSION_USER_READ=$(az ad sp show \
        --id $AZ_AD_MICROSOFT_GRAPH_APP_ID \
        --query "oauth2PermissionScopes[?value=='User.Read'].id" -o tsv)
    ```

Get the API ID for email Permission

    ```bash
    AZ_AD_API_PERMISSION_EMAIL=$(az ad sp show \
	    --id $AZ_AD_MICROSOFT_GRAPH_APP_ID \
	    --query "oauth2PermissionScopes[?value=='email'].id" -o tsv)
    ```

Assign the User.Read & email scoped permissions to the App, to be able to read the user profiles.
> _Note : The "User.Read" profile & email scopes do not require consent grant by default, so the message to grant consent may be ignored. However it'd be good to check with the Azure AD administrator about any requirement to explicitly grant these scopes to the app. AD domain users will be prompted for consent when they first login to the cluster._

    ```bash
    az ad app permission add \
        --api $AZ_AD_MICROSOFT_GRAPH_APP_ID \
        --api-permissions $AZ_AD_API_PERMISSION_USER_READ=Scope \
        --id $AZ_AD_APP_ID
    ```

    ```bash
    az ad app permission add \
        --api $AZ_AD_MICROSOFT_GRAPH_APP_ID \
        --api-permissions $AZ_AD_API_PERMISSION_EMAIL=Scope \
        --id $AZ_AD_APP_ID
    ```

Get the tenant id of the Azure AD App which will be used shortly while configuring OpenShfit oAuth.

    ```bash
    AZ_AD_APP_TENANT_ID=$(az account show \
        --query tenantId -o tsv)
    ```

Create a password credential for the created Azure AD App, which will be used in the next step to create an OpenShift secret.

    ```bash
    AZ_AD_APP_CLIENT_SECRET=$(az ad app credential reset \
        --id $AZ_AD_APP_ID \
        --append --years 1 \
        --display-name $AZ_AD_APP_DISPLAY_NAME \
        | jq -r '.password')
    ```

### Configure OpenShift OAuth 

Create an OpenShift secret for authenticating against Azure AD.

    ```bash
    oc create secret generic azuread-client-secret \
        --namespace openshift-config \
        --from-literal=clientSecret=$AZ_AD_APP_CLIENT_SECRET
    ```

Create an azureADOAuth.yaml file, for oAuth cluster config of type OpenID (OIDC) in OpenShift, to specify the Azure AD details.
 > _Here we use the tenantID (AZ_AD_APP_TENANT_ID), appID (AZ_AD_APP_ID) and the OpenShift secret (azuread-client-secret) that were created earlier._

    ```bash
    cat > azureADOAuth.yaml<< EOF
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
          clientID: $AZ_AD_APP_ID
          clientSecret:
            name: azuread-client-secret
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
          issuer: https://login.microsoftonline.com/$AZ_AD_APP_TENANT_ID
    EOF
    ```

Apply the yaml file to the cluster.

    ```bash
    oc apply -f azureADOAuth.yaml
    ```


You may wait a few minutes, log-out and re-log in to the cluster’s web-cosole, to find the Azure Active Directory login option. 

To authorize users to access ARO cluster resources, [RBAC permissions](https://docs.openshift.com/container-platform/4.10/authentication/using-rbac.html) should be configured.