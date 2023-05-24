---
date: '2022-09-14T22:07:09.764151'
title: Create IAM user and Policy
tags: ["AWS", "ROSA"]
authors:
  - Shaozhen Ding 
---

**Notes: These are sample commands. Please fill in your own resource parameters E.g. ARN**

* Create the policy

```
cat <<EOF > /tmp/iam_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken"
            ],
            "Resource": "*"
        }
    ]
}
EOF
aws iam create-policy \
    --policy-name ECRLoginPolicy \
    --policy-document file:///tmp/iam_policy.json
```    

* Create a user and access key and attach the policy

```
aws iam create-user --user-name ecr-bot
aws create-access-key --user-name ecr-bot
aws iam attach-user-policy --policy-arn arn:aws:iam::[ACCOUNT_ID]:policy/ECRLoginPolicy --user-name ecr-bot
```

**Notes: Save access key id and key for later usage**


* Set up a specific ECR repository access

```
cat <<EOF > /tmp/repo_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowPushPull",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::[ACCOUNT_ID]:user/ecr-bot"
                ]
            },
            "Action": [
                "ecr:BatchGetImage",
                "ecr:BatchCheckLayerAvailability",
                "ecr:CompleteLayerUpload",
                "ecr:GetDownloadUrlForLayer",
                "ecr:InitiateLayerUpload",
                "ecr:PutImage",
                "ecr:UploadLayerPart"
            ]
        }
    ]
}
EOF

aws ecr set-repository-policy --repository-name test --policy-text file:///tmp/repo_policy.json
```

* Create kubernetes Secret with iam user

```
cat <<EOF > /tmp/credentials
[default]
aws_access_key_id=""
aws_secret_access_key=""
EOF


oc create secret generic aws-ecr-cloud-credentials --from-file=credentials=/tmp/credentials
```