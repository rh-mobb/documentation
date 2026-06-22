---
date: '2026-06-01'
title: Configure Network Policies and Egress Firewalls for a ROSA Cluster
tags: ["ROSA", "ROSA HCP", "ROSA Classic"]
authors:
  - 'Paul Czarkowski'
  - 'Nerav Doshi'
validated_version: "4.20"
---

It is common to restrict network access between namespaces and to control where traffic can leave the cluster. OpenShift implements both with [NetworkPolicy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/network-policy) and [EgressFirewall](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/egress-firewall) resources on the OVN-Kubernetes network plugin.

These controls apply the same way on **ROSA Hosted Control Planes (HCP)** and **ROSA Classic**. Both architectures run OVN-Kubernetes on the data plane, so the project template, `NetworkPolicy`, and `EgressFirewall` objects in this guide work on either cluster type.

## When to use this guide

Use this guide when you want a **baseline namespace isolation pattern** for multi-tenant ROSA clusters:

* Restrict pod-to-pod traffic across namespaces with `NetworkPolicy`
* Control which external destinations workloads can reach with `EgressFirewall`
* Automate those defaults for every new project through a [project request template](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/building_applications/projects#modifying-the-template-for-new-projects)

These OpenShift resources complement (they do not replace) AWS edge controls such as security groups, NAT gateways, and transit gateway inspection. Pair `EgressFirewall` with [Egress IP](/experts/rosa/egress-ip/) when external allowlists need predictable source IPs. For design rationale, see [Network isolation with NetworkPolicies and Egress Firewalls](/experts/rosa/best-practices-recommendations/#network-isolation-with-networkpolicies-and-egress-firewalls) in the ROSA best practices guide.

## NetworkPolicy vs EgressFirewall

The two resources operate at different layers. The project template in this guide uses both:

| Goal | Resource | What the template does |
|------|----------|------------------------|
| Block pod-to-pod traffic across namespaces | `NetworkPolicy` | Allows ingress only from the Ingress Controller namespace and from pods in the same namespace |
| Block or allow traffic leaving the cluster | `EgressFirewall` | Denies egress to all external destinations except cluster DNS (see below) |

`NetworkPolicy` in this guide controls **ingress** only. It does not deny egress. `EgressFirewall` controls **egress** to destinations outside the pod network.

### OVN-Kubernetes constraints

* Each namespace can have at most one `EgressFirewall` object.
* Rules are evaluated in order. Place `Allow` rules before catch-all `Deny` rules.
* The project template applies only to **new** projects. Existing namespaces (including `openshift-*` and `kube-*`) are unaffected until you apply policies manually.
* For platform-wide rules on supported versions, cluster administrators can also use [AdminNetworkPolicy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/admin-network-policy). That is a separate cluster-level layer on top of namespace-scoped `NetworkPolicy` objects.

## Prerequisites

* A ROSA cluster on OpenShift 4.20 or newer. This procedure is identical on HCP and Classic; only cluster provisioning differs:
  * **ROSA HCP**: Follow the [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/) guide
  * **ROSA Classic**: Follow the [Deploying a ROSA Classic cluster with Terraform](/experts/rosa/terraform/classic/) guide
* Cluster administrator access (`cluster-admin` or equivalent). Creating the project template, patching `project.config.openshift.io/cluster`, and creating `EgressFirewall` objects require cluster-admin privileges.
* OpenShift CLI (`oc`)

## Project template

The first step is to create a project template that contains `NetworkPolicy` and `EgressFirewall` objects with default deny rules.

1. Look up the cluster DNS service IP. Most ROSA clusters use `172.30.0.10`, but confirm on your cluster:

    ```bash
    export CLUSTER_DNS=$(oc get svc -n openshift-dns dns-default -o jsonpath='{.spec.clusterIP}')
    echo "Cluster DNS IP: ${CLUSTER_DNS}"
    ```

    A deny-all `EgressFirewall` without a DNS exception blocks name resolution for pods in affected namespaces.

1. Create and apply a project template with default deny rules

    > **NOTE** This template ensures that any new project has an egress policy that allows cluster DNS and denies all other external traffic, plus a network policy that only allows ingress from an Ingress Controller and from pods in the same namespace.


    ```bash
    cat <<EOF | oc apply -f -
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
          openshift.io/description: \${PROJECT_DESCRIPTION}
          openshift.io/display-name: \${PROJECT_DISPLAYNAME}
          openshift.io/requester: \${PROJECT_REQUESTING_USER}
        creationTimestamp: null
        name: \${PROJECT_NAME}
      spec: {}
      status: {}
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      metadata:
        creationTimestamp: null
        name: admin
        namespace: \${PROJECT_NAME}
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: admin
      subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: User
        name: \${PROJECT_ADMIN_USER}
    - apiVersion: k8s.ovn.org/v1
      kind: EgressFirewall
      metadata:
        name: default
      spec:
        egress:
          - to:
              cidrSelector: ${CLUSTER_DNS}/32
            type: Allow
          - to:
              cidrSelector: 0.0.0.0/0
            type: Deny
    - apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: deny-by-default
      spec:
        podSelector: {}
        policyTypes:
          - Ingress
        ingress:
          - from:
            - namespaceSelector:
                matchLabels:
                  policy-group.network.openshift.io/ingress: ""
          - from:
            - podSelector: {}
    EOF
    ```

    Do not set `metadata.namespace` on the `NetworkPolicy` or `EgressFirewall` objects. OpenShift assigns the new project namespace when it processes the template ([OCP 4.20 project template guidance](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/network-policy#nw-networkpolicy-project-defaults)).

    Confirm the template object exists before you continue:

    ```bash
    oc get template project-request -n openshift-config
    ```

    If this command returns `NotFound`, `oc new-project` fails later even after you patch the cluster project config. Re-run the `cat <<EOF | oc apply -f -` step and fix any apply errors first.

1. Patch the project configuration to use the newly created project template

    ```bash
    oc patch project.config.openshift.io/cluster --type=merge -p "
    apiVersion: config.openshift.io/v1
    kind: Project
    metadata:
      name: cluster
    spec:
      projectRequestTemplate:
        name: project-request
    "
    ```

1. Create a new project to verify the policies

    If you already created the demo project before the template was configured, delete it and **wait until the namespace is gone**. If the namespace still exists, `oc new-project egress-demo` prints `Already on project "egress-demo"` and **does not** run the template.

    ```bash
    export DEMO_PROJECT=egress-demo

    oc delete project "${DEMO_PROJECT}" --ignore-not-found --wait=true
    while oc get namespace "${DEMO_PROJECT}" >/dev/null 2>&1; do
      echo "Waiting for ${DEMO_PROJECT} to finish terminating..."
      sleep 3
    done

    oc new-project "${DEMO_PROJECT}"
    ```

1. Verify the policies were created

    ```bash
    oc get egressfirewall,networkpolicy -n "${DEMO_PROJECT}"
    oc get egressfirewall -n "${DEMO_PROJECT}" -o jsonpath='{.items[0].status.status}{"\n"}' 2>/dev/null || true
    oc describe egressfirewall default -n "${DEMO_PROJECT}" 2>/dev/null || true
    ```

    Expected results:

    * `egressfirewall.k8s.ovn.org/default` exists in the demo namespace
    * `networkpolicy.networking.k8s.io/deny-by-default` exists in the demo namespace
    * Egress firewall status is `EgressFirewall Rules applied` (check with `jsonpath` or `describe` if the table column is not shown)

    If either object is missing, use the manual apply step in the next subsection, then continue with the tests.

### If the template did not create policies

Some clusters (including certain ROSA HCP configurations) create the project and `admin` `RoleBinding` but skip `NetworkPolicy` or `EgressFirewall` objects from the template. Apply the policies directly:

```bash
export DEMO_PROJECT=egress-demo
export CLUSTER_DNS=$(oc get svc -n openshift-dns dns-default -o jsonpath='{.spec.clusterIP}')

oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata:
  name: default
  namespace: ${DEMO_PROJECT}
spec:
  egress:
    - to:
        cidrSelector: ${CLUSTER_DNS}/32
      type: Allow
    - to:
        cidrSelector: 0.0.0.0/0
      type: Deny
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-by-default
  namespace: ${DEMO_PROJECT}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            policy-group.network.openshift.io/ingress: ""
    - from:
      - podSelector: {}
EOF

oc get egressfirewall,networkpolicy -n "${DEMO_PROJECT}"
```

Use `DEMO_PROJECT=egress-demo-2` if you created a differently named project.

## Test the Network Policy

These tests use `oc exec` against long-running pods in the target namespace. That keeps traffic in the namespace you intend to test. Avoid `oc debug` for these checks: recent OpenShift CLI versions create short-lived debug pods with different output formatting.

1. Create test pods in the `default` and `egress-demo` namespaces

    ```bash
    oc run debug-default \
      --namespace=default \
      --image=registry.access.redhat.com/ubi9/ubi \
      --restart=Never \
      --command -- sleep 360000

    oc run debug-demo \
      --namespace=egress-demo \
      --image=registry.access.redhat.com/ubi9/ubi \
      --restart=Never \
      --command -- sleep 360000

    oc wait --for=condition=Ready pod/debug-default -n default --timeout=120s
    oc wait --for=condition=Ready pod/debug-demo -n egress-demo --timeout=120s
    ```

1. Deploy a sample application and expose it

    ```bash
    oc -n egress-demo create deployment hello --image=docker.io/openshift/hello-openshift --port=8080
    oc -n egress-demo expose deployment hello --port=8080
    oc -n egress-demo create route edge hello --service=hello --port=8080

    oc -n egress-demo rollout status deployment/hello --timeout=120s
    ROUTE=$(oc get route hello -n egress-demo -o jsonpath='{.spec.host}')
    echo "Route host: http://${ROUTE}"
    ```

1. Access the application via its Route from your workstation (should succeed)

    ```bash
    curl -s --max-time 10 "https://${ROUTE}"
    ```

    Expected: response body contains Hello OpenShift! 

1. Access the application via its Route from the `default` namespace (should succeed)

    Traffic enters through the Ingress Controller, which matches the allowed `NetworkPolicy` source.

    ```bash
    oc exec -n default debug-default -- curl -s --max-time 10 "https://${ROUTE}"
    ```

    Expected: response body contains Hello OpenShift! 

1. Access the application via its cluster service from within `egress-demo` (should succeed)

    ```bash
    oc exec -n egress-demo debug-demo -- curl -s --max-time 10 http://hello.egress-demo.svc.cluster.local:8080
    ```

    Expected: response body contains Hello OpenShift!

1. Access the application via its cluster service from `default` (should fail)

    ```bash
    oc exec -n default debug-default -- curl -s --max-time 10 http://hello.egress-demo.svc.cluster.local:8080
    echo "Exit code: $?"
    ```

    Expected: command times out or exits non-zero. No response body.

## Test the Egress Firewall

1. Verify external access from the `default` namespace (should succeed)

    ```bash
    oc exec -n default debug-default -- curl -sS --max-time 10 https://icanhazip.com
    ```

    Expected: command prints a public IP address.

1. Verify external access from the `egress-demo` namespace (should fail)

    ```bash
    oc exec -n egress-demo debug-demo -- curl -sS --max-time 10 https://icanhazip.com
    echo "Exit code: $?"
    ```

    Expected: command times out or exits non-zero. No public IP is returned.

## Allow specific egress destinations

Production namespaces rarely stay on deny-all egress. Update the `EgressFirewall` to allow specific FQDNs or CIDR blocks **before** the catch-all deny rule.

1. Patch the `egress-demo` namespace `EgressFirewall` to allow `icanhazip.com` and keep the DNS exception:

    ```bash
    oc apply -f - <<EOF
    apiVersion: k8s.ovn.org/v1
    kind: EgressFirewall
    metadata:
      name: default
      namespace: egress-demo
    spec:
      egress:
        - to:
            dnsName: icanhazip.com
          type: Allow
        - to:
            cidrSelector: ${CLUSTER_DNS}/32
          type: Allow
        - to:
            cidrSelector: 0.0.0.0/0
          type: Deny
    EOF
    ```

    If you opened a new shell, set `CLUSTER_DNS` again with the lookup command from the project template section.

1. Verify that the allowed external host is reachable from the `egress-demo` namespace

    ```bash
    oc exec -n egress-demo debug-demo -- curl -sS --max-time 10 https://icanhazip.com
    ```

    Expected: command prints a public IP address.

1. Verify that other external hosts remain blocked

    ```bash
    oc exec -n egress-demo debug-demo -- curl -sS --max-time 10 https://example.com
    echo "Exit code: $?"
    ```

    Expected: command times out or exits non-zero.

## Cleanup

Remove demo resources and, if this was a lab cluster, revert the project template configuration.

1. Delete test workloads and the demo project

    ```bash
    oc delete project egress-demo --wait=false
    oc delete pod debug-default -n default --ignore-not-found
    ```

1. Remove the custom project template

    ```bash
    oc delete template project-request -n openshift-config --ignore-not-found
    ```

1. Clear the project request template reference (restores OpenShift default project creation behavior)

    ```bash
    oc patch project.config.openshift.io/cluster --type=merge -p '
    {
      "spec": {
        "projectRequestTemplate": {
          "name": ""
        }
      }
    }'
    ```

    On some OpenShift versions you may need to remove the `projectRequestTemplate` key with a strategic merge or `oc edit project.config.openshift.io/cluster` instead. Confirm new project creation behaves as expected after cleanup.
