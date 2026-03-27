---
date: '2026-03-25'
title: Using OpenShift Lightspeed with AWS Bedrock on ROSA
tags: ["ROSA", "ROSA HCP", "Lightspeed"]
authors:
  - Kevin Collins
  - Kumudu Herath
---

{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}

OpenShift Lightspeed is an AI-powered assistant that helps developers and administrators interact with OpenShift using natural language. This guide walks you through integrating OpenShift Lightspeed with AWS Bedrock on Red Hat OpenShift Service on AWS (ROSA).

## Prerequisites

* ROSA Cluster (4.20+)
* AWS CLI configured with appropriate credentials
* `oc` CLI logged in as cluster-admin
* `rosa` CLI
* An AWS account with access to Amazon Bedrock
* Access to a supported foundation model in Bedrock (e.g., Claude, Llama, etc.)

## Architecture Overview

OpenShift Lightspeed uses Large Language Models (LLMs) to provide intelligent assistance. By integrating with AWS Bedrock, you can leverage AWS-managed foundation models while keeping your OpenShift environment secure and compliant.

The integration uses:
- **AWS Bedrock**: Provides the foundation models for AI inference
- **IRSA (IAM Roles for Service Accounts)**: Enables secure authentication from ROSA to AWS Bedrock
- **OpenShift Lightspeed Operator**: Manages the Lightspeed service on your cluster
- **Bedrock Proxy**: Translation layer that bridges Lightspeed with Bedrock (see below)

### Bedrock Proxy Component

The **bedrock-proxy** is a critical translation layer that enables OpenShift Lightspeed to communicate with AWS Bedrock. OpenShift Lightspeed is built to work with OpenAI-compatible APIs, but AWS Bedrock has its own unique API format. Rather than modifying Lightspeed itself, this lightweight proxy makes Bedrock "speak OpenAI" so they can communicate seamlessly.

**What the Bedrock Proxy Does:**

1. **API Translation**
   - Receives OpenAI format requests from Lightspeed (`/v1/chat/completions`)
   - Translates them to Bedrock format and calls the appropriate model

2. **Message Format Conversion**
   - Amazon Nova doesn't support `system` role messages
   - The proxy extracts system prompts and prepends them to the first user message
   - Ensures only `user` and `assistant` roles are sent to Bedrock

3. **Parameter Mapping**
   - Converts OpenAI's `max_tokens` → Bedrock's `max_new_tokens`
   - Transforms message structure from simple strings to Nova's `content: [{"text": "..."}]` format

4. **Streaming Support**
   - Converts Bedrock streaming responses to OpenAI-compatible Server-Sent Events (SSE)
   - Reformats Bedrock's `contentBlockDelta` events into OpenAI's `delta` format
   - Ensures Lightspeed receives responses in the expected streaming format

5. **Authentication**
   - Uses IRSA (IAM Roles for Service Accounts) for secure AWS authentication
   - The pod's service account token is projected and used to assume the AWS IAM role
   - No static credentials needed - all authentication is handled via the service account

6. **Multi-Model Support**
   - Handles both Claude and Amazon Nova models
   - Automatically detects model type and applies appropriate format conversion

## Enable Amazon Bedrock Access

1. Enable model access in Amazon Bedrock

    Navigate to the AWS Bedrock console and enable access to your desired foundation model. For this guide, we'll use Anthropic Claude.

    ```bash
    aws bedrock list-foundation-models --region us-east-1 \
      --query 'modelSummaries[?contains(modelId, `anthropic.claude`)].[modelId,modelName]' \
      --output table
    ```

1. Request model access if needed

    If you don't have access to the model, request it through the AWS Bedrock console:
    - Navigate to Amazon Bedrock → Model access
    - Click "Request model access"
    - Select the model(s) you want to use
    - Submit the request

## Configure IAM for Bedrock Access

1. Set environment variables

    ```bash
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export CLUSTER_NAME=<your-cluster-name>
    export AWS_REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
    export BEDROCK_MODEL_ID=anthropic.claude-3-5-sonnet-20250219-v2:0
    export OIDC_ENDPOINT=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .aws.sts.oidc_endpoint_url | sed 's|^https://||')
    export LIGHTSPEED_NAMESPACE=openshift-lightspeed
    export SERVICE_ACCOUNT_NAME=lightspeed-service-account
    ```

