---
date: '2026-04-15'
title: 'AWS Cognito and IAM Identity Center for ROSA Cluster Access'
tags: ["ROSA", "IDP"]
authors:
  - cwooley-rh
---

EKS allows humans to assume IAM roles and pass those credentials directly to `kubectl` via the AWS IAM Authenticator. ROSA does not have that path natively — it uses OpenShift OAuth, which requires an OIDC identity provider as the bridge.

This guide demonstrates the AWS-native pattern for ROSA human identity using IAM Identity Center and Cognito as an OIDC bridge to ROSA OAuth. The end result provides the same outcome as EKS IAM assumed roles: users are managed in AWS identity tooling, cluster access maps to OpenShift RBAC, and no separate user directory is required outside of AWS.

**Two approaches are provided:**

| Approach | Use Case |
|----------|----------|
| **Cognito Only** | Teams not yet using Identity Center, or quick proof of concept |
| **Identity Center + Cognito** | Closest equivalent to EKS IAM assumed roles; full AWS SSO |

## Prerequisites

* ROSA cluster (4.14+)
    - [ROSA HCP via Terraform](/experts/rosa/terraform/hcp/) (recommended)
    - [ROSA Classic via CLI](/experts/rosa/sts/)
    - Logged in with cluster-admin access
* `rosa` CLI
* `aws` CLI ([installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
* `oc` CLI
* Existing cluster admin access (HTPasswd or other IdP) for initial configuration

## Environment Variables

Set the following variables for use throughout this guide. Customize the values to match your environment.

```bash
export CLUSTER_NAME="<your-cluster-name>"
export AWS_REGION="<your-aws-region>"  # e.g., us-east-1
export USER_POOL_NAME="rosa-cluster-users"
export COGNITO_DOMAIN="rosa-$(echo $RANDOM | md5sum | head -c 8)"  # Must be globally unique
```

Get your cluster domain for the callback URL:

```bash
export CLUSTER_DOMAIN=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.dns.base_domain')
export CALLBACK_URL="https://oauth-openshift.apps.${CLUSTER_NAME}.${CLUSTER_DOMAIN}/oauth2callback/cognito"
```

## Approach 1: Cognito as Standalone OIDC IdP for ROSA

Use this approach if you want AWS-managed users without Identity Center, or as a stepping stone before wiring in Identity Center.

### 1. Create a Cognito User Pool

```bash
aws cognito-idp create-user-pool \
  --pool-name $USER_POOL_NAME \
  --auto-verified-attributes email \
  --username-attributes email \
  --region $AWS_REGION
```

Capture the User Pool ID from the output:

```bash
export USER_POOL_ID=$(aws cognito-idp list-user-pools \
  --max-results 10 \
  --region $AWS_REGION \
  --query "UserPools[?Name=='${USER_POOL_NAME}'].Id" \
  --output text)

echo "User Pool ID: $USER_POOL_ID"
```

### 2. Configure a Cognito App Client

```bash
aws cognito-idp create-user-pool-client \
  --user-pool-id $USER_POOL_ID \
  --client-name rosa-oidc-client \
  --generate-secret \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --callback-urls "$CALLBACK_URL" \
  --supported-identity-providers COGNITO \
  --region $AWS_REGION
```

Capture the client credentials:

```bash
export COGNITO_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
  --user-pool-id $USER_POOL_ID \
  --region $AWS_REGION \
  --query "UserPoolClients[?ClientName=='rosa-oidc-client'].ClientId" \
  --output text)

export COGNITO_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id $USER_POOL_ID \
  --client-id $COGNITO_CLIENT_ID \
  --region $AWS_REGION \
  --query "UserPoolClient.ClientSecret" \
  --output text)

echo "Client ID: $COGNITO_CLIENT_ID"
echo "Client Secret: $COGNITO_CLIENT_SECRET"
```

{{< alert state="info" >}}
The callback URL format is `https://oauth-openshift.apps.<cluster-domain>/oauth2callback/<idp-name>` where `<idp-name>` matches the `--name` used when creating the IdP in step 4.
{{< /alert >}}

### 3. Set a Cognito Domain

Cognito requires a domain to serve the OIDC endpoints and hosted login UI:

```bash
aws cognito-idp create-user-pool-domain \
  --domain $COGNITO_DOMAIN \
  --user-pool-id $USER_POOL_ID \
  --region $AWS_REGION
```

Set the OIDC issuer URL:

```bash
export COGNITO_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}"
```

Verify the OIDC discovery endpoint is reachable:

```bash
curl -s $COGNITO_ISSUER/.well-known/openid-configuration | jq .
```

### 4. Configure the OpenID IdP in ROSA

```bash
rosa create idp \
  --cluster $CLUSTER_NAME \
  --type openid \
  --name cognito \
  --client-id $COGNITO_CLIENT_ID \
  --client-secret $COGNITO_CLIENT_SECRET \
  --issuer-url $COGNITO_ISSUER \
  --email-claims email \
  --name-claims name \
  --username-claims email
```

Verify the IdP was registered:

```bash
rosa list idps --cluster $CLUSTER_NAME
```

{{< alert state="warning" >}}
The `--name` value (`cognito` here) must match the `<idp-name>` in the callback URL registered in step 2. If you used a different name, update the callback URL in the Cognito App Client to match.
{{< /alert >}}

### 5. Create Cognito Users

```bash
export ADMIN_EMAIL="admin@yourcompany.com"
export TEMP_PASSWORD="TempPass123!"

aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username $ADMIN_EMAIL \
  --user-attributes Name=email,Value=$ADMIN_EMAIL \
                    Name=email_verified,Value=true \
  --temporary-password "$TEMP_PASSWORD" \
  --region $AWS_REGION
```

The user will be prompted to change their password on first login.

### 6. Grant cluster-admin in OpenShift

First, get the current cluster admin credentials (if using HTPasswd):

```bash
oc login $(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.api.url') \
  --username <htpasswd-admin> \
  --password '<password>'
```

Grant `cluster-admin` to the Cognito user:

```bash
oc adm policy add-cluster-role-to-user cluster-admin $ADMIN_EMAIL
```

### 7. Test Login via oc and Console

Get the console URL:

```bash
rosa describe cluster -c $CLUSTER_NAME | grep Console
```

**Browser login:**
1. Open the OpenShift Console URL
2. Select **"Log in with cognito"**
3. Sign in with Cognito user credentials (you will be prompted to change the temporary password)
4. Use **"Copy login command"** for the `oc` token

**oc login:**
```bash
oc login https://api.${CLUSTER_NAME}.${CLUSTER_DOMAIN}:6443 --token=<token-from-console>
oc whoami
oc get nodes
```

### 8. Remove HTPasswd IdP (Optional)

Once Cognito login is confirmed working, you can remove the HTPasswd IdP:

```bash
rosa list idps --cluster $CLUSTER_NAME
rosa delete idp --cluster $CLUSTER_NAME --name htpasswd
```

{{< alert state="danger" >}}
Ensure you have verified Cognito login and have granted cluster-admin to at least one Cognito user before removing the HTPasswd IdP.
{{< /alert >}}

---

## Approach 2: IAM Identity Center + Cognito for ROSA

Use this approach if your organization already uses IAM Identity Center for AWS access and you want the same identity system to control ROSA cluster access.

**Architecture:**
```
Corporate users in IAM Identity Center
  → SAML 2.0 assertion → Cognito User Pool
    → OIDC token → ROSA OpenID IdP
      → OpenShift RBAC → oc / Console access
```

### 1. Create Cognito User Pool, App Client, and Domain

Follow **Approach 1, Steps 1-3** to create the User Pool, App Client, and domain. Ensure you have these values ready:

```bash
echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $COGNITO_CLIENT_ID"
echo "Client Secret: $COGNITO_CLIENT_SECRET"
echo "Issuer: $COGNITO_ISSUER"
echo "Cognito Domain: $COGNITO_DOMAIN"
```

### 2. Create a SAML Application in IAM Identity Center

IAM Identity Center speaks SAML to Cognito (not OIDC directly). Cognito then exposes OIDC to ROSA.

**Option A: Using AWS CLI (creates application, console required for SAML config)**

```bash
export IDC_INSTANCE_ARN=$(aws sso-admin list-instances --region $AWS_REGION \
  --query "Instances[0].InstanceArn" --output text)

aws sso-admin create-application \
  --application-provider-arn "arn:aws:sso::aws:applicationProvider/custom" \
  --instance-arn "$IDC_INSTANCE_ARN" \
  --name "rosa-cognito" \
  --status ENABLED \
  --region $AWS_REGION
```

Capture the Application ARN from the output:

```bash
export APPLICATION_ARN="<ApplicationArn from output>"
```

**Option B: Using AWS Console (recommended for full SAML configuration)**

In the **IAM Identity Center console:**

1. Go to **Applications** → **Add application** → **Add custom SAML 2.0 application**
2. Set Application name: `rosa-cognito`
3. Click **Next**
4. Under **Application properties**:
   - Application start URL: (leave empty)
   - Relay state: (leave empty)
5. Under **Application metadata**:
   - **If you choose to manually type your metadata values:**
     - Application ACS URL: `https://<cognito-domain>.auth.<region>.amazoncognito.com/saml2/idpresponse`
       - Use your actual values: `https://${COGNITO_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com/saml2/idpresponse`
     - Application SAML audience: `urn:amazon:cognito:sp:<USER_POOL_ID>`
       - Use your actual value: `urn:amazon:cognito:sp:${USER_POOL_ID}`
6. Under **Attribute mappings**, add:
   - Subject: `${user:email}` with format `emailAddress`
   - Additional attribute: `email` → `${user:email}` with format `basic`
7. Click **Submit**
8. On the application details page, go to the **Actions** menu → **Edit attribute mappings**
9. Verify the email attribute mapping uses the claim name: `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress`

**Get the SAML Metadata URL:**

After creating the application, you need the IAM Identity Center SAML metadata URL:

1. In the application details page, scroll to **IAM Identity Center metadata**
2. Copy the **IAM Identity Center SAML metadata file URL**
3. Save this URL for Step 3

{{< alert state="info" >}}
The SAML metadata URL will be in the format: `https://portal.sso.<region>.amazonaws.com/saml/metadata/<application-id>`
{{< /alert >}}

Export the metadata URL:

```bash
export IDC_SAML_METADATA_URL="<metadata-url-from-console>"
```

### 3. Configure Identity Center as SAML IdP in Cognito

Replace `<IAM-Identity-Center-SAML-metadata-URL>` with the metadata URL from the previous step:

```bash
export IDC_SAML_METADATA_URL="<IAM-Identity-Center-SAML-metadata-URL>"

aws cognito-idp create-identity-provider \
  --user-pool-id $USER_POOL_ID \
  --provider-name IdentityCenter \
  --provider-type SAML \
  --provider-details MetadataURL=$IDC_SAML_METADATA_URL \
  --attribute-mapping email=http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress \
  --region $AWS_REGION
```

{{< alert state="info" >}}
The attribute mapping connects the SAML claim from IAM Identity Center to the Cognito email attribute. Adjust the claim name if your Identity Center uses a different attribute for email.
{{< /alert >}}

### 4. Update the Cognito App Client to Allow Identity Center Login

```bash
aws cognito-idp update-user-pool-client \
  --user-pool-id $USER_POOL_ID \
  --client-id $COGNITO_CLIENT_ID \
  --supported-identity-providers COGNITO IdentityCenter \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --callback-urls "$CALLBACK_URL" \
  --region $AWS_REGION
```

### 5. Assign Users/Groups in IAM Identity Center

In the **IAM Identity Center console:**

1. Go to **Applications** → **rosa-cognito**
2. Under **Assigned users and groups**, assign the users or groups who should have ROSA cluster access
3. Users can now federate through Identity Center → Cognito → ROSA

{{< alert state="info" >}}
This is the closest analog to EKS: you manage cluster access by assigning users to the application in Identity Center, the same place you manage their AWS account access.
{{< /alert >}}

### 6. Configure the OpenID IdP in ROSA

```bash
rosa create idp \
  --cluster $CLUSTER_NAME \
  --type openid \
  --name cognito \
  --client-id $COGNITO_CLIENT_ID \
  --client-secret $COGNITO_CLIENT_SECRET \
  --issuer-url $COGNITO_ISSUER \
  --email-claims email \
  --name-claims name \
  --username-claims email
```

### 7. Grant cluster-admin to Identity Center Users

```bash
# Log in with existing HTPasswd admin
oc login $(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.api.url') \
  --username <htpasswd-admin> \
  --password '<password>'

# Grant cluster-admin by email (as it flows through Identity Center → Cognito → OIDC)
export IDC_USER_EMAIL="user@yourcompany.com"
oc adm policy add-cluster-role-to-user cluster-admin $IDC_USER_EMAIL
```

For group-based access (if Cognito passes group claims):

```bash
export GROUP_NAME="<your-group-name>"
oc adm policy add-cluster-role-to-group cluster-admin $GROUP_NAME
```

### 8. Test Login

1. Open the OpenShift Console URL
2. Select **"Log in with cognito"**
3. You will see both a Cognito native login AND an **"IdentityCenter"** option
4. Select **IdentityCenter**, which redirects to IAM Identity Center SSO
5. Sign in with corporate credentials
6. On success, you are redirected back to OpenShift as your Identity Center user
7. Use **"Copy login command"** for the `oc` token

```bash
oc login https://api.${CLUSTER_NAME}.${CLUSTER_DOMAIN}:6443 --token=<token>
oc whoami
oc get nodes
```

### 9. Remove HTPasswd (Optional)

Once Identity Center login is confirmed working:

```bash
rosa list idps --cluster $CLUSTER_NAME
rosa delete idp --cluster $CLUSTER_NAME --name htpasswd
```

{{< alert state="danger" >}}
Ensure you have verified Identity Center login and have granted cluster-admin to at least one Identity Center user before removing the HTPasswd IdP.
{{< /alert >}}

---

## EKS vs ROSA Identity Flow Comparison

| Step | EKS (IAM Assumed Roles) | ROSA (Cognito + Identity Center) |
|------|-------------------------|----------------------------------|
| Identity source | IAM roles / Identity Center | IAM Identity Center |
| Auth mechanism | AWS IAM Authenticator | OpenID Connect (Cognito) |
| CLI credential | `aws eks get-token` | `oc login --token` (from console) |
| User management | IAM / Identity Center | Identity Center → Cognito (federated) |
| Access control | `aws-auth` ConfigMap / Access Entries | OpenShift RBAC (`ClusterRoleBinding`) |
| AWS-native? | Yes, natively | Yes, via Cognito OIDC bridge |
| Extra hop vs EKS? | No | Yes (Cognito as bridge) |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Login redirect fails | Verify callback URL in Cognito App Client matches `--name` in `rosa create idp` |
| "Invalid client" error | Confirm `CLIENT_ID` and `CLIENT_SECRET` match the Cognito App Client exactly |
| User authenticated but no access | Confirm `oc adm policy add-cluster-role-to-user` was run with the correct email |
| Identity Center users not seeing SAML login option | Confirm user/group is assigned to the `rosa-cognito` app in Identity Center |
| SAML attribute mapping wrong | Check claim name in Approach 2, Step 3 matches what Identity Center sends in SAML assertion |
| OIDC discovery endpoint 404 | Confirm Cognito domain was created and `USER_POOL_ID` is correct |

---

## Cleanup

Remove all resources created by this guide in reverse order:

```bash
# Remove OpenShift RBAC bindings
# Find the binding name first
oc get clusterrolebinding -o json | jq -r '.items[] | select(.subjects[]?.name == "'"$ADMIN_EMAIL"'") | .metadata.name'

# Delete the binding (replace with actual binding name from above)
oc delete clusterrolebinding <binding-name>

# Remove the OpenID IdP from ROSA
rosa delete idp cognito --cluster $CLUSTER_NAME --yes

# If using Approach 2, delete the SAML IdP from Cognito first
aws cognito-idp delete-identity-provider \
  --user-pool-id $USER_POOL_ID \
  --provider-name IdentityCenter \
  --region $AWS_REGION

# Delete the Cognito domain (must be deleted before User Pool)
aws cognito-idp delete-user-pool-domain \
  --domain $COGNITO_DOMAIN \
  --user-pool-id $USER_POOL_ID \
  --region $AWS_REGION

# Delete the Cognito User Pool (this also deletes the app client and users)
aws cognito-idp delete-user-pool \
  --user-pool-id $USER_POOL_ID \
  --region $AWS_REGION
```

For **Approach 2**, also remove the SAML application from IAM Identity Center:

**Using AWS CLI:**
```bash
aws sso-admin delete-application \
  --application-arn $APPLICATION_ARN \
  --region $AWS_REGION
```

**Or using AWS Console:**
1. Go to **IAM Identity Center** → **Applications**
2. Select **rosa-cognito**
3. Delete the application
