# Using AWS Secrets Manager CSI on Red Hat OpenShift on AWS with STS

Author **Paul Czarkowski**

*last modified 2021-08-17*

The AWS Secrets and Configuration Provider (ASCP) provides a way to expose AWS Secrets as Kubernetes storage volumes. With the ASCP, you can store and manage your secrets in Secrets Manager and then retrieve them through your workloads running on ROSA or OSD.

This is made even easier / more secure through the use of AWS STS and Kubernetes PodIdentity.

## Prerequisites

* [A ROSA cluster deployed with STS](/docs/rosa/sts/)
* Helm 3
* aws CLI
* jq

### Preparing Environment

1. Validate that your cluster has STS

    ```bash
    oc get authentication.config.openshift.io cluster -o json \
    | jq .spec.serviceAccountIssuer
    ```

    You should see something like the following, if not, you could try adding support yourself like [this](https://cloud.redhat.com/blog/fine-grained-iam-roles-for-openshift-applications), but YMMV.

    ```
    "https://rh-oidc.s3.us-east-1.amazonaws.com/xxxxxx"
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:kube-system:secrets-store-csi-driver
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:kube-system:csi-secrets-store-provider-aws
    ```

1. Create some environment variables to refer to later

    ```bash
    export ROSA_CLUSTER_NAME=my-cluster
    export ROSA_CLUSTER_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME --output json | jq -r .id)
    export REGION=us-east-2 \
    export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq .spec.serviceAccountIssuer)
    export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
    export AWS_PAGER=""
    ```

## Deploy the AWS Secrets and Configuration Provider

1. Use Helm to register the secrets store csi driver

    ```bash
    helm repo add secrets-store-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/master/charts
    ```

1. Update your Helm Repositories

    ```bash
    helm repo update
    ```

1. Install the secrets store csi driver

    ```bash
    helm install -n kube-system csi-secrets-store \
      secrets-store-csi-driver/secrets-store-csi-driver
    ```

1. Deploy the AWS provider

    ```bash
    kubectl -n kube-system apply -f \
      https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
    ```

1. Check that both Daemonsets are running

    ```bash
    kubectl -n kube-system get ds \
      csi-secrets-store-provider-aws \
      csi-secrets-store-secrets-store-csi-driver
    ```

## Creating a Secret and IAM Access Policies

1. Create a secret in Secrets Manager

    ```bash
    SECRET_ARN=$(aws --region "$REGION" secretsmanager  create-secret \
      --name MySecret --secret-string \
      '{"username":"shadowman", "password":"hunter2"}' \
      --query ARN --output text)

    echo $SECRET_ARN
    ```

1. Create IAM Access Policy document

    ```bash
    cat << EOF > policy.json
    {
      "Version": "2012-10-17",
      "Statement": [{
          "Effect": "Allow",
          "Action": [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret"
          ],
          "Resource": ["$SECRET_ARN"]
          }]
    }
    EOF
    ```

1. Create an IAM Access Policy

    ```bash
    POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn \
      --output text iam create-policy \
      --policy-name openshift-access-to-mysecret-policy \
      --policy-document file://policy.json)
    echo $POLICY_ARN
    ```

1. Create IAM Role trust policy document

    > Note you can use Conditions to lock down to a specific namespace or service account here. But for simplicity we're keeping it open.

    ```bash
    cat <<EOF > trust-policy.json
    {
    "Version": "2012-10-17",
    "Statement": [
      {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/$ROSA_CLUSTER_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity"
      }
    ]
    }
    EOF
    ```

1. Create IAM Role

    ```bash
    ROLE_ARN=$(aws iam create-role --role-name openshift-access-to-mysecret \
      --assume-role-policy-document file://trust-policy.json \
      --query Role.Arn --output text)
    echo $ROLE_ARN
    ```

1. Attach Role to the Policy

    ```bash
    aws iam attach-role-policy --role-name openshift-access-to-mysecret --policy-arn $POLICY_ARN
    ```

## Create an Application to use this secret

1. Create an OpenShift project

    ```bash
    oc new-project my-application
    ```

1. Annotate the default service account to use the STS Role

    ```bash
    oc annotate -n my-application serviceaccount default \
      eks.amazonaws.com/role-arn=$ROLE_ARN
    ```

1. Create a secret provider class to access our secret

    ```bash
    cat << EOF | kubectl apply -f -
    apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
    kind: SecretProviderClass
    metadata:
      name: my-application-aws-secrets
    spec:
      provider: aws
      parameters:
        objects: |
            - objectName: "MySecret"
              objectType: "secretsmanager"
    EOF
    ```

1. Create a Deployment using our secret

    ```bash
    cat << EOF | kubectl apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: my-application
      labels:
        app: my-application
    spec:
      volumes:
      - name: secrets-store-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "my-application-aws-secrets"
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

1. Verify the Pod has the secret mounted

    ```bash
    kubectl exec -it my-application -- cat /mnt/secrets-store/MySecret
    ```

## Cleanup

1. Delete application

    ```bash
    oc delete project my-application
    ```

1. Delete the secrets store csi driver

    ```bash
    helm delete -n kube-system csi-secrets-store
    ```

1. Delete the AWS provider

    ```bash
    kubectl -n kube-system delete -f \
      https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
    ```

1. Delete Security Context Constraints

    ```bash
    oc adm policy remove-scc-from-user privileged \
      system:serviceaccount:kube-system:secrets-store-csi-driver
    oc adm policy remove-scc-from-user privileged \
      system:serviceaccount:kube-system:csi-secrets-store-provider-aws
    ```

1. Delete AWS Roles and Policies

    ```bash
    aws iam detach-role-policy --role-name openshift-access-to-mysecret --policy-arn $POLICY_ARN
    aws iam delete-role --role-name openshift-access-to-mysecret
    aws iam delete-policy --policy-arn $POLICY_ARN
    ```