1. Create IAM policy for Bedrock access

    ```bash
    BEDROCK_POLICY=$(cat <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "BedrockInvokeModel",
          "Effect": "Allow",
          "Action": [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelWithResponseStream"
          ],
          "Resource": "*"
        }
      ]
    }
    EOF
    )
    ```

1. Create the IAM policy and capture the ARN

    ```bash
    POLICY_ARN=$(aws iam create-policy \
      --policy-name ${CLUSTER_NAME}-lightspeed-bedrock \
      --policy-document "$BEDROCK_POLICY" \
      --query Policy.Arn --output text)
    echo "Policy ARN: $POLICY_ARN"
    ```

1. Create IAM role with trust policy for IRSA

    ```bash
    TRUST_POLICY=$(cat <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "${OIDC_ENDPOINT}:sub": "system:serviceaccount:${LIGHTSPEED_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
            }
          }
        }
      ]
    }
    EOF
    )

    aws iam create-role \
      --role-name ${CLUSTER_NAME}-lightspeed-bedrock \
      --assume-role-policy-document "$TRUST_POLICY"

    aws iam attach-role-policy \
      --role-name ${CLUSTER_NAME}-lightspeed-bedrock \
      --policy-arn ${POLICY_ARN}
    ```

1. Get the role ARN for later use

    ```bash
    export ROLE_ARN=$(aws iam get-role \
      --role-name ${CLUSTER_NAME}-lightspeed-bedrock \
      --query Role.Arn --output text)
    echo $ROLE_ARN
    ```

## Install OpenShift Lightspeed

1. Create the namespace

    ```bash
    oc create namespace ${LIGHTSPEED_NAMESPACE}
    ```

1. Create the service account with the IAM role annotation

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: ${SERVICE_ACCOUNT_NAME}
      namespace: ${LIGHTSPEED_NAMESPACE}
      annotations:
        eks.amazonaws.com/role-arn: ${ROLE_ARN}
    EOF
    ```
1. Create the OperatorGroup

    The OperatorGroup tells the Operator Lifecycle Manager (OLM) which namespaces the operator should monitor.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: openshift-lightspeed-group
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      targetNamespaces:
      - ${LIGHTSPEED_NAMESPACE}
    EOF
    ```

1. Subscribe to the Operator

    The Subscription links the operator from the Red Hat catalog to your cluster.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: lightspeed-operator
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      channel: stable
      name: lightspeed-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      installPlanApproval: Automatic
    EOF
    ```

1. Wait for the operator to be installed

    ```bash
    sleep 30
    oc get csv -n ${LIGHTSPEED_NAMESPACE} | grep lightspeed
    ```

1. Deploy PostgreSQL for conversation cache

    {{% alert state="info" %}}OpenShift Lightspeed requires PostgreSQL for conversation caching.{{% /alert %}}

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: lightspeed-postgres-pvc
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 10Gi
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: lightspeed-postgres
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: lightspeed-postgres
      template:
        metadata:
          labels:
            app: lightspeed-postgres
        spec:
          containers:
          - name: postgresql
            image: registry.redhat.io/rhel9/postgresql-15:latest
            env:
            - name: POSTGRESQL_USER
              value: lightspeed
            - name: POSTGRESQL_PASSWORD
              value: lightspeed123
            - name: POSTGRESQL_DATABASE
              value: lightspeed
            ports:
            - containerPort: 5432
            volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/pgsql/data
          volumes:
          - name: postgres-data
            persistentVolumeClaim:
              claimName: lightspeed-postgres-pvc
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: lightspeed-postgres
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      selector:
        app: lightspeed-postgres
      ports:
      - port: 5432
        targetPort: 5432
    EOF
    ```

1. Create PostgreSQL password secret

    ```bash
    oc create secret generic postgres-password \
      -n ${LIGHTSPEED_NAMESPACE} \
      --from-literal=password=lightspeed123
    ```

1. Wait for PostgreSQL to be ready

    ```bash
    oc wait --for=condition=available deployment/lightspeed-postgres \
      -n ${LIGHTSPEED_NAMESPACE} \
      --timeout=300s
    ```

