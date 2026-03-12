---
date: '2026-03-11'
title: Using AWS Secrets Manager with External Secrets Operator on ROSA HCP 
tags: ["AWS", "ROSA", "STS"]
authors:
  - Kumudu Herath
  - Kevin Collins
  - Diana Sari
---
{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}

# Bridging the Security Gap with External Secrets Operator
In the modern cloud-native landscape, managing sensitive credentials across distributed environments is a critical challenge for platform engineers. The External Secrets Operator (ESO) for Red Hat OpenShift provides a robust, cluster-wide service designed to bridge the gap between enterprise security standards and Kubernetes agility. By acting as a secure conduit, ESO automates the fetching, refreshing, and provisioning of secrets from external management systems directly into your OpenShift clusters, ensuring that your applications remain secure without manual overhead.

## The Security Limitations of Native Kubernetes Secrets

While Kubernetes provides a native Secret resource, relying on it alone presents significant security hurdles for production-grade environments:
* Encoding vs. Encryption: By default, native secrets are stored as Base64-encoded strings—an obfuscation method that offers no true cryptographic protection and is easily reversible.
* The "Admin-as-Superuser" Risk: Even when encryption-at-rest is enabled in etcd, cluster administrators often maintain inherent visibility into secret values, complicating compliance in multi-tenant environments.
* Rotation Inconsistency: Manual rotation processes are prone to human error, often leading to stale credentials or security gaps across global clusters.
* Access Control Fragility: A single misconfiguration in Role-Based Access Control (RBAC) can inadvertently expose sensitive data to unauthorized entities within a namespace.

## The Strategic Advantage of Externalized Secret Management
Moving sensitive data out of the cluster and into a dedicated management system shifts the security paradigm from reactive to proactive. By utilizing an external-first approach, organizations gain:
* Centralized Governance: A single source of truth for sensitive data that exists independently of the Kubernetes lifecycle.
* Enhanced Privilege Separation: By decoupling storage from the cluster, you can protect secrets from cluster admins and enforce strict "least-privilege" access.
* Automated Lifecycle Management: Fully automate the secret lifecycle—from creation and fine-grained access control to rotation and expiration—ensuring your security posture evolves in real-time.


Refer to [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift) for more details.

