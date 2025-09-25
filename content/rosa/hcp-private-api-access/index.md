---
## Content migrated to product documentation: https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-aws-private-creating-cluster.html#rosa-hcp-aws-private-security-groups_rosa-hcp-aws-private-creating-cluster
date: "2024-09-10"
title: "Configuring ROSA with HCP Private Cluster API Access"
tags: ["AWS", "ROSA", "ROSA with HCP"]
authors:
   - Michael McNeill
---

With ROSA with HCP private clusters, the AWS PrivateLink endpoint exposed in the customer's VPC has a default security group. This security group has access to the PrivateLink endpoint that is limited to only those resources that exist within the VPC or resources that are present with an IP address associated with the VPC CIDR range. In order to grant access to any entities outside of the VPC, through VPC peering and transit gateway, you must create and attach another security group to the PrivateLink endpoint to grant the necessary access.

### Prerequisites

* Your corporate network or other VPC has connectivity.
* You have permission to create and attach security groups within the VPC.

### Procedure

1. Set your cluster name as an environment variable by running the following command:
    ```bash
    export CLUSTER_NAME=<cluster_name>
    ```
    You can verify that the variable has been set by running the following command:
    ```bash
    echo $CLUSTER_NAME
    ```
    _Example output_
    ```text
    hcp-private
    ```

1. Find the VPC endpoint (VPCE) ID and VPC ID by running the following command:
    ```bash
    read -r VPCE_ID VPC_ID <<< $(aws ec2 describe-vpc-endpoints --filters "Name=tag:api.openshift.com/id,Values=$(rosa describe cluster -c ${CLUSTER_NAME} -o yaml | grep '^id: ' | cut -d' ' -f2)" --query 'VpcEndpoints[].[VpcEndpointId,VpcId]' --output text)
    ```

1. Create your security group by running the following command:
    ```bash
    export SG_ID=$(aws ec2 create-security-group --description "Granting API access to ${CLUSTER_NAME} from outside of VPC" --group-name "${CLUSTER_NAME}-api-sg" --vpc-id $VPC_ID --output text)
    ```

1. Add an ingress rule to the security group by running the following command:
    ```bash
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --ip-permissions FromPort=443,ToPort=443,IpProtocol=tcp,IpRanges=[{CidrIp=0.0.0.0/0}]
    ```

1. Add the new security group to the VPCE by running the following command:
    ```bash
    aws ec2 modify-vpc-endpoint --vpc-endpoint-id $VPCE_ID --add-security-group-ids $SG_ID
    ```

You now can access the API with your ROSA with HCP private cluster.