1. Build and deploy Bedrock OpenAI-compatible proxy

    {{% alert state="info" %}}Since OpenShift Lightspeed doesn't natively support Bedrock, we need to build a proxy that provides an OpenAI-compatible API.{{% /alert %}}

    Create a simple proxy application:

    ```bash
    mkdir -p ~/bedrock-proxy
    cd ~/bedrock-proxy

    cat > app.py <<'PYTHON_EOF'
    from flask import Flask, request, Response, stream_with_context
    import boto3
    import json
    import os
    import time

    app = Flask(__name__)
    bedrock = boto3.client('bedrock-runtime', region_name=os.environ.get('AWS_REGION', 'us-east-1'))

    @app.route('/v1/chat/completions', methods=['POST'])
    def chat_completions():
        data = request.json
        model = data.get('model', os.environ.get('BEDROCK_MODEL_ID'))
        messages = data.get('messages', [])
        stream = data.get('stream', False)

        prompt = "\n".join([f"{m['role']}: {m['content']}" for m in messages])
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": data.get('max_tokens', 4096),
            "messages": [{"role": "user", "content": prompt}]
        })

        if stream:
            # Streaming response
            def generate():
                response = bedrock.invoke_model_with_response_stream(
                    modelId=model,
                    body=body
                )

                request_id = response['ResponseMetadata']['RequestId']

                for event in response['body']:
                    chunk = json.loads(event['chunk']['bytes'].decode())

                    if chunk['type'] == 'content_block_delta':
                        # Send SSE chunk
                        sse_chunk = {
                            "id": f"chatcmpl-{request_id}",
                            "object": "chat.completion.chunk",
                            "created": int(time.time()),
                            "model": model,
                            "choices": [{
                                "index": 0,
                                "delta": {
                                    "content": chunk['delta']['text']
                                },
                                "finish_reason": None
                            }]
                        }
                        yield f"data: {json.dumps(sse_chunk)}\n\n"

                    elif chunk['type'] == 'message_stop':
                        # Send final chunk
                        final_chunk = {
                            "id": f"chatcmpl-{request_id}",
                            "object": "chat.completion.chunk",
                            "created": int(time.time()),
                            "model": model,
                            "choices": [{
                                "index": 0,
                                "delta": {},
                                "finish_reason": chunk.get('stop_reason', 'stop')
                            }]
                        }
                        yield f"data: {json.dumps(final_chunk)}\n\n"
                        yield "data: [DONE]\n\n"

            return Response(stream_with_context(generate()), mimetype='text/event-stream')

        else:
            # Non-streaming response (original code)
            response = bedrock.invoke_model(
                modelId=model,
                body=body
            )

            response_body = json.loads(response['body'].read())

            openai_response = {
                "id": "chatcmpl-" + response['ResponseMetadata']['RequestId'],
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": response_body['content'][0]['text']
                    },
                    "finish_reason": response_body['stop_reason']
                }]
            }
            return json.dumps(openai_response)

    if __name__ == '__main__':
        app.run(host='0.0.0.0', port=8000)
    PYTHON_EOF

    cat > requirements.txt <<'EOF'
    flask==3.0.0
    boto3==1.34.0
    EOF

    cat > Dockerfile <<'EOF'
    FROM registry.access.redhat.com/ubi9/python-39:latest
    USER root
    WORKDIR /app
    COPY requirements.txt .
    RUN pip install --no-cache-dir -r requirements.txt
    COPY app.py .
    USER 1001
    EXPOSE 8000
    CMD ["python", "app.py"]
    EOF
    ```

1. Expose the OpenShift internal image registry

    ```bash
    oc patch configs.imageregistry.operator.openshift.io/cluster \
      --type merge \
      --patch '{"spec":{"defaultRoute":true}}'
    ```

1. Get the OpenShift internal registry route

    ```bash
    export REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
    echo $REGISTRY
    ```

1. Login to the OpenShift internal registry

    ```bash
    podman login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY
    ```

