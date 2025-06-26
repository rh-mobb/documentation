---
date: '2025-06-26'
title: Deploy ROSA with Red Hat Advanced Cluster Management for Kubernetes 
tags: ["AWS", "ROSA"]
authors:
  - Kevin Collins
  - Michael McNeill
---

In the dynamic world of cloud-native development, efficiently managing Kubernetes clusters across diverse environments is paramount. This blog post dives into a powerful combination: deploying Red Hat OpenShift Service on AWS (ROSA) Hosted Control Planes (HCP) clusters, orchestrated and governed by Red Hat Advanced Cluster Management for Kubernetes (RHACM). This approach offers a compelling suite of benefits, including significant cost reductions by offloading control plane management to Red Hat, accelerated cluster provisioning times, and enhanced operational efficiency through a centralized management plane. By leveraging ROSA HCP with RHACM, organizations can achieve a more streamlined, secure, and scalable Kubernetes footprint on AWS, allowing teams to focus more on innovation and less on infrastructure overhead.

## Pre-requisites

1. You will need a a ROSA Cluster (see [Deploying ROSA HCP with Terraform](/experts/rosa/terraform/hcp/) if you need help creating one).

2. Log into the ROSA cluster

3. AWS CLI logged into

4. Terraform CLI

5. Git CLI

6. An OCM Service Account ClientID and Client Secret - if you don't have one, you can create a service account by visiting [here](https://console.redhat.com/iam/service-accounts)

6. Set environment variables

```bash
export ACM_CLUSTER_NAME=rosa-hcp-1
export NEW_ROSA_CLUSTER_NAME=new-hcp
export ROSA_VERSION=4.19
export ROSA_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer | sed 's/https:\/\///')
ROSA_API_SERVER=$(oc config view --minify -o jsonpath='{.clusters[*].cluster.server}')
export OCM_CLIENT_ID= # SERVICE ACCOUNT CLIENT ID
export OCM_CLIENT_SECRET= # SERVICE ACCOUNT CLIENT SECRET
```

## Install and Configure ACM

1. Deploy the Red Hat Advanced Cluster Management for Kubernetes Operator

    ```
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: open-cluster-management
    ---
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: open-cluster-management-operator-group
      namespace: open-cluster-management
    spec:
      targetNamespaces:
        - open-cluster-management
    ---
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: acm-operator-subscription
      namespace: open-cluster-management
    spec:
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      name: advanced-cluster-management
      channel: "release-2.13"
      installPlanApproval: Automatic
    EOF
    ```
2. Create a MultiClusterHub Instance

    ```
    cat << EOF | oc apply -f -
    apiVersion: operator.open-cluster-management.io/v1
    kind: MultiClusterHub
    metadata:
      name: multiclusterhub # You can customize the name
      namespace: open-cluster-management # Must match the namespace where the operator is installed
    spec: {}
    EOF
    ```    

    Before continuing, wait for the multicluster engine to complete

    ```bash
    oc wait --for=jsonpath='{.status.phase}'='Running' MultiClusterHub multiclusterhub -n open-cluster-management
    ```

3. Patch the multiclusterengine to support preview APIs

```bash
oc patch multiclusterengine multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"cluster-api-provider-aws-preview","enabled":true},{"name":"cluster-api-preview","enabled":true}]}}}'

oc patch multiclusterengine multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"cluster-api-preview","enabled":true}]}}}'
```

4. Annotate the multiclusterengine to respect IRSA credentails

```bash
oc annotate mce multiclusterengine installer.multicluster.openshift.io/pause=true
```

### Configure AWS Credentails

1. Create a trust policy

```bash
   cat <<EOF > ./trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:multicluster-engine:capa-controller-manager"
        }
      }
    }
  ]
}
EOF
```

2. Create a role with a trust policy for RHACM to use

```bash
CAPA_ROLE=$(aws iam create-role --role-name "capa-manager-role-${ACM_CLUSTER_NAME}" --assume-role-policy-document file://trust.json --description "AWS Role for CAPA to assume" --query "Role.Arn" --output text)
echo $CAPA_ROLE
```

### Configure RHACM to use AWS Roles

1. Annotate the multicluster-engine service account

```bash
oc annotate serviceaccount -n multicluster-engine capa-controller-manager eks.amazonaws.com/role-arn=${CAPA_ROLE}
```

