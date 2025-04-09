---
date: '2025-04-09'
title: Add a Private Ingress Controller to a ROSA Cluster and add a Public ALB
tags: ["AWS", "ROSA"]
authors:
  - Kevin Collins
  - Paul Czarkowski
---

Starting with OpenShift 4.14, ROSA supports adding additional Ingress Controllers which can use used to configure a custom domain on a ROSA cluster without having to use the now deprecated Custom Domain Operator.  This guide shows how to add an additional Ingress Controller ( public or private ) to a ROSA cluster and optionally also configuring a custom domain.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) cluster
* The oc CLI      #logged in.
* The aws CLI     #logged in.
* The rosa CLI    #logged in.
* (optional) A Public Route53 Hosted Zone, and the related Domain to use.


## Set up environment


1. Export few environment variables
> **Important**: The variables below can be customized to fit your needs for your ingress controller.

  ```bash
  export CLUSTER_NAME=<my cluster>
  export CLUSTER_REGION=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r .region.id)
  # vpc id of rosa cluster

   #Custom Hosted Zone Domain for apps
  export DOMAIN=lab.domain.com
   #name of the new ingress controller
   export INGRESS_NAME=private-ingress #name of the new ingress controller
   export SCOPE="Internal"
   export AWS_PAGER=""
   export HOSTED_ZONE_ID=<FETCH FROM AWS CONSOLE>
   export HOSTED_ZONE_REGION=<FETCH FROM AWS CONSOLE>
   export SCRATCH_DIR=/tmp/scratch
   mkdir -p $SCRATCH_DIR
   ```

## Create the Ingress Controller.

   ```yaml
   envsubst  <<EOF | oc apply -f -
   apiVersion: operator.openshift.io/v1
   kind: IngressController
   metadata:
     annotations:
       ingress.operator.openshift.io/auto-delete-load-balancer: "true"
     finalizers:
     - ingresscontroller.operator.openshift.io/finalizer-ingresscontroller
     generation: 2
     labels:
       hypershift.openshift.io/managed: "true"
     name: $INGRESS_NAME
     namespace: openshift-ingress-operator
   spec:
     clientTLS:
       clientCA:
         name: ""
       clientCertificatePolicy: ""
    #  defaultCertificate:
    #    name: $CERT_NAME
     domain: $DOMAIN
     endpointPublishingStrategy:
       loadBalancer:
         dnsManagementPolicy: Unmanaged
         providerParameters:
           aws:
             networkLoadBalancer: {}
             type: NLB
           type: AWS
         scope: $SCOPE
       type: LoadBalancerService
     httpCompression: {}
     httpEmptyRequestsPolicy: Respond
     httpErrorCodePages:
       name: ""
     replicas: 2
     tuningOptions:
       reloadInterval: 0s
     unsupportedConfigOverrides: null
   EOF
   ```

  Describe the Ingress Controller to confirm it's ready.

   ```bash
   oc describe IngressController $INGRESS_NAME -n openshift-ingress-operator
   ```

   You should see an output that mentions that the ingress controller is Admitted.

   ```
   Normal   Admitted           2m16s  ingress_controller  ingresscontroller passed validation
   ```

   Also verify the router pods of the new ingress controller are running

   ```bash
   oc get pods -n openshift-ingress | grep $INGRESS_NAME
   ```

  Expected output is two pods in a Running state.
  ```bash
  router-public-7dd48fdcbb-bpdzc    1/1     Running   0          4m20s
router-public-7dd48fdcbb-cn7hb    1/1     Running   0          4m20s
  ```

  Verify the service of the new ingress controller is running.

  ```bash
  oc get svc -n openshift-ingress router-${INGRESS_NAME}
  ```

  Patch the service to add a healthcheck port:

  ```bash
  oc -n openshift-ingress patch svc router-${INGRESS_NAME} -p '{"spec":{"ports":[{"port":1936,"targetPort":1936,"protocol":"TCP","name":"httphealth"}]}}'
  ```

## Create an ALB

1. Get the NLB environment variables:

    ```bash
    NLB_HOSTNAME=$(oc get service -n openshift-ingress router-${INGRESS_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    NLB_NAME=$(echo $NLB_HOSTNAME | sed 's/-.*//')
    NLB_REGION=$(echo $NLB_HOSTNAME | cut -d "." -f 3)
    NLB_HOSTED_ZONE=$(aws elbv2 describe-load-balancers --name $NLB_NAME --region $NLB_REGION | jq -r ".LoadBalancers[0].CanonicalHostedZoneId")
    NLB_VPC=$(aws elbv2 describe-load-balancers --name $NLB_NAME --region $NLB_REGION | jq -r ".LoadBalancers[0].VpcId")
    echo "NLB_HOSTNAME="${NLB_HOSTNAME}
    echo "NLB_NAME="${NLB_NAME}
    echo "NLB_REGION="${NLB_REGION}
    echo "NLB_HOSTED_ZONE="${NLB_HOSTED_ZONE}
    echo "NLB_VPC="${NLB_VPC}
    ```

1. Create a target group for the NLB IP addresses

    ```bash
    aws elbv2 create-target-group --name router-${INGRESS_NAME} \
      --protocol TCP --port 1936 --vpc-id ${NLB_VPC} \
      --health-check-protocol HTTP --health-check-port 1936 \
      --health-check-path /httphealth --health-check-enabled \
      --target-type ip
    TG_ARN=$(aws elbv2 describe-target-groups --name router-${INGRESS_NAME} | jq -r '.TargetGroups[0].TargetGroupArn')
    ```

1. Get IP addresses of the NLB

    ```bash
    host ${NLB_HOSTNAME}
    ```

1. Create targets for each of the IP addresses

    ```bash
    aws elbv2 register-targets --target-group-arn ${TG_ARN}  \
     --targets '[{"Id":"<IP_ADDRESS>","Port":443}]'

    ```

1. Create a AWS Certificate Manager (ACM) certificate for the new domain

    ```bash
    aws acm request-certificate --domain-name "*.${DOMAIN}" \
      --validation-method DNS \
      --idempotency-token $(uuidgen | sed 's/-//g')
    ```

1. Get the ARN of the ACM certificate

    ```bash
    ACM_ARN=$(aws acm list-certificates --query="CertificateSummaryList[?DomainName=='*.${DOMAIN}'].CertificateArn" --output text)
    ```

1. Create an ALB for the new domain

    # todo

### Create a Route 53 entry for the new domain / network load balancer

# todo


## Test an application.

1. Create a test applciation in a new namespace.

    # todo