1. Build and tag the image for the internal registry

    {{% alert state="info" %}}If building on a Mac, specify the platform to ensure compatibility with OpenShift's x86_64 nodes.{{% /alert %}}

    ```bash
    podman build --platform linux/amd64 -t $REGISTRY/${LIGHTSPEED_NAMESPACE}/bedrock-proxy:latest .
    ```

1. Push the image to OpenShift internal registry

    ```bash
    podman push $REGISTRY/${LIGHTSPEED_NAMESPACE}/bedrock-proxy:latest
    ```

1. Deploy the proxy

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: bedrock-proxy
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: bedrock-proxy
      template:
        metadata:
          labels:
            app: bedrock-proxy
        spec:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
          containers:
          - name: proxy
            image: image-registry.openshift-image-registry.svc:5000/${LIGHTSPEED_NAMESPACE}/bedrock-proxy:latest
            ports:
            - containerPort: 8000
            env:
            - name: AWS_REGION
              value: ${AWS_REGION}
            - name: BEDROCK_MODEL_ID
              value: ${BEDROCK_MODEL_ID}
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: bedrock-proxy
      namespace: ${LIGHTSPEED_NAMESPACE}
    spec:
      selector:
        app: bedrock-proxy
      ports:
      - port: 8000
        targetPort: 8000
    EOF
    ```

1. Wait for proxy to be ready

    ```bash
    oc wait --for=condition=available deployment/bedrock-proxy \
      -n ${LIGHTSPEED_NAMESPACE} \
      --timeout=300s
    ```

1. Create a credentials secret for the provider

    {{% alert state="info" %}}Even though the proxy uses IRSA for authentication, the OLSConfig schema requires a credentialsSecretRef with a key named `apitoken`. We'll create a dummy secret to satisfy the validation.{{% /alert %}}

    ```bash
    oc create secret generic bedrock-credentials \
      -n ${LIGHTSPEED_NAMESPACE} \
      --from-literal=apitoken=dummy
    ```

1. Create the OLSConfig custom resource

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: ols.openshift.io/v1alpha1
    kind: OLSConfig
    metadata:
      name: cluster
    spec:
      llm:
        providers:
          - name: bedrock-openai-proxy
            type: openai
            url: http://bedrock-proxy.${LIGHTSPEED_NAMESPACE}.svc.cluster.local:8000/v1
            credentialsSecretRef:
              name: bedrock-credentials
            models:
            - name: ${BEDROCK_MODEL_ID}
              url: http://bedrock-proxy.${LIGHTSPEED_NAMESPACE}.svc.cluster.local:8000/v1
      ols:
        conversationCache:
          type: postgres
          postgres:
            host: lightspeed-postgres.${LIGHTSPEED_NAMESPACE}.svc.cluster.local
            port: 5432
            dbname: lightspeed
            user: lightspeed
            passwordSecret:
              name: postgres-password
              key: password
        defaultModel: ${BEDROCK_MODEL_ID}
        defaultProvider: bedrock-openai-proxy
        logLevel: INFO
    EOF
    ```

## Verify the OLSConfig

1. Check if the OLSConfig was created successfully

    ```bash
    oc get olsconfig cluster -o yaml
    ```

1. Verify there are no validation errors

    ```bash
    oc get olsconfig cluster -o jsonpath='{.status.conditions[?(@.type=="Valid")]}' | jq .
    ```

1. Check the OLSConfig status

    ```bash
    oc describe olsconfig cluster
    ```

    Look for events and status conditions. A healthy OLSConfig should show:
    - `Valid: True`
    - No error messages in the events

1. Check the operator logs for reconciliation issues

    ```bash
    oc logs -n openshift-lightspeed-operator deployment/lightspeed-operator-controller-manager --tail=100
    ```

## Verify the Installation

1. Check the Lightspeed deployment status

    ```bash
    oc get deployment -n ${LIGHTSPEED_NAMESPACE}
    ```

1. Verify the pods are running

    ```bash
    oc get pods -n ${LIGHTSPEED_NAMESPACE}
    ```

1. Check the Lightspeed application server logs

    ```bash
    oc logs -n ${LIGHTSPEED_NAMESPACE} deployment/lightspeed-app-server --tail=50
    ```

