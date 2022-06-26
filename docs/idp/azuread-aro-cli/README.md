# Configure Azure AD as an OIDC identity provider for ARO with cli  #

**Daniel Moessner**

*26 June 2022*

The steps to add Azure AD as an identity provider for Azure Red Hat OpenShift (ARO) via cli are:

1. Define needed variables
1. Get oauthCallbackURL
1. Create `manifest.json` file 
1. Register/create app
1. Add Servive Principal for the new app 
1. Make Service Principal and Enterprise Application
1. Create the client secret
1. Update the Azure AD application scope permissions
1. Get Tenant ID
1. Login to OpenShift as kubeadmin 
1. Create an OpenShift secret 
1. Apply OpenShift OpenID authentication 
1. Wait for authentication operator to roll out
1. Verify login through Azure Active Directory

## Define needed variables ##
To simplly follow along, first define the following variables according to your set-up:

   ```
   RESOURCEGROUP=<your ARO cluster RG>
   CLUSTERNAME=<your ARO cluster NAME>
   ```

## Get oauthCallbackURL ##
To get the `oauthCallbackURL` for the Azure AD integration, run the following commands:
   ```
   domain=$(az aro show -g $RESOURCEGROUP -n $CLUSTERNAME --query clusterProfile.domain -o tsv)
   location=$(az aro show -g $RESOURCEGROUP -n $CLUSTERNAME --query location -o tsv)
   apiServer=$(az aro show -g $RESOURCEGROUP -n $CLUSTERNAME --query apiserverProfile.url -o tsv)
   webConsole=$(az aro show -g $RESOURCEGROUP -n $CLUSTERNAME --query consoleProfile.url -o tsv)

   oauthCallbackURL=https://oauth-openshift.apps.$domain/oauth2callback/AAD
   echo $oauthCallbackURL
   ```

  **NOTE:** `oauthCallbackURL`, in particular `AAD` can be changed but **must** match the name in the oauth providerwhen creating the OpenShift OpenID authentication   

## Create `manifest.json` file to configure the Azure Active Directory application ##
Configure OpenShift to use the `email` claim and fall back to `upn` to set the Preferred Username by adding the `upn` as part of the ID token returned by Azure Active Directory.

Create a `manifest.json` file to configure the Azure Active Directory application.

   ```
   cat << EOF > manifest.json
   {
    "idToken": [
      {
       "name": "upn",
       "source": null,
       "essential": false,
       "additionalProperties": []
      },
      {
       "name": "email",
       "source": null,
       "essential": false,
       "additionalProperties": []
      }
     ]
   }  
   EOF
   ```


## Register/create app ##
Create an Azure AD application and retrieve app id:

   ```
   DISPLAYNAME=<auth-dmoessne-aro01> # set you name accordingly 

   az ad app create \
   --display-name $DISPLAYNAME \
   --web-redirect-uris $oauthCallbackURL \
   --sign-in-audience AzureADMyOrg \
   --optional-claims @manifest.json
   ```

   ```
   app_id=$(az ad app list --display-name $DISPLAYNAME --query [].appId -o tsv)
   ```

## Add Servive Principal for the new app ##
Create Pervice Principal for the app created:

   ```
   az ad sp create --id $app_id
   ```

## Make Service Principal and Enterprise Application ##
We need this Service Principal to be an Enterprise Application to be able to add users and groups, so we add the needed tag

   ```
   az ad sp update --id $app_id --add tags WindowsAzureActiveDirectoryIntegratedApp
   ```
   > **NOTE** in case you get a trace back (az cli >= `2.37.0`) check out https://github.com/Azure/azure-cli/issues/23027

## Create the client secret ##
The password for the app created is retrieved by resetting the same:

   ```
   PASSWD=$(az ad app credential reset --id $app_id --query password -o tsv)
   ``` 

## Update the Azure AD application scope permissions ##
To be able to read the user information from Azure Active Directory, we need to add the following Azure Active Directory Graph permissions

Add permission for the Azure Active Directory as follows:

   * read email
   ```
   az ad app permission add \
   --api 00000003-0000-0000-c000-000000000000 \
   --api-permissions 64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope \
   --id $app_id
   ```

   * read profile
   ```
   az ad app permission add \
   --api 00000003-0000-0000-c000-000000000000 \
   --api-permissions 14dad69e-099b-42c9-810b-d002981feec1=Scope \
   --id $app_id
   ```

   * User.Read
   ```
   az ad app permission add \
   --api 00000003-0000-0000-c000-000000000000 \
   --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope \
   --id $app_id
   ```
   > **NOTE** If you see message to grant the consent unless you are authenticated as a Global Administrator for this Azure Active Directory. Standard domain users will be asked to grant consent when they first login to the cluster using their AAD credentials.

## Get Tenant ID ##
We do need the Tenant ID for setting up the Oauth provider later on:

   ```
   tenant_id=$(az account show --query tenantId -o tsv)
   ```
   > **NOTE** now we can switch over to our OpenShift installation and apply the needed configuraion:


## Login to OpenShift as kubeadmin ##
Fetch kubeadmin password and login to your cluster via `oc` cli (you can use any other cluster-admin user in case you have already created/added other oauth providers)

   ```
   kubeadmin_password=$(az aro list-credentials \
   --name $CLUSTERNAME \
   --resource-group $RESOURCEGROUP \
   --query kubeadminPassword --output tsv)

   oc login $apiServer -u kubeadmin -p $kubeadmin_password
   ``` 
## Create an OpenShift ##
Create an OpenShift secret to store the Azure Active Directory application secret from the application password we created/reset earlier:

   ```
   oc create secret generic openid-client-secret-azuread \
   -n openshift-config \
   --from-literal=clientSecret=$PASSWD
   ```


## Apply OpenShift OpenID authentication ##
As a last step we need to apply the OpenShift OpenID authentication for Azure Active Directory:

   ```
      cat << EOF | oc apply -f -
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
         clientID: $app_id
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
         issuer: https://login.microsoftonline.com/$tenant_id
   EOF
   ```

## Wait for authentication operator to roll out ##
Before we move over to the OpenShift login, let's wait for the new version of the authentication cluster operator to be rolled out


   ```
   watch -n 5 oc get co authentication
   ```

   > **Note:** it may take some time until the rollout starts 

## Verify login through Azure Active Directory ##
Now we can see the login to Azure AD is available

At first login you may have to agree 
