## Create STS Assume Role

[About AWS STS and Assume Role](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)

**Notes: These are sample commands. Please fill in your own resource parameters E.g. ARN**

* Prequisites

  [An STS Openshift Cluster](https://docs.openshift.com/container-platform/4.10/authentication/managing_cloud_provider_credentials/cco-mode-sts.html)

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

* Create the role and attach the policy

```
cat <<EOF > /tmp/trust_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::[ACCOUNT_ID]:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/1ou2pbj9v68ghlc63bo0mad059cj1elf"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "rh-oidc.s3.us-east-1.amazonaws.com/1ou2pbj9v68ghlc63bo0mad059cj1elf:sub": "system:serviceaccount:ecr-secret-operator:ecr-secret-operator-controller-manager"
                }
            }
        }
    ]
}
EOF

aws iam create-role --role-name ECRLogin --assume-role-policy-document file:///tmp/trust_policy.json
aws iam attach-role-policy --role-name ECRLogin --policy-arn arn:aws:iam::[ACCOUNT_ID]:policy/ECRLoginPolicy
```

* Create the repository policy

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
                    "arn:aws:iam::[ACCOUNT_ID]:role/ECRLogin"
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

* Create STS kubernetes Secret

```
cat <<EOF > /tmp/credentials
[default]
role_arn = arn:aws:iam::[ACCOUNT_ID]:role/ECRLogin
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF


oc create secret generic aws-ecr-cloud-credentials --from-file=credentials=/tmp/credentials
```