1. Verify the Bedrock proxy is working

    ```bash
    oc logs -n ${LIGHTSPEED_NAMESPACE} deployment/bedrock-proxy --tail=50
    ```

## Access OpenShift Lightspeed

1. Access Lightspeed through the OpenShift web console

    Navigate to the OpenShift console and look for the Lightspeed icon (typically in the top navigation bar or help menu).

1. Test the integration

    Try asking questions like:
    - "How do I create a new project?"
    - "Show me how to deploy a containerized application"
    - "What are the current pod resources in my cluster?"

## Troubleshooting

### OLSConfig Validation Errors

If you see validation errors like "credentialsSecretRef: Required value" or "missing key 'apitoken'":

1. Ensure the credentials secret exists and has the correct key:
   ```bash
   oc get secret bedrock-credentials -n ${LIGHTSPEED_NAMESPACE} -o yaml
   ```

2. The secret must have a key named `apitoken` (not `api_key`):
   ```bash
   oc create secret generic bedrock-credentials \
     -n ${LIGHTSPEED_NAMESPACE} \
     --from-literal=apitoken=dummy \
     --dry-run=client -o yaml | oc apply -f -
   ```

### Environment Variables Not Expanding

If the OLSConfig shows literal `${LIGHTSPEED_NAMESPACE}` in URLs instead of the actual namespace:

1. Check that the environment variable is set:
   ```bash
   echo $LIGHTSPEED_NAMESPACE
   ```

2. If using a heredoc, ensure you use `cat <<EOF` (without quotes) to allow variable expansion, or replace the variable with the actual namespace value `openshift-lightspeed`.

3. Verify the URLs in the OLSConfig:
   ```bash
   oc describe olsconfig cluster | grep URL
   ```

### Operator Not Reconciling

If the OLSConfig exists but no app server pods are created:

1. Check operator logs for errors:
   ```bash
   oc logs -n openshift-lightspeed deployment/lightspeed-operator-controller-manager --tail=50
   ```

2. Trigger a manual reconciliation:
   ```bash
   oc annotate olsconfig cluster reconcile-trigger="$(date +%s)" --overwrite
   ```

3. Wait for the lightspeed-app-server pod to be created (image pull can take 3-5 minutes):
   ```bash
   oc get pods -n openshift-lightspeed -w
   ```

### Permission Errors

If you see permission errors in the logs:

```bash
oc logs -n ${LIGHTSPEED_NAMESPACE} -l app=openshift-lightspeed | grep -i "access denied\|forbidden"
```

Verify the IAM role has the correct permissions:

```bash
aws iam list-attached-role-policies \
  --role-name ${CLUSTER_NAME}-lightspeed-bedrock
```

### Model Access Issues

Verify model access in Bedrock:

```bash
aws bedrock get-foundation-model \
  --model-identifier ${BEDROCK_MODEL_ID} \
  --region ${AWS_REGION}
```

### Service Account Annotation

Verify the service account has the correct IAM role annotation:

```bash
oc get serviceaccount ${SERVICE_ACCOUNT_NAME} -n ${LIGHTSPEED_NAMESPACE} -o yaml | grep eks.amazonaws.com/role-arn
```

## Cleanup

To remove OpenShift Lightspeed and associated resources:

1. Delete the OLSConfig

    ```bash
    oc delete olsconfig cluster
    ```

1. Delete the operator subscription

    ```bash
    oc delete subscription openshift-lightspeed -n openshift-operators
    ```

1. Delete the namespace

    ```bash
    oc delete namespace ${LIGHTSPEED_NAMESPACE}
    ```

1. Remove AWS IAM resources

    ```bash
    aws iam detach-role-policy \
      --role-name ${CLUSTER_NAME}-lightspeed-bedrock \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-lightspeed-bedrock

    aws iam delete-role \
      --role-name ${CLUSTER_NAME}-lightspeed-bedrock

    aws iam delete-policy \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-lightspeed-bedrock
    ```

## Additional Resources

- [OpenShift Lightspeed Documentation](https://docs.openshift.com/container-platform/latest/lightspeed/lightspeed-about.html)
- [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/)
- [ROSA STS Documentation](https://docs.openshift.com/rosa/rosa_getting_started_sts/rosa-sts-overview.html)
