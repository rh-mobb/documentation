---
date: '2026-07-29'
title: Deploy Pega Platform on Red Hat OpenShift Service on AWS (ROSA)
tags: ["ROSA", "Pega"]
authors:
  - Andres Romero
---

Deploying Pega Platform on a managed OpenShift environment like Red Hat OpenShift Service on AWS (ROSA) lets you take advantage of the platform's enterprise capabilities while benefiting from a fully managed Kubernetes service. However, the deployment process involves coordinating several components: container images, databases, search services, message streaming, and Helm charts.

This guide walks you through deploying Pega Platform on ROSA step by step, covering everything from preparing your container images to accessing the Pega web interface. The accompanying [Git repository](https://github.com/roller1187/pega-rosa) contains all the configuration files you need to get started.

> This deployment was tested on ROSA GovCloud 4.18, using a bastion host running RHEL 8.6.

## Prerequisites

* OpenShift CLI (`oc`)
* [Helm](https://github.com/pegasystems/pega-helm-charts/blob/master/docs/prepping-local-system-runbook-linux.md#installing-helm)
* Podman
* A running ROSA cluster
* Three Pega container images (obtained from [Pega](https://github.com/pegasystems/pega-helm-charts/blob/master/docs/prepping-local-system-runbook-linux.md#downloading-a-pega-platform-installer-docker-image)):
  * `pega-docker.downloads.pega.com/platform/installer`
  * `pega-docker.downloads.pega.com/platform/pega`
  * `pega-docker.downloads.pega.com/platform-services/search-n-reporting-service-os`

## Create a Namespace and Configure the Internal Registry

Create a dedicated namespace for the Pega deployment and expose the OpenShift internal registry so you can push your container images.

```bash
oc new-project pega
```

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --patch '{"spec":{"defaultRoute":true}}' --type=merge

export REGISTRY=$(oc get route default-route -n openshift-image-registry \
  --template='{{ .spec.host }}')

podman login -u $(oc whoami) -p $(oc whoami --show-token) ${REGISTRY}
```

## Load and Push Container Images

Load the Pega images from their tar archives, tag them for the internal registry, and push them.

```bash
podman load -i pega_23_1_1.tar
podman load -i pega_srs.tar
podman load -i pega_23_install.tar
```

```bash
podman tag quay.io/aromero/pega/pega:23.1.1 \
  ${REGISTRY}/pega/pega:23.1.1
podman tag quay.io/aromero/pega/search-n-reporting-service-os:1.35.0 \
  ${REGISTRY}/pega/search-n-reporting-service-os:1.35.0
podman tag quay.io/aromero/pega/installer:23.1.1 \
  ${REGISTRY}/pega/installer:23.1.1
```

```bash
podman push ${REGISTRY}/pega/pega:23.1.1
podman push ${REGISTRY}/pega/search-n-reporting-service-os:1.35.0
podman push ${REGISTRY}/pega/installer:23.1.1
```

## Create a Machine Pool for the Installer

The Pega installer pods require significant resources. Create a machine pool with a larger instance type to accommodate them.

```bash
rosa cluster list
```

```bash
rosa create machinepool --cluster=${CLUSTER_NAME} \
  --name=big --replicas=1 --instance-type=m6a.4xlarge
```

## Deploy OpenSearch

Pega uses OpenSearch for its Search and Reporting Service. Deploy it using Helm with the required configuration.

### Clone the Git Repository

```bash
git clone https://github.com/roller1187/pega-rosa
cd pega-rosa
```

### Install OpenSearch

```bash
oc adm policy add-scc-to-user privileged -z default
```

```bash
oc apply -f opensearch.yaml
```

```bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm install opensearch opensearch/opensearch \
  --version 2.17.0 --namespace pega
```

Scale down the StatefulSet to apply environment variable changes, then scale it back up.

```bash
oc scale statefulset opensearch-cluster-master --replicas=0
```

```bash
oc set env statefulset/opensearch-cluster-master \
  OPENSEARCH_INITIAL_ADMIN_PASSWORD=Openshift123!
oc set env statefulset/opensearch-cluster-master \
  plugins.security.disabled=true
oc set env statefulset/opensearch-cluster-master \
  plugins.security.ssl.http.enabled=false
```

```bash
oc scale statefulset opensearch-cluster-master --replicas=3
```

## Deploy PostgreSQL

Deploy PostgreSQL 12 as the backing database for Pega.

```bash
oc apply -f postgres-12.yaml
oc scale deployment/postgresql-12 --replicas=1
```

## Deploy Kafka

Install the Streams for Apache Kafka operator using the [Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.8/html/getting_started_with_streams_for_apache_kafka_on_openshift/proc-deploying-cluster-operator-hub-str#proc-deploying-cluster-operator-hub-str), then deploy a Kafka cluster.

> The Kafka cluster must be named `pega-kafka-cluster` as this name is referenced in the Pega Helm chart configuration.

## Deploy Pega Backing Services

Add the Pega Helm repository and configure the backing services.

```bash
helm repo add pega https://pegasystems.github.io/pega-helm-charts
```

Update the `backingservices.yaml` file in the cloned repository with the following values. Refer to the [Pega documentation](https://github.com/pegasystems/pega-helm-charts/blob/master/docs/Deploying-Pega-on-openshift.md#updating-the-backingservicesyaml-helm-chart-values-for-the-srs-supported-when-installing-or-upgrading-to-pega-infinity-86-and-later) for details.

```yaml
k8sProvider: openshift
srs.srsRuntime.srsImage: <internal registry SRS image path>
srs.srsStorage.provisionInternalESCluster: false
srs.srsStorage.domain: <OpenSearch service address>
srs.srsStorage.port: <OpenSearch service port>
srs.srsStorage.protocol: http
srs.srsStorage.tls.enabled: false
srs.srsStorage.authCredentials.username: admin
srs.srsStorage.authCredentials.password: Openshift123!
```

Deploy the backing services.

```bash
helm install backingservices pega/backingservices \
  --namespace pega --values backingservices.yaml --version 3.21.6
```

> The default NetworkPolicy in the backing services Helm template uses a podSelector that must be patched to work with OpenSearch.

```bash
oc patch networkpolicy/pega-search-networkpolicy --type=json \
  -p '[{"op": "add", "path": "/spec/egress/0/to/0/podSelector/matchLabels", "value": {app.kubernetes.io/name: "opensearch"}}]'
```

## Deploy Pega Platform

Update the `pega.yaml` file in the cloned repository with the following values. Refer to the [Pega documentation](https://github.com/pegasystems/pega-helm-charts/blob/master/docs/Deploying-Pega-on-openshift.md#updating-the-pegayaml-helm-chart-values) for details.

```yaml
provider: openshift
jdbc.url: jdbc:postgresql://postgresql-12.pega.svc.cluster.local:5432/postgres
jdbc.driverClass: org.postgresql.Driver
jdbc.dbType: postgres
jdbc.driverUri: https://jdbc.postgresql.org/download/postgresql-42.7.5.jar
jdbc.username: postgres
jdbc.password: postgres
jdbc.rulesSchema: rules
jdbc.dataSchema: data
docker.pega.image: <internal registry Pega image path>
tier.ingress.domain: <app_name>-<namespace>.apps.<FQDN>
cassandra.enabled: false
cassandra.persistence.enabled: false
pegasearch.externalSearchService: true
pegasearch.externalURL: http://opensearch-cluster-master.pega.svc.cluster.local:9200
installer.image: <internal registry installer image path>
installer.upgrade.pegaRESTUsername: pega
installer.upgrade.pegaRESTPassword: pega
hazelcast.enabled: false
stream.bootstrapServer: pega-kafka-cluster-kafka-bootstrap.pega.svc.cluster.local:9092
```

Run the Helm chart to create the database schema and deploy Pega.

```bash
helm install pega pega/pega \
  --namespace pega --values pega.yaml
```

> The database install process takes approximately 20 minutes to complete, followed by the Pega web deployment.

For subsequent installs where the database schema already exists, use the same command — the installer will detect the existing schema and skip creation.

## Access the Pega Web Interface

Once the Pega web pod is running, access the application using the route specified in `tier.ingress.domain` in your `pega.yaml` configuration.

Log in with the default credentials:

* **Username:** `administrator@pega.com`
* **Password:** `ADMIN_PASSWORD`

> You will be prompted to change your password on first login.