2. Restart the CAPA Controller Manager Deployment

```bash
oc rollout restart deployment capa-controller-manager -n multicluster-engine
```

3. Deploy the AWSClusterControllerIdentity

    ```bash
    cat << EOF | oc apply -f -
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: AWSClusterControllerIdentity
    metadata:
      name: "default"
    spec:
      allowedNamespaces: {}  # matches all namespaces
    EOF
    ```

### Configure RHACM to auto-import ROSA Clusters

1. Enable the ClusterImporter feature gates on the ClusterManager

```bash
cat << EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: ClusterManager
metadata:
  name: cluster-manager
spec:
  registrationConfiguration:
    featureGates:
    - feature: ClusterImporter
      mode: Enable
    - feature: ManagedClusterAutoApproval
      mode: Enable
    autoApproveUsers:
    - system:serviceaccount:multicluster-engine:agent-registration-bootstrap
EOF
```

2. Bind the CAPI manager permission to the import controller

```bash
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-manager-registration-capi
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: capi-operator-manager-role
subjects:
- kind: ServiceAccount
  name: registration-controller-sa
  namespace: open-cluster-management-hub
EOF
```

3. Get the CA from the hub cluster

```bash
CA=$(oc get cm -n kube-public kube-root-ca.crt -o json | jq '.data."ca.crt"' | base64)
```

4. Apply a config map on the hub cluster

```bash
cat << EOF | oc apply -f -
apiVersion: v1
data:
  kubeconfig: |
    apiVersion: v1
    clusters:
    - cluster:
        server: ${ROSA_API_SERVER}
        certificate-authority-data: ${CA}
        name: ""
    contexts: null
    current-context: ""
    kind: Config
    preferences: {}
    users: null
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: kube-public
EOF
```

## Deploy a new ROSA HCP Cluster

1. Create a namespace for the new cluster and an OCM secret

```bash
    oc new-project ${NEW_ROSA_CLUSTER_NAME} &&
    
    oc create -n ${NEW_ROSA_CLUSTER_NAME} secret generic rosa-creds-secret \
      --from-literal=ocmClientID=${OCM_CLIENT_ID} \
  --from-literal=ocmClientSecret=${OCM_CLIENT_SECRET} \
  --from-literal=ocmApiUrl='https://api.openshift.com'
```

2. Create OIDC Config for new cluster

```bash
export OIDC_ID=$(rosa create oidc-config --mode=auto --yes --region ${ROSA_REGION} -o json | jq -r '.id')

rosa create oidc-provider --oidc-config-id ${OIDC_ID}
```

3. Create ROSA Operator Roles for new cluster

```bash
rosa create operator-roles --hosted-cp --prefix "${NEW_ROSA_CLUSTER_NAME}" --oidc-config-id "${OIDC_ID}"  --installer-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-HCP-ROSA-Installer-Role
```

4. Deploy AWS VPC and Subnets for the cluster

>Note: This example deploys ROSA to a single availablility zone but can be easily adopted for multi-zone configuration

