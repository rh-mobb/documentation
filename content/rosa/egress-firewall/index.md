---
date: '2024-07-26'
title: Configure Pod Security Policies and Egress Firewalls for a ROSA Cluster
tags: ["OSD", "ROSA", "security","egressfirewall", "networkpolicy"]
authors:
  - 'Paul Czarkowski'
---

It's common to want to restrict network access between namespaces, as well as restricting where traffic can go outside of the cluster.  OpenShift achieves this with the [Network Policy](https://docs.openshift.com/container-platform/4.15/networking/network_policy/about-network-policy.html) and [Egress Firewall](https://docs.openshift.com/container-platform/4.15/networking/ovn_kubernetes_network_provider/configuring-egress-firewall-ovn.html) resources.

It's common to use these methods to restrict network traffic alongside [Egress IP](../egress-ip) and other [OpenShift and OVN-Kubernetes](https://docs.openshift.com/container-platform/4.15/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html) resources.

## Prerequisites

* [ROSA Cluster 4.14](../terraform/classic)
* openshift-cli (`oc`)
* rosa-cli (`rosa`)
* jq

## Project Template

The first thing to do is create a Project Template that containes Network Policys and Egress Firewalls with default deny rules

1. Create and Apply a Project template with default deny rules

    > **NOTE** This template will ensure that any new projects have a default deny rule for egress, and a network policy that only allows traffic to come from an Ingress Controller

    ```yaml
    cat << "EOF" | oc apply -f -
    apiVersion: template.openshift.io/v1
    kind: Template
    metadata:
      name: project-request
      namespace: openshift-config
    parameters:
      - name: PROJECT_NAME
      - name: PROJECT_DISPLAYNAME
      - name: PROJECT_DESCRIPTION
      - name: PROJECT_ADMIN_USER
      - name: PROJECT_REQUESTING_USER
    objects:
    - apiVersion: project.openshift.io/v1
      kind: Project
      metadata:
        annotations:
          openshift.io/description: ${PROJECT_DESCRIPTION}
          openshift.io/display-name: ${PROJECT_DISPLAYNAME}
          openshift.io/requester: ${PROJECT_REQUESTING_USER}
        creationTimestamp: null
        name: ${PROJECT_NAME}
      spec: {}
      status: {}
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      metadata:
        creationTimestamp: null
        name: admin
        namespace: ${PROJECT_NAME}
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: admin
      subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: User
        name: ${PROJECT_ADMIN_USER}
    - apiVersion: k8s.ovn.org/v1
      kind: EgressFirewall
      metadata:
        name: default
        namespace: ${PROJECT_NAME}
      spec:
        egress:
          - to:
              cidrSelector: 0.0.0.0/0
            type: Deny
    - apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: deny-by-default
        namespace: ${PROJECT_NAME}
      spec:
        podSelector: {}
        policyTypes:
          - Ingress
        ingress:
          - from:
            - namespaceSelector:
                matchLabels:
                  network.openshift.io/policy-group: ingress
          - from:
            - podSelector: {}
    EOF
    ```

1. Patch the project configuration to use the newly created Project Template

    ```bash
    kubectl patch project.config.openshift.io/cluster --type=merge -p "
    apiVersion: config.openshift.io/v1
    kind: Project
    metadata:
      name: cluster
    spec:
      projectRequestTemplate:
        name: project-request
    "
    ```

1. Create a new Project to verify the policies

    ```bash
    oc new-project restricted
    ```

1. Check for EgressFirewall

    ```bash
    oc get egressfirewall -n restricted
    ```

    you should see

    ```
    NAME      EGRESSFIREWALL STATUS
    default   EgressFirewall Rules applied
    ```

1. Check for NetworkPolicy

    ```bash
    oc get networkpolicy -n restricted
    ```

    you should see

    ```
    NAME              POD-SELECTOR   AGE
    deny-by-default   <none>         15m
    ```

## Test the Network Policy

1. Create a debug pod in the default namespace to use later

    ```bash
    oc run \
      debug \
      --namespace=default \
      --image=registry.access.redhat.com/ubi9/ubi -- \
      sleep 360000
    ```

1. Create a debug pod in the restricted namespace to use later

    ```bash
    oc run \
      debug \
      --namespace=restricted \
      --image=registry.access.redhat.com/ubi9/ubi -- \
      sleep 360000
    ```

1. Deploy a web service and expose it

    ```bash
    oc -n restricted new-app --name=hello --image=docker.io/openshift/hello-openshift
    oc expose service/hello
    ROUTE=$(oc get route hello -o jsoNetwork Policyath='{.spec.host}')
    echo $ROUTE
    ```

1. See if you can access the application via its Route (you should be able to)

    ```bash
    curl -s http://$ROUTE
    ```

    You should see

    ```
    Hello OpenShift!
    ```

1. See if you can access the application via its Route from the default namespace. (again you should be able to)

    ```bash
    oc -n default debug debug -- curl -s http://$ROUTE
    ```

    You should see

    ```
    Starting pod/debug-debug-xrrmt ...
    Hello OpenShift!
    ```

1. Now try to access the application via its local service from within the same pod (this should succeed due to the Network Policy)

    ```bash
    oc -n restricted debug debug -- curl -sv http://hello.restricted:8080
    ```

    output

    ```
    Starting pod/debug-debug-p69x7 ...
    *   Trying 172.30.137.196:8080...
    ...
    ...
    Hello OpenShift!
    Removing debug pod ...
    ```

1. Now try to access the application via its local service (this should fail due to the Network Policy)

    > **NOTE:** To avoid waiting for a long timeout feel free to hit *CTRL-C*.

    ```bash
    oc -n default debug debug -- curl -sv http://hello.restricted:8080
    ```

    output

    ```
    Starting pod/debug-debug-p69x7 ...
    *   Trying 172.30.137.196:8080...
    <CTRL-C>
    ```

## Test the Egress Firewall

1. Verify you can access an external website from the default namespace debug pod (this should work)

    ```bash
    oc -n default debug debug -- curl -sSL https://icanhazip.com
    ```

    output

    ```bash
    Starting pod/debug-debug-sznlt ...
    *   Trying 104.16.185.241:443...
    * Connected to icanhazip.com (104.16.185.241) port 443 (#0)
    ...
    ...
    3.136.221.97
    ```

1. Verify that you cannot access an external website from the restricted namespace (this should fail)

    ```bash
    oc -n restricted debug debug -- curl -sSL https://icanhazip.com
    ```

    output

    ```bash
    oc -n restricted debug debug -- curl -sSL https://icanhazip.com
    Starting pod/debug-debug-rbd79 ...
    <CTRL-C>
    ```
