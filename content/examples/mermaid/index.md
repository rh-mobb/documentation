---
date: 2026-05-29
title: Mermaid diagram examples
draft: true
authors:
  - Paul Czarkowski
---

Reference page for Mermaid diagram usage on this site. Add the diagram source inside a `mermaid` shortcode pair.

## Flowchart: ROSA cluster creation flow

{{< mermaid >}}
flowchart TD
    A([Start]) --> B[Choose cluster type\nClassic or HCP]
    B --> C{HCP?}
    C -- Yes --> D[Create VPC &\nsubnets]
    C -- No --> E[Select existing VPC\nor let ROSA create]
    D --> F[rosa create cluster\n--hosted-cp]
    E --> G[rosa create cluster]
    F --> H[Wait for install\n~15 min]
    G --> I[Wait for install\n~45 min]
    H --> J[Cluster ready]
    I --> J
    J --> K[Create admin user\nor configure IDP]
    K --> L([Done])
{{< /mermaid >}}

## Sequence diagram: OIDC authentication flow

{{< mermaid >}}
sequenceDiagram
    autonumber
    actor User
    participant OC as oc / kubectl
    participant IDP as Identity Provider
    participant API as OpenShift API Server
    participant OIDC as OIDC Endpoint

    User->>OC: oc login --web
    OC->>API: Request OAuth token
    API-->>OC: Redirect to IDP login
    OC->>User: Open browser
    User->>IDP: Enter credentials
    IDP-->>User: MFA challenge (if configured)
    User->>IDP: Submit MFA
    IDP-->>API: OIDC token (id_token)
    API->>OIDC: Validate token signature
    OIDC-->>API: Valid
    API-->>OC: OpenShift session token
    OC-->>User: Logged in as [username]
{{< /mermaid >}}

## Architecture diagram: ROSA HCP cluster topology

{{< mermaid >}}
graph TB
    subgraph AWS["AWS — Customer account"]
        subgraph VPC["Customer VPC"]
            subgraph WN["Worker nodes (EC2)"]
                P1[Pod] & P2[Pod] & P3[Pod]
            end
            LB[AWS Load Balancer]
            PrivLink[PrivateLink endpoint]
        end
    end

    subgraph RH["AWS — Red Hat service account"]
        subgraph CP["Hosted Control Plane"]
            API[API Server]
            ETCD[(etcd)]
            CTRL[Controller Manager]
        end
    end

    Internet((Internet)) -->|HTTPS| LB
    LB --> WN
    WN <-->|PrivateLink| PrivLink
    PrivLink <--> CP
    API <--> ETCD
    CTRL <--> API
{{< /mermaid >}}

## State diagram: Kubernetes Pod lifecycle

{{< mermaid >}}
stateDiagram-v2
    [*] --> Pending : Pod scheduled

    Pending --> Init : Init containers start
    Init --> Running : All init containers complete

    Pending --> Running : No init containers

    Running --> Succeeded : All containers exit 0
    Running --> Failed : Container exits non-zero\n(restartPolicy: Never)
    Running --> Running : Container restarts\n(restartPolicy: Always/OnFailure)

    Running --> Terminating : Deletion requested
    Terminating --> [*] : terminationGracePeriod elapsed

    Succeeded --> [*]
    Failed --> [*]

    note right of Pending
        OOMKilled or ImagePullBackOff
        keeps pod in this state
    end note
{{< /mermaid >}}

## Pie chart: Cluster resource allocation example

{{< mermaid >}}
pie title Cluster vCPU allocation
    "Application workloads" : 48
    "Platform / infra" : 12
    "Monitoring stack" : 8
    "Reserved (headroom)" : 8
    "Unallocated" : 24
{{< /mermaid >}}

## Gantt chart: ROSA upgrade timeline

{{< mermaid >}}
gantt
    title ROSA cluster upgrade plan
    dateFormat  YYYY-MM-DD
    section Prep
    Review release notes          :done,    prep1, 2026-06-01, 2d
    Test in non-prod cluster      :active,  prep2, 2026-06-03, 5d
    section Maintenance window
    Notify stakeholders           :         maint1, 2026-06-08, 1d
    Control plane upgrade         :crit,    maint2, 2026-06-10, 1d
    Worker node rolling upgrade   :crit,    maint3, 2026-06-10, 2d
    section Validation
    Smoke-test workloads          :         val1, 2026-06-12, 1d
    Monitor for 48 h              :         val2, 2026-06-12, 2d
    Close change record           :         val3, 2026-06-14, 1d
{{< /mermaid >}}

## Git graph: Feature branch workflow

{{< mermaid >}}
gitGraph
    commit id: "Initial commit"
    commit id: "Add base config"

    branch feature/add-idp
    checkout feature/add-idp
    commit id: "Add LDAP IDP config"
    commit id: "Add group sync CronJob"

    checkout main
    branch feature/network-policy
    checkout feature/network-policy
    commit id: "Add default deny policy"
    commit id: "Allow monitoring namespace"

    checkout main
    merge feature/add-idp id: "Merge IDP feature"
    merge feature/network-policy id: "Merge network policies"
    commit id: "Release v1.1"
{{< /mermaid >}}