Refer to [Limitations of External Secrets Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift#external-secrets-operator-limitations_external-secrets-operator-install)

## Prerequisites

1. ROSA HCP Cluster access with cluster-admin privileges.
2. OpenShift CLI (oc)
3. Access AWS Secrets Manager and aws cli


## Create environment variables

1. Create environment variables :

```bash
export REGION=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.aws.region}")
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
-o jsonpath='{.spec.serviceAccountIssuer}' | sed  's|^https://||')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_PAGER=""
export CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.apiServerURL}" | awk -F '.' '{print $2}')
export Project_Name="my-application"

echo REGION:$REGION OIDC_ENDPOINT:$OIDC_ENDPOINT AWS_ACCOUNT_ID:$AWS_ACCOUNT_ID CLUSTER_NAME:$CLUSTER_NAME Project_Name:$Project_Name

```

## Install the ESO Operator

1. OpenShift project for ESO operator

```bash
oc new-project external-secrets-operator
```

2. Create an OperatorGroup

```bash
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-external-secrets-operator
  namespace: external-secrets-operator
spec:
  targetNamespaces: []
EOF
```

3. Create a Subscription for ESO Operator

```bash
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-external-secrets-operator
  namespace: external-secrets-operator
spec:
  channel: stable-v1
  name: openshift-external-secrets-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
  startingCSV: external-secrets-operator.v1.0.0
EOF
```

>Note: Make sure to validate the current stable channel version.

4. Verify Operator Installation
  Verify OLM subscription, Operator deployment and the status of the External Secrets Operator is Running

  ```bash
  oc get subscription -n external-secrets-operator
  oc get csv -n openshift-operators-redhat
  oc get pods -n external-secrets-operator
  ```

  >Note: This can take up to a minute - #TODO update output

  Example Output

  ```
  NAME                                  PACKAGE                               SOURCE             CHANNEL
  openshift-external-secrets-operator   openshift-external-secrets-operator   redhat-operators   stable-v1
  NAME                               DISPLAY                                           VERSION   REPLACES   PHASE
  external-secrets-operator.v1.0.0   External Secrets Operator for Red Hat OpenShift   1.0.0                Succeeded
  NAME                                                            READY   STATUS    RESTARTS   AGE
  external-secrets-operator-controller-manager-549d5bc5fd-kwtt7   1/1     Running   0          2m7s
  ```

>Note: Refer to [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift) and [external-secrets](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift) for advance configurations.

5. Create external secrets operand 
```bash
oc create -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  labels:
    app: external-secrets-operator
    app.kubernetes.io/name: cluster
  name: cluster
spec:
  controllerConfig:
    networkPolicies:
    - componentName: ExternalSecretsCoreController
      egress:
      - {}
      name: allow-external-secrets-egress
EOF
```
## Use external secret in ROSA HCP project

1. Create a secret in AWS Secrets Manager

```bash
SECRET_ARN=$(aws --region "$REGION" secretsmanager create-secret \
    --name MYDBCreds --secret-string \
    '{"username":"shadowman", "password":"hunter2"}' \
    --query ARN --output text); echo $SECRET_ARN
```


2. Create an IAM Access Policy for above secret

```bash
cat <<EOF > policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "${SECRET_ARN}"
    }
  ]
}
EOF

POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn \
--output text iam create-policy \
--policy-name "${CLUSTER_NAME}-eso-aws-sm-policy" \
--policy-document file://policy.json)
echo $POLICY_ARN
```

3. Create an IAM Role trust policy

```bash
cat <<EOF > trust-policy.json
{
   "Version": "2012-10-17",
   "Statement": [
   {
   "Effect": "Allow",
   "Condition": {
     "StringEquals" : {
       "${OIDC_ENDPOINT}:sub": ["system:serviceaccount:${Project_Name}:default"]
      }
    },
    "Principal": {
       "Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/${OIDC_ENDPOINT}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity"
    }
    ]
}
EOF
```

4. Create an IAM role and attach the IAM policy

```bash
ROLE_ARN=$(aws iam create-role --role-name "${CLUSTER_NAME}-eso-aws-sm-role" \
--assume-role-policy-document file://trust-policy.json \
--query Role.Arn --output text); echo $ROLE_ARN

aws iam attach-role-policy --role-name "${CLUSTER_NAME}-eso-aws-sm-role" \
    --policy-arn $POLICY_ARN

```

5. Create a Project to test access to AWS secret in ROSA HCP project

```bash
oc new-project $Project_Name
```

6. Annotate the default service account to use the STS Role
>Note: create separate service account if your appplication uses non defult service account

```bash
oc annotate -n $Project_Name serviceaccount default \
    eks.amazonaws.com/role-arn=$ROLE_ARN

```
7. Create the SecretStore for service account:

```bash
oc create -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secret-store
  namespace: ${Project_Name}
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: default
EOF
```

8. Create an ExternalSecret Resource


```bash
oc create -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: ${Project_Name}
spec:
  refreshInterval: 1h  # Set the refresh interval for secrets
  secretStoreRef:
    name: aws-secret-store
    kind: SecretStore  # Referencing the SecretStore created earlier
  target:
    name: my-app-secrets
    creationPolicy: Owner  # This ensures the Secret is owned by the ExternalSecret
  data:
  - secretKey: DB_CREDS # This is the key in the Kubernetes Secret
    remoteRef:
      key: ${SECRET_ARN} #Replace this with the ARN of your AWS Secret Manager
EOF
```
>Note: For more advanced examples refer [external-secrets](https://external-secrets.io/latest/guides/introduction/)

9. Validate access to external secret

```bash
oc describe SecretStore aws-secret-store
```

Example Output

  ```
Name:         aws-secret-store
Namespace:    my-application
Labels:       <none>
Annotations:  <none>
API Version:  external-secrets.io/v1
Kind:         SecretStore
Metadata:
  Creation Timestamp:  2026-03-12T01:12:24Z
  Generation:          1
  Resource Version:    188462
  UID:                 b24020fc-97d7-48bf-8497-d29c4a7d8aa1
Spec:
  Provider:
    Aws:
      Auth:
        Jwt:
          Service Account Ref:
            Name:  default
      Region:      us-west-2
      Service:     SecretsManager
Status:
  Capabilities:  ReadWrite
  Conditions:
    Last Transition Time:  2026-03-12T01:25:08Z
    Message:               store validated
    Reason:                Valid
    Status:                True
    Type:                  Ready
Events:
  Type    Reason  Age               From          Message
  ----    ------  ----              ----          -------
  Normal  Valid   60s (x3 over 6m)  secret-store  store validated
  ```

```bash
oc describe externalsecret my-app-secrets
```

Example Output

  ```
Name:         my-app-secrets
Namespace:    my-application
Labels:       <none>
Annotations:  <none>
API Version:  external-secrets.io/v1
Kind:         ExternalSecret
Metadata:
  Creation Timestamp:  2026-03-12T01:12:33Z
  Generation:          1
  Resource Version:    184258
  UID:                 89e247a4-5f59-46a3-b029-7f8bc6a4dda8
Spec:
  Data:
    Remote Ref:
      Conversion Strategy:  Default
      Decoding Strategy:    None
      Key:                  arn:aws:secretsmanager:us-west-2:660250927410:secret:MYDBCreds-YLiKvK
      Metadata Policy:      None
    Secret Key:             DB_CREDS
  Refresh Interval:         1h
  Secret Store Ref:
    Kind:  SecretStore
    Name:  aws-secret-store
  Target:
    Creation Policy:  Owner
    Deletion Policy:  Retain
    Name:             my-app-secrets
Events:               <none>
  ```

```bash
oc get secrets
```

Example Output

  ```
NAME                       TYPE                      DATA   AGE
builder-dockercfg-cn98z    kubernetes.io/dockercfg   1      13m
default-dockercfg-xfl49    kubernetes.io/dockercfg   1      13m
deployer-dockercfg-bs6s4   kubernetes.io/dockercfg   1      13m
my-app-secrets             Opaque                    1      13s
  ```

```bash
oc describe secret my-app-secrets
```
Example Output

  ```
Name:         my-app-secrets
Namespace:    my-application
Labels:       reconcile.external-secrets.io/created-by=dec10c241d4322e67df2f3a503fdb206d6b69c516cfe9a5b4a664c25
              reconcile.external-secrets.io/managed=true
Annotations:  reconcile.external-secrets.io/data-hash: c02cf5e2c8075fb8e9d99e6d2136762e753006c8a13ebc6c268025d6

Type:  Opaque

Data
====
DB_CREDS:  46 bytes
  ```

```bash
oc get secret my-app-secrets -n $Project_Name -o go-template --template='{{.data.DB_CREDS|base64decode}}'
```
Example Output

  ```
{"username":"shadowman", "password":"hunter2"}
  ```

10. Deploy a pod and validate 

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: my-application
  labels:
    app: my-application
spec:
  volumes:
  - name: secrets-store-inline
    secret:
      secretName: my-app-secrets
  containers:
  - name: my-application-deployment
    image: k8s.gcr.io/e2e-test-images/busybox:1.29
    command:
      - "/bin/sleep"
      - "10000"
    volumeMounts:
    - name: secrets-store-inline
      mountPath: "/mnt/secrets-store"
      readOnly: true
EOF
```

11. Verify the pod has the secret mounted 
```bash
oc exec -it my-application -- cat /mnt/secrets-store/DB_CREDS
```


## Cleanup

1. Delete test Project

```bash
oc delete project $Project_Name
```

2. Delete the custom resource definitions (CRDs) 

```bash
oc delete customresourcedefinitions.apiextensions.k8s.io -l external-secrets.io/component=controller
```

3. Delete the external-secrets-operator namespace 

```bash
oc delete project external-secrets-operator
```

4. Cleanup your AWS Policies and roles

```bash
aws iam detach-role-policy --role-name "${CLUSTER_NAME}-eso-aws-sm-role" --policy-arn ${POLICY_ARN}
aws iam delete-role --role-name "${CLUSTER_NAME}-eso-aws-sm-role"
aws iam delete-policy --policy-arn ${POLICY_ARN}
```
5. Delete the Secrets Manager secret

```bash
aws secretsmanager --region $REGION delete-secret --secret-id $SECRET_ARN
```