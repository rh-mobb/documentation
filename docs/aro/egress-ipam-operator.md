# Using the Egressip Ipam Operator with a Private ARO Cluster

## Prerequisites

* [A private ARO cluster with a VPN Connection](./private-cluster) and the egress LB removed


#### Delete the ARO egress LB

> Note: you should only do this if enabled the firewall egress above and you plan to use the [egress-ipam-operator](./egress-ipam-operator) doing this may render your ARO cluster **UNSUPPORTED** by Red Hat / Azure, so speak to your support
 team before doing this.

1. Get and Login as Service Principal

    ```bash
    oc login $APISERVER -u kubeadmin -p $ADMINPW
    SPAPPID="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_client_id | base64 --decode)"
    SPSECRET="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_client_secret | base64 --decode)"
    SPTENANT="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_tenant_id | base64 --decode)"
    CLUSTERRG="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_resourcegroup |base64 --decode)"
    az login --service-principal -u $SPAPPID -p $SPSECRET -t $SPTENANT
    ```

1. get the name of the LB

    ```
LB_NAME=$(az network lb list --query '[].name' -o tsv | grep -v 'internal')
echo $LB_NAME
    ```

1. delete the outbound rule

    ```
az network lb outbound-rule delete -n outbound-rule-v4 \
  --lb-name $LB_NAME -g $CLUSTERRG
    ```

## Deploy the Operator

### Via GUI

1. Log into the ARO cluster's Console

1. Switch to the Administrator view

1. Click on Operators -> Operator Hub

1. Search for "Egressip Ipam Operator"

1. Install it with the default settings

or

### Via CLI

1. Deploy the `egress-ipam-operator`

    ```bash
cat << EOF | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: egressip-ipam-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: egressip-ipam-operator
  namespace: openshift-operators
  labels:
    operators.coreos.com/egressip-ipam-operator.egressip-ipam-operator: ''
spec:
  channel: alpha
  installPlanApproval: Automatic
  name: egressip-ipam-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  startingCSV: egressip-ipam-operator.v1.2.2
EOF
    ```

## Configure EgressIP

1. Create an EgressIPAM resource for your cluster.  Update the CIDR to reflect the worker node subnet.

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: redhatcop.redhat.io/v1alpha1
kind: EgressIPAM
metadata:
  name: egressipam-azure
  annotations:
      egressip-ipam-operator.redhat-cop.io/azure-egress-load-balancer: none
spec:
  # Add fields here
  cidrAssignments:
    - labelValue: ""
      CIDR: 10.0.1.0/24
      reservedIPs: []
  topologyLabel: "node-role.kubernetes.io/worker"
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
EOF
    ```

1. Create test namespaces

    ```bash
cat << EOF | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: egressipam-azure-test
  annotations:
    egressip-ipam-operator.redhat-cop.io/egressipam: egressipam-azure
---
apiVersion: v1
kind: Namespace
metadata:
  name: egressipam-azure-test-1
  annotations:
    egressip-ipam-operator.redhat-cop.io/egressipam: egressipam-azure
EOF
    ```

1. Check the namespaces have IPs assigned

    ```bash
kubectl get namespace egressipam-azure-test \
  egressipam-azure-test-1 -o yaml | grep egressips
    ```

    The output should look like:

    ```
    egressip-ipam-operator.redhat-cop.io/egressips: 10.0.1.8
    egressip-ipam-operator.redhat-cop.io/egressips: 10.0.1.7
    ```

1. Check they're actually set as Egress IPs

    ```bash
oc get netnamespaces | egrep 'NAME|egress'
    ```

    The output should look like:

    ```
    NAME                                               NETID      EGRESS IPS
    egressip-ipam-operator                             6374875
    egressipam-azure-test                              6917470    ["10.0.1.8"]
    egressipam-azure-test-1                            16320378   ["10.0.1.7"]
    ```

1. Finally check the Host Subnets for Egress IPS

    ```bash
oc get hostsubnets
    ```

    The output should look like:

    ```
    NAME                                         HOST                                         HOST IP    SUBNET          EGRESS CIDRS   EGRESS IPS
    private-cluster-bj275-master-0               private-cluster-bj275-master-0               10.0.0.8   10.129.0.0/23
    private-cluster-bj275-master-1               private-cluster-bj275-master-1               10.0.0.7   10.128.0.0/23
    private-cluster-bj275-master-2               private-cluster-bj275-master-2               10.0.0.9   10.130.0.0/23
    private-cluster-bj275-worker-eastus1-zt59t   private-cluster-bj275-worker-eastus1-zt59t   10.0.1.4   10.128.2.0/23                  ["10.0.1.8"]
    private-cluster-bj275-worker-eastus2-bfrwt   private-cluster-bj275-worker-eastus2-bfrwt   10.0.1.5   10.129.2.0/23                  ["10.0.1.7"]
    private-cluster-bj275-worker-eastus3-fgjzk   private-cluster-bj275-worker-eastus3-fgjzk   10.0.1.6   10.131.0.0/23
    ```

1. If any of these do not give the correct output, it could be because you haven't removed the `egress-lb` from the cluster. Check the logs of the `egress-ipam` operator for errors

    ```bash
kubectl -n openshift-operators logs \
  deployment/egressip-ipam-operator-controller-manager \
  -c manager -f
     ```

## Test Egress

1. Log into your jumpbox and allow http into firewall

    ```bash
    sudo firewall-cmd --zone=public --add-service=http
    ```

1. Install and start apache httpd

    ```bash
    sudo yum -y install httpd
    sudo systemctl start httpd
    ```

1. Create a index.html

    ```bash
    echo HELLO | sudo tee /var/www/html/index.html
    ```

1. tail apache logs

    ```bash
    sudo tail -f /var/log/httpd/access_log
    ```

1. Start an interactive pod in one of your new namespaces

    ```bash
    kubectl run -n egressipam-azure-test -i \
      --tty --rm debug --image=alpine \
      --restart=Never -- wget -O - 10.0.3.4
    ```

    The output should look the following (the IP should match the egress IP of your namespace):

    ```bash
    10.0.1.7 - - [03/Feb/2022:19:33:54 +0000] "GET / HTTP/1.1" 200 6 "-" "Wget"
    ```

1. Deploy a hello world pod

    ```bash
oc new-project hello
oc new-app --docker-image=docker.io/openshift/hello-openshift
oc expose service/hello-openshift
    ```

1. Create an interactive pod in one of the new namespaces

    ```bash
kubectl run -n egressipam-azure-test -i --tty --rm debug --image=fedora --restart=Never
    ```

1. Create


oc new-project hello
    oc new-app --docker-image=docker.io/openshift/hello-openshift
    oc create route edge --service=hello-openshift hello-openshift-tls \
        --hostname hello.apps.reinvent.aws.mobb.ninja
