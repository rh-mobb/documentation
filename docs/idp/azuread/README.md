# Configure Azure AD ad OIDC identity provider #

The steps to add Azure AD as an identity provider for managed OpenShift are:

1. Determine the OAuth callback URL
1. A new App registration on Azure AD
1. Creation of a client secret
1. The Token configuration 
1. Configuration of the OAuth identity provider in OCM

## Determine the OAuth callback URL ##
To determine the OAuth callback URL there are different ways. 

The callback URL has the following format:
```
https://oauth-openshift.apps.<cluster_name>.<cluster_domain>/oauth2callback/<idp_provider_name>
```
You can determine it for your cluster by changing the <cluster_name> and the <cluster_domain> with the name of your cluster and its domain.
The <idp_provider_name> is the name that you give to the identity provider.

It is possible to find quickly the callback URL in the OCM:
1. Select your cluster in OCM and then go to the **'Access control'** tab. 
![ocm select access control tab](../images/ocm_access_control.png)
1. Then select OpenID as identity provider from the identity providers list.  
![ocm select OpenID as indenity provider](../images/ocm_identity_providers_list.png)
1. Give a name to the indenity provider that we are adding to the OCP cluster
![ocm set a name to the OpenID indenity provider](../images/ocm_indentity_providers_callback_url.png)
1. Keep the OAuth callback URL to use later.

## A new App registrations on Azure AD ##
Access your Azure account and select the Azure Active Directory service and execute the following steps:

1. From the main menu add a new Webapp  
![azuread create a new webapp](../images/azuread_add_webapp.png)
1. For the new webapp select a name and the supported account type
1. In the redirect URI add the callback URL saved in the previous section and press the button 'Register'  
![azuread add the callback URI](../images/azuread_configure_webapp.png)  
 Once the Webapp is created the following field must be saved to be used in the OCM OAuth configuration:
    - Application (client) ID
    - Directory (tenant) ID   

    ![azuread display the Webapp info registration](../images/azuread_webapp_info.png) 

## Creation of a client secret ##
1. Create a new Secret for the Webapp  
![azuread create a new Webapp secret](../images/azuread_new_client_secret.png)   
Once the secret is created the SecretID has to be saved to be used later in the OCM OAuth configuration 
![azuread secret id](../images/azuread_secret_id.png)

## The Token configuration  ##
1. Create a new token configuration  
![azuread create a new token configuration](../images/azuread_token_configuration.png)
1. Add the minimum claims that has to be in the token:
    - upn
    - email
       
   ![azuread add token claims](../images/azuread_add_token_claims.png)
1. Specify that the claim must be returned in the token.  
![azuread add token claim check](../images/azuread_add_token_claims_2.png)

## Configuration the OAuth identity provider in OCM ##
In the OCM fill all the fields with the values collected during the registration of the new Webapp in the Azure AD  
![ocm fill the oauth fields](../images/ocm_oauth_id_filled.png)
and click the 'Add' button. 
After a few minutes the Azure AD authentication methos will be available in the OpenShift console login screen  
![ocp login screen](../images/ocp_login.png)
