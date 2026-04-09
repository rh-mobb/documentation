---
date: '2026-03-30'
title: 'Configuring a ROSA cluster to pull images from AWS Elastic Container Registry (ECR)'
tags: ["ROSA", "ROSA HCP", "ROSA Classic"]
authors:
  - Kevin Collins
  - Byron Miller
  - Deepika Ranganathan
validated_version: "4.20"
---

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Openshift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/) 4.11+
* [Podman Desktop](https://podman-desktop.io/)
* [ROSA Cluster](https://cloud.redhat.com/experts/rosa/quickstart/)


## Background
Quick Introduction by Ryan Niksch & Charlotte Fung on [YouTube](https://youtu.be/1PBFtpCIMBo).

 <iframe width="560" height="315" src="https://www.youtube.com/embed/1PBFtpCIMBo" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>  <br/>

There are two options to use to authenticate wth Amazon ECR to pull images.

The traditional method is to create a pull secret for ecr.

Example:

```
oc create secret docker-registry ecr-pull-secret  \
  --docker-server=<registry id>.dkr.ecr.<region>.amazonaws.com  \
  --docker-username=AWS --docker-password=$(aws ecr get-login-password) \
  --namespace=hello-world
```

However Amazon ECR tokens expire every 12 hours which will mean you will need to re-authenticate every 12 hours either through scripting or do so manually.

A second, and preferred method, is to attach an ECR Policy to your cluster's worker machine profiles which this guide will walk you through.

ROSA worker nodes are provisioned with predefined IAM roles ( ManagedOpenShift-HCP-ROSA-Worker-Role for ROSA HCP and ManagedOpenShift-Worker-Role for ROSA Classic) which can be updated with an Amazon ECR policy to allow the cluster to pull images from your registries.

## Configure ECR with ROSA

1. Set ENV variables

    ```
    export REGION="us-east-1"
    export REPO_NAME="hello-ecr"
    export CLUSTER_NAME="my-cluster"
    export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export REPO_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO_NAME}"
    export SCRATCH_DIR=~/tmp/rosa-ecr
    mkdir -p $SCRATCH_DIR
        
    export WORKER_ROLE=$(rosa describe cluster -c ${CLUSTER_NAME} -o json | jq -r '.aws.sts.instance_iam_roles.worker_role_arn | split("/")[-1]')
    echo $WORKER_ROLE
    ```
   
2. Create an ECR repository

    ```
    aws ecr create-repository \
        --repository-name $REPO_NAME \
        --image-scanning-configuration scanOnPush=true \
        --region $REGION
    ```

3. Create the IAM policy with ECR permissions.

    ```
    cat <<EOF > $SCRATCH_DIR/rosa-ecr-read-policy.json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "ECRAuth",
                "Effect": "Allow",
                "Action": [
                    "ecr:GetAuthorizationToken"
                ],
                "Resource": "*"
            },
            {
                "Sid": "ECRScopedRead",
                "Effect": "Allow",
                "Action": [
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:GetRepositoryPolicy",
                    "ecr:DescribeRepositories",
                    "ecr:ListImages",
                    "ecr:DescribeImages",
                    "ecr:BatchGetImage",
                    "ecr:GetLifecyclePolicy",
                    "ecr:GetLifecyclePolicyPreview",
                    "ecr:ListTagsForResource",
                    "ecr:DescribeImageScanFindings"
                ],
                "Resource": "$REPO_ARN"
            }
        ]
    }
    EOF
    ```

4. Create the Customer Managed Policy
 
     ```
     POLICY_ARN=$(aws iam create-policy \
            --policy-name ROSA-ECR-Scoped-Read-Policy \
            --policy-document file://$SCRATCH_DIR/rosa-ecr-read-policy.json \
            --query 'Policy.Arn' --output text)
     ```

5. Attach policy to the worker IAM role. 

    ```
    aws iam attach-role-policy \
      --role-name $WORKER_ROLE \
      --policy-arn $POLICY_ARN
    ```
    
6. Log into ECR  

    ```
    podman login -u AWS -p $(aws ecr get-login-password --region $REGION) $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
    ```

7. Pull an image  

    ```
    podman pull openshift/hello-openshift
    ```

8. Tag the image for ecr  

    ```
    podman tag openshift/hello-openshift:latest $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/${REPO_NAME}:latest
    ```

9. Push the image to ECR  

    ```
    podman push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/${REPO_NAME}:latest
    ```

10. Create a new project  

    ```
    oc new-project hello-ecr
    ```

11. Create a new app using the image on ECR  

    ```
    oc new-app --name hello-ecr --allow-missing-images \
         --image $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/${REPO_NAME}:latest
    ```

12. View a list of pods in the namespace you created:
        
    ```
    oc get pods
    ```

    Expected output:
    
     If you see the hello-ecr pod running ... congratulations!  You can now pull images from your ECR repository.

## Clean up    

1. Simply delete the project you created to test pulling images:

   ```
    oc delete project hello-ecr
    ```

3. Detach and delete the IAM policy

    ```
    aws iam detach-role-policy --role-name $WORKER_ROLE --policy-arn $POLICY_ARN
    aws iam delete-policy --policy-arn $POLICY_ARN
    ```

4. Remove local files and ECR repository

    ```
    rm -rf $SCRATCH_DIR
    aws ecr delete-repository --repository-name $REPO_NAME --force
    ```