For detailed examples please refer to the official [docs](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-sts-creating-a-cluster-quickly#rosa-hcp-prereqs)

```bash
git clone https://github.com/openshift-cs/terraform-vpc-example
cd terraform-vpc-example
terraform init
terraform plan -out rosa.tfplan -var region=${ROSA_REGION}
terraform apply rosa.tfplan
export SUBNET_IDS=$(terraform output -raw cluster-subnets-string)
PRIVATE_SUBNET=$(terraform output | grep -A 1 "cluster-private-subnets" | tail -n 1 | cut -d'"' -f2)
PUBLIC_SUBNET=$(terraform output | grep -A 1 "cluster-public-subnets" | tail -n 1 | cut -d'"' -f2)
```

5. Shorten Role names to meet AWS limit of 64 characters

```bash
export INGRESSARN="${NEW_ROSA_CLUSTER_NAME}-openshift-ingress-operator-cloud-credentials"
export INGRESSARN=arn:aws:iam::660250927410:role/${INGRESSARN:0:64}

export IMAGEREGISTRYARN="${NEW_ROSA_CLUSTER_NAME}-openshift-image-registry-installer-cloud-credentials"
export IMAGEREGISTRYARN=arn:aws:iam::660250927410:role/${IMAGEREGISTRYARN:0:64}

export STORAGEARN="${NEW_ROSA_CLUSTER_NAME}-openshift-cluster-csi-drivers-ebs-cloud-credentials"
export STORAGEARN=arn:aws:iam::660250927410:role/${STORAGEARN:0:64}

export NETWORKARN="${NEW_ROSA_CLUSTER_NAME}-openshift-cloud-network-config-controller-cloud-credentials"
export NETWORKARN=arn:aws:iam::660250927410:role/${NETWORKARN:0:64}

export KUBECLOUDCONTROLLERARN="${NEW_ROSA_CLUSTER_NAME}-kube-system-kube-controller-manager"
export KUBECLOUDCONTROLLERARN=arn:aws:iam::660250927410:role/${KUBECLOUDCONTROLLERARN:0:64}

export NODEPOOLMANAGEMENTARN="${NEW_ROSA_CLUSTER_NAME}-kube-system-capa-controller-manager"
export NODEPOOLMANAGEMENTARN=arn:aws:iam::660250927410:role/${NODEPOOLMANAGEMENTARN:0:64}

export CONTROLPLANEOPERATORARN="${NEW_ROSA_CLUSTER_NAME}-kube-system-control-plane-operator"
export CONTROLPLANEOPERATORARN=arn:aws:iam::660250927410:role/${CONTROLPLANEOPERATORARN:0:64}

export KMSPROVIDERARN="${NEW_ROSA_CLUSTER_NAME}-kube-system-kms-provider"
export KMSPROVIDERARN=arn:aws:iam::660250927410:role/${KMSPROVIDERARN:0:64}
```

6. Create a new cluster

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${NEW_ROSA_CLUSTER_NAME}
spec:
  hubAcceptsClient: true
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${NEW_ROSA_CLUSTER_NAME}
  namespace: ${NEW_ROSA_CLUSTER_NAME}
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: ROSACluster
    name: ${NEW_ROSA_CLUSTER_NAME}
    namespace: ${NEW_ROSA_CLUSTER_NAME}
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: ROSAControlPlane
    name: "rosa-cp-${NEW_ROSA_CLUSTER_NAME}"
    namespace: ${NEW_ROSA_CLUSTER_NAME}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSACluster
metadata:
  name: ${NEW_ROSA_CLUSTER_NAME}
  namespace: ${NEW_ROSA_CLUSTER_NAME}
spec: {}
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: ROSAControlPlane
metadata:
  name: "rosa-cp-${NEW_ROSA_CLUSTER_NAME}"
  namespace: ${NEW_ROSA_CLUSTER_NAME}
spec:
  credentialsSecretRef:
    name: rosa-creds-secret
  rosaClusterName: ${NEW_ROSA_CLUSTER_NAME}
  domainPrefix: ${NEW_ROSA_CLUSTER_NAME}
  version: "${ROSA_VERSION}"
  region: ${ROSA_REGION}
  installerRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-HCP-ROSA-Installer-Role"
  supportRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-HCP-ROSA-Support-Role"
  workerRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-HCP-ROSA-Worker-Role"
  oidcID: ${OIDC_ID}
  rolesRef:
    ingressARN: ${INGRESSARN}
    imageRegistryARN: ${IMAGEREGISTRYARN}
    storageARN: ${STORAGEARN}
    networkARN: ${NETWORKARN}
    kubeCloudControllerARN: ${KUBECLOUDCONTROLLERARN}
    nodePoolManagementARN: ${NODEPOOLMANAGEMENTARN}
    controlPlaneOperatorARN: ${CONTROLPLANEOPERATORARN}
    kmsProviderARN: ${KMSPROVIDERARN}
  subnets:
    - "${PRIVATE_SUBNET}"
    - "${PUBLIC_SUBNET}"
  availabilityZones:
    - ${AZ}
  network:
    machineCIDR: "10.0.0.0/16"
    podCIDR: "10.128.0.0/14"
    serviceCIDR: "172.30.0.0/16"
  defaultMachinePoolSpec:
    instanceType: "m5.xlarge"
    autoscaling:
      maxReplicas: 3
      minReplicas: 2
  additionalTags:
    env: "demo"
    profile: "hcp"
    app-code: "MOBB-001"
    cost-center: "468"
    service-phase: "lab"
EOF
```

