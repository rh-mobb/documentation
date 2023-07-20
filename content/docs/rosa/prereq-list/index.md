# ROSA Classic Prerequisites Checklist
rev 0.1

## Background
This is a quick checklist of prerequisites needed to spin up a ROSA cluster. Note that this is a high level checklist and your implementation may vary. 

## ROSA Prerequisites with STS
Before proceeding futher, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-aws-prereqs_rosa-sts-aws-prereqs).

- AWS account with following details:
    - AWS IAM User
    - AWS Access Key ID
    - AWS Secret Access Key
- Red Hat account:
    - Create one [here](https://console.redhat.com/) if you do not have it already.
- AWS CLI:
    - Install from [here](https://aws.amazon.com/cli/) if you have not already.
- Enabling ROSA and its CLI: 
    - Enable ROSA from your AWS account [here](https://console.aws.amazon.com/rosa/) if you have not already.
    - Install the CLI from [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-installing-rosa.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-rosa).
- OpenShift CLI:
    - Install from [here](https://docs.openshift.com/container-platform/4.13/cli_reference/openshift_cli/getting-started-cli.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-oc)
- 




## ROSA Prerequisites without STS 
Before proceeding futher, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html).