# Deploying 3scale API Management to ROSA and OSD

**Michael McNeill**

*26 January 2022*

This document will take you through deploying 3scale in any OSD or ROSA cluster. Review the [official documentation here](https://access.redhat.com/documentation/en-us/red_hat_3scale_api_management/) for more information or how to further customize or use 3scale.

## Prerequisites

* An existing ROSA or OSD cluster
* Access to an AWS account with permissions to create S3 buckets, IAM users, and IAM policies
* A subscription for 3scale API Management
* A wildcard domain configured with a CNAME to your cluster's ingress controller 

## Prepare AWS Account

1. Set environment variables (ensuring you update the variables appropriately!)

```bash
export S3_BUCKET=<your-bucket-name-here>
export REGION=us-east-1
export S3_IAM_USER_NAME=<your-s3-user-name-here>
export S3_IAM_POLICY_NAME=<your-s3-policy-name-here>
export AWS_PAGER=""
export PROJECT_NAME=<your-project-name-here>
export WILDCARD_DOMAIN=<your-wildcard-domain-here>
```

For my example, I'll be using the following variables:

```bash
export S3_BUCKET=mobb-3scale-bucket
export REGION=us-east-1
export S3_IAM_USER_NAME=mobb-3scale-user
export S3_IAM_POLICY_NAME=3scale-s3-access
export AWS_PAGER=""
export PROJECT_NAME=3scale-example
export WILDCARD_DOMAIN=3scale.example.com
```

2. Create an S3 bucket

```bash
aws s3 mb s3://$S3_BUCKET
```

3. Apply the proper S3 bucket CORS configuration

```bash
aws s3api put-bucket-cors --bucket $S3_BUCKET --cors-configuration \
'{
	"CORSRules": [{
		"AllowedMethods": [
			"GET"
		],
		"AllowedOrigins": [
			"https://*"
		]
	}]
}'
```

4. Create an IAM policy for access to the S3 bucket

```bash
POLICY_ARN=$(aws iam create-policy --policy-name "$S3_IAM_POLICY_NAME" \
--output text --query "Policy.Arn" \
--policy-document \
'{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:ListAllMyBuckets",
            "Resource": "arn:aws:s3:::*"
        },
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::'$S3_BUCKET'",
                "arn:aws:s3:::'$S3_BUCKET'/*"
            ]
        }
    ]
}')
```

5. Create an IAM user to access the S3 bucket

```bash
aws iam create-user --user-name $S3_IAM_USER_NAME
```

6. Generate an access key for the newly created S3 user

```bash
ACCESS_CREDS=$(aws iam create-access-key --user-name $S3_IAM_USER_NAME \
--output text --query "AccessKey.[AccessKeyId, SecretAccessKey]")
```

7. Apply the IAM policy to the newly created S3 user

```bash
aws iam attach-user-policy --user-name $S3_IAM_USER_NAME \
--policy-arn $POLICY_ARN
```

## Install the 3Scale API Management Operator

8. Create a new project to install 3Scale API Management into.

```bash
oc new-project $PROJECT_NAME
```

Inside of the OpenShift Web Console, navigate to Operators -> OperatorHub.

9. Search for "3scale" and select the "Red Hat Integration - 3scale" Operator.

![OperatorHub](./OperatorHub.png)

10. Click "Install" and select the project you wish to install the operator into. 

![Operator Installation Flow](./Operator-Install.png)

For this example, I'm deploying into the "3scale-example" project that I have just created.

11. Once the 3Scale operator successfully installs, return to your terminal.

## Deploy 3Scale API Management

12. Create a secret that contains the Amazon S3 configuration.

```bash
echo 'apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: aws-auth
stringData:
  AWS_ACCESS_KEY_ID: '$(echo $ACCESS_CREDS | cut -f 1)'
  AWS_SECRET_ACCESS_KEY: '$(echo $ACCESS_CREDS | cut -f 2)'
  AWS_BUCKET: '$S3_BUCKET'
  AWS_REGION: '$REGION'
type: Opaque' | oc create -f -
```

13. Create an APIManager custom resource

```bash
echo 'apiVersion: apps.3scale.net/v1alpha1
kind: APIManager
metadata:
  name: example-apimanager
spec:
  wildcardDomain: '$WILDCARD_DOMAIN'
  system:
    fileStorage:
      simpleStorageService:
        configurationSecretRef:
          name: aws-auth' | oc create -f -
```

14. Once the APIManager instance becomes available, you can login to the 3Scale Admin (located at https://3scale-admin.$WILDCARD_DOMAIN) using the credentials from the below commands:

```bash
oc get secret system-seed --template={{.data.ADMIN_USER}} | base64 -d
oc get secret system-seed --template={{.data.ADMIN_PASSWORD}} | base64 -d
```

15. Congratulations! You've successfully deployed 3Scale API Management to ROSA/OSD.