# ROSA Classic with STS Prerequisites Checklist
rev 0.1

## Background
This is a quick checklist of prerequisites needed to spin up a classic [Red Hat OpenShift Service on AWS (ROSA)](https://developers.redhat.com/products/red-hat-openshift-service-on-aws/overview) cluster with [STS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html). Note that this is a high level checklist and your implementation may vary. 

## Generic Prerequisites
Before proceeding futher, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-aws-prereqs_rosa-sts-aws-prereqs).

- AWS account:
    - You would need the following details:
        - AWS IAM User
        - AWS Access Key ID
        - AWS Secret Access Key
- AWS CLI (`aws`):
    - Install from [here](https://aws.amazon.com/cli/) if you have not already.
    - Configure the CLI:
        - Enter `aws configure` in the terminal.
        - Enter the AWS Access Key ID and press enter.
        - Enter the AWS Secret Access Key and press enter.
        - Enter the default region you want to deploy into.
        - Enter the output format you want (“table” or “json”). 
        - Verify the output by running `aws sts get-caller-identity`.
        - Ensure that the service role for ELB already exists by running `aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing"`
            - If it does not exist, run `aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"`
- Red Hat account:
    - Create one [here](https://console.redhat.com/) if you have not already.
- ROSA CLI (`rosa`): 
    - Enable ROSA from your AWS account [here](https://console.aws.amazon.com/rosa/) if you have not already.
    - Install the CLI from [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-installing-rosa.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-rosa).
    - Enter `rosa login` in a terminal, and this will prompt you to go to the [token page](https://console.redhat.com/openshift/token/rosa) via the console.
    - Log in with your Red Hat account credentials.
    - Click the "Load token" button.
    - Copy the token and paste it back into the CLI prompt and press enter.
        - Alternatively, you can copy the full `rosa login --token=abc...` command and paste that in the terminal.
    - Verify your credentials by running `rosa whoami`.
    - Ensure you have sufficient quota by running `rosa verify quota`.
        - Please refer [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#rosa-aws-policy-provisioned_prerequisites) for more details on AWS services provisioned for ROSA cluster. 
        - Please refer [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-required-aws-service-quotas.html#rosa-required-aws-service-quotas) for more details on AWS services quota. 
- OpenShift CLI (`oc`):
    - Install from [here](https://docs.openshift.com/container-platform/4.13/cli_reference/openshift_cli/getting-started-cli.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-oc).
    - Verify that the OpenShift CLI has been installed correctly by running `rosa verify openshift-client`.

Once you have the above prerequisites installed and enabled, let's proceed to the next steps.


## SCP Prerequisites
In this section, we will discuss about the minimum set of effective permissions for [service control policy (SCP)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html). 

Ensure that your organization's SCP does not restrict any of these [required permissions](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#rosa-minimum-scp_prerequisites).


## Networking Prerequisites
Next, let's talk about the prerequisites needed from networking standpoint.

- Firewall
    - Configure your firewall to allow access to the domains and ports listed [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#osd-aws-privatelink-firewall-prerequisites_prerequisites)
- Custom DNS
- 



## ROSA Prerequisites without STS 
Note that we do not discuss about the prerequisites for a classic ROSA cluster without STS in this article. And thus, if that is your preferred scenario, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html).