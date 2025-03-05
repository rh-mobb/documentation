---
date: '2025-02-28'
title: Setting up Cross-Cluster PostgreSQL Replication with Skupper on ROSA and ARO
tags: ["OpenShift", "ROSA", "ARO", "PostgreSQL", "Replication", "Skupper", "Service Interconnect"]
aliases: ["/docs/misc/rosa-aro-service-interconnect"]
authors:
  - Florian Jacquin
---

# Setting up Cross-Cluster PostgreSQL Replication with Skupper on ROSA and ARO

This guide demonstrates how to set up a highly available PostgreSQL database with cross-cluster replication between Red Hat OpenShift Service on AWS (ROSA) and Azure Red Hat OpenShift (ARO) using Skupper. This architecture enables disaster recovery capabilities and geographical distribution of your database workloads.

> **Note**: You can create a ROSA cluster using the [ROSA with STS deployment guide](https://cloud.redhat.com/experts/rosa/sts/) or an ARO cluster with the [ARO quickstart guide](https://cloud.redhat.com/experts/quickstart-aro/). While this tutorial focuses on ROSA and ARO, the same principles can be applied to any two OpenShift clusters, regardless of their hosting environment.

## Prerequisites

* Access to both ROSA and ARO clusters
* OC CLI installed
* Admin access to both clusters

## Architecture Overview

In this setup:
- The primary PostgreSQL instance will run on ROSA
- The replica PostgreSQL instance will run on ARO
- Skupper will provide secure cross-cluster communication
- The PostgreSQL instances will be configured for asynchronous replication

```
┌─────────────────────────────────────┐                 ┌─────────────────────────────────────┐
│                                     │                 │                                     │
│            AWS Cloud                │                 │           Azure Cloud               │
│                                     │                 │                                     │
│  ┌─────────────────────────────┐    │                 │    ┌─────────────────────────────┐  │
│  │                             │    │                 │    │                             │  │
│  │  ROSA Cluster               │    │                 │    │  ARO Cluster                │  │
│  │  ┌───────────────────────┐  │    │                 │    │  ┌───────────────────────┐  │  │
│  │  │                       │  │    │                 │    │  │                       │  │  │
│  │  │  Namespace: primary-db│  │    │                 │    │  │  Namespace: replica-db│  │  │
│  │  │  ┌─────────────────┐  │  │    │    Skupper      │    │  │  ┌─────────────────┐  │  │  │
│  │  │  │ PostgreSQL      │  │  │    │    Secure       │    │  │  │ PostgreSQL      │  │  │  │
│  │  │  │ Primary         │  │  │    │    Virtual      │    │  │  │ Replica         │  │  │  │
│  │  │  │                 │<─┼──┼────┼─────Network─────┼────┼──┼─>│                 │  │  │  │
│  │  │  │                 │  │  │    │                 │    │  │  │                 │  │  │  │
│  │  │  └─────────────────┘  │  │    │                 │    │  │  └─────────────────┘  │  │  │
│  │  │                       │  │    │                 │    │  │                       │  │  │
│  │  └───────────────────────┘  │    │                 │    │  └───────────────────────┘  │  │
│  │                             │    │                 │    │                             │  │
│  └─────────────────────────────┘    │                 │    └─────────────────────────────┘  │
│                                     │                 │                                     │
└─────────────────────────────────────┘                 └─────────────────────────────────────┘

             Write Operations                                     Read-Only Replica
              Transactions                                      Asynchronous Replication
```

## Set up Cluster Contexts

First, let's set up and organize our cluster contexts for easier management:

```bash
# Login to ROSA cluster
oc login --token=<rosa_token> --server=<rosa_url>
oc new-project primary-db
oc config set-context --current --namespace=primary-db
oc config rename-context $(oc config current-context) rosa

# Login to ARO cluster
oc login --token=<aro_token> --server=<aro_url>
oc new-project replica-db
oc config set-context --current --namespace=replica-db
oc config rename-context $(oc config current-context) aro
```

This creates separate namespaces for our primary and replica databases and renames the contexts for easier switching between clusters.

## Deploy Service Interconnect Operator

The Service Interconnect Operator (based on Skupper) enables secure communication between clusters. Deploy it on both clusters:

```bash
# Install on ROSA
oc apply -k https://github.com/fjcloud/gitops-catalog/service-interconnect-operator/operator/overlays/stable --context rosa

# Install on ARO
oc apply -k https://github.com/fjcloud/gitops-catalog/service-interconnect-operator/operator/overlays/stable --context aro
```

## Install and Configure Skupper

Skupper provides the application interconnect between clusters. Install the Skupper CLI and initialize it on both clusters:

```bash
# Install Skupper CLI
curl https://skupper.io/install.sh | sh

# Initialize Skupper on ROSA
skupper init --context rosa

# Initialize Skupper on ARO
skupper init --context aro

# Create a token on ROSA to authorize the connection
skupper token create primary.token --context rosa

# Use the token to link ARO to ROSA
skupper link create primary.token --context aro
```

This creates a secure Virtual Application Network (VAN) between the two clusters.

## Deploy Primary PostgreSQL on ROSA

Now we'll deploy the primary PostgreSQL instance on the ROSA cluster:

```bash
oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-primary \
  -e POSTGRESQL_USER=myuser \
  -e POSTGRESQL_PASSWORD=mypassword \
  -e POSTGRESQL_DATABASE=mydatabase \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e POSTGRESQL_ADMIN_PASSWORD=adminpassword \
  -e IS_PRIMARY=true --context rosa

# Add persistent storage
oc set volume deployment/postgres-primary --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data --context rosa

# Expose PostgreSQL via Skupper
skupper expose deployment/postgres-primary --port 5432 --context rosa
```

This deploys PostgreSQL 16 from the RHEL9 image with our custom replication configuration, adds persistent storage, and exposes it to the Skupper network.

```bash
# Wait for primary to be ready
oc wait --for=condition=available deployment/postgres-primary --timeout=120s --context rosa
```

## Deploy Replica PostgreSQL on ARO

Next, deploy the replica PostgreSQL instance on ARO:

```bash
oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-replica \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e POSTGRESQL_PRIMARY_HOST=postgres-primary \
  -e IS_PRIMARY=false \
  -e POSTGRESQL_MIGRATION_REMOTE_HOST=postgres-primary \
  -e POSTGRESQL_MIGRATION_ADMIN_PASSWORD=adminpassword \
  -e POSTGRESQL_MIGRATION_IGNORE_ERRORS=yes --context aro

# Add persistent storage
oc set volume deployment/postgres-replica --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data --context aro
```

This deploys the replica PostgreSQL instance on ARO, configured to replicate from the primary instance on ROSA.

```bash
# Wait for replica to be ready
oc wait --for=condition=available deployment/postgres-replica --timeout=120s --context aro
```

## Verify Replication

After setting up both PostgreSQL instances, we'll perform a comprehensive test of our replication configuration:

Let's perform a more comprehensive test of our replication setup by creating a test table, generating sample data, and verifying it's properly replicated:

```bash
# Create test table and function on primary
oc rsh --context rosa deployment/postgres-primary psql -d mydatabase -c "
-- Create table if not exists
CREATE TABLE IF NOT EXISTS sample_table (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
-- Create function to generate sample data
CREATE OR REPLACE FUNCTION add_sample_data(num_rows integer DEFAULT 1000)
RETURNS void AS \$\$
BEGIN
    INSERT INTO sample_table (data)
    SELECT 
        md5(random()::text)
    FROM generate_series(1, num_rows);
END;
\$\$ LANGUAGE plpgsql;"

# Generate initial test data (1000 rows)
oc rsh --context rosa deployment/postgres-primary psql -d mydatabase -c "SELECT add_sample_data();"

# Verify data on primary
oc rsh --context rosa deployment/postgres-primary psql -d mydatabase -c "SELECT count(*) FROM sample_table;"

# Verify data on replica
oc rsh --context aro deployment/postgres-replica psql -d mydatabase -c "SELECT count(*) FROM sample_table;"

# Add more data on primary (500 additional rows)
oc rsh --context rosa deployment/postgres-primary psql -d mydatabase -c "SELECT add_sample_data(500);"

# Check counts on both servers
echo "Primary count:"
oc rsh --context rosa deployment/postgres-primary psql -d mydatabase -c "SELECT count(*) FROM sample_table;"
echo "Replica count:"
oc rsh --context aro deployment/postgres-replica psql -d mydatabase -c "SELECT count(*) FROM sample_table;"
```

This comprehensive testing approach:
1. Creates a sample table and a function to generate test data
2. Generates an initial batch of 1000 rows
3. Verifies the count on both primary and replica
4. Adds 500 more rows to test ongoing replication
5. Checks for replication lag to ensure both instances are in sync

## Why This Architecture Matters

This cross-cluster PostgreSQL replication architecture provides several important benefits:

1. **Disaster Recovery**: If one cloud provider experiences an outage, your database remains available on the other cloud.

2. **Geographic Distribution**: Reduces latency for users by having database replicas closer to their physical location.

3. **Cloud Provider Independence**: Avoids vendor lock-in by spanning multiple cloud providers.

4. **High Availability**: Ensures database availability even during maintenance or unexpected failures.

5. **Advanced Networking**: Skupper provides secure, application-level connectivity between clusters without requiring VPN or complex network configurations.

6. **Simplified Operations**: The configuration automates much of the complexity of setting up PostgreSQL replication.

## Cleaning Up

When you're done with your deployment, follow these steps to clean up all resources:

```bash
# Delete PostgreSQL deployments
oc delete all -l app=postgres-primary --context rosa
oc delete all -l app=postgres-replica --context aro

# Remove Skupper interconnect
skupper delete --context rosa
skupper delete --context aro

# Delete projects/namespaces
oc delete project primary-db --context rosa
oc delete project replica-db --context aro

# Optional: Remove local configuration
rm primary.token
```

## Conclusion

In this guide, we've successfully implemented a cross-cluster PostgreSQL replication setup using Skupper to bridge between ROSA and ARO environments. This hybrid cloud architecture provides several significant advantages over traditional single-cluster deployments:

- **Enhanced Resilience**: By spanning multiple cloud providers, your database system can withstand regional outages or cloud-specific incidents.
- **Optimized Performance**: Geographical distribution of database instances reduces latency for globally distributed applications.
- **Operational Flexibility**: The ability to maintain service during maintenance windows by redirecting traffic between clusters.
- **Robust Disaster Recovery**: A ready-to-use standby database in a completely separate environment.

The combination of managed OpenShift services (ROSA and ARO) with Skupper's advanced application networking capabilities creates a powerful platform for mission-critical database workloads. This architecture can be further enhanced with monitoring tools, automated failover procedures, and integration with your application deployment pipeline.

By following the steps in this guide, you've laid the groundwork for a highly available, geographically distributed database architecture that can grow with your application needs while maintaining resilience against various failure scenarios.
