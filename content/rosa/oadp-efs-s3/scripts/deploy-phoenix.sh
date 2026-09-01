#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-phoenix.sh

Deploys the Phoenix Mission Control validation workload to the primary cluster.
The current oc context must already be logged in to PRIMARY_CLUSTER_NAME.
EOF
}


while [ $# -gt 0 ]; do
  case "$1" in
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done


: "${PRIMARY_CLUSTER_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${APP_BUCKET_PRIMARY:?}"
: "${APP_S3_ROLE_ARN_PRIMARY:?}"
: "${PRIMARY_EFS:?}"

NAMESPACE="dr-demo"

CURRENT_API=$(oc whoami --show-server)
EXPECTED_API=$(rosa describe cluster -c "$PRIMARY_CLUSTER_NAME" -o json | jq -r '.api.url')

if [ "$CURRENT_API" != "$EXPECTED_API" ]; then
  echo "Current oc context is $CURRENT_API" >&2
  echo "Expected primary cluster API is $EXPECTED_API" >&2
  echo "Log in to the primary cluster before running this script." >&2
  exit 1
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${APP_S3_ROLE_ARN_PRIMARY}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-writer
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${APP_S3_ROLE_ARN_PRIMARY}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-flight-data
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mission-control
  template:
    metadata:
      labels:
        app: mission-control
    spec:
      serviceAccountName: dashboard
      containers:
        - name: mission-control
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                printf 'Phoenix Mission Control running on %s\n' "\${CLUSTER_NAME}" > /tmp/health
                sleep 300
              done
          env:
            - name: S3_BUCKET
              value: "${APP_BUCKET_PRIMARY}"
            - name: AWS_REGION
              value: "${PRIMARY_REGION}"
            - name: CLUSTER_NAME
              value: "${PRIMARY_CLUSTER_NAME}"
            - name: AWS_ROLE_ARN
              value: "${APP_S3_ROLE_ARN_PRIMARY}"
            - name: PRIMARY_EFS
              value: "${PRIMARY_EFS}"
          volumeMounts:
            - name: shared-flight-data
              mountPath: /shared
      volumes:
        - name: shared-flight-data
          persistentVolumeClaim:
            claimName: shared-flight-data
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telemetry-transmitter
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: telemetry-transmitter
  template:
    metadata:
      labels:
        app: telemetry-transmitter
    spec:
      serviceAccountName: s3-writer
      containers:
        - name: telemetry-transmitter
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                date -u +"telemetry heartbeat %Y-%m-%dT%H:%M:%SZ" > /tmp/telemetry
                sleep 300
              done
          env:
            - name: S3_BUCKET
              value: "${APP_BUCKET_PRIMARY}"
            - name: AWS_REGION
              value: "${PRIMARY_REGION}"
            - name: CLUSTER_NAME
              value: "${PRIMARY_CLUSTER_NAME}"
            - name: AWS_ROLE_ARN
              value: "${APP_S3_ROLE_ARN_PRIMARY}"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: flight-recorder
  namespace: ${NAMESPACE}
spec:
  serviceName: flight-recorder
  replicas: 2
  selector:
    matchLabels:
      app: flight-recorder
  template:
    metadata:
      labels:
        app: flight-recorder
    spec:
      containers:
        - name: flight-recorder
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                echo "\${HOSTNAME}" > /flight-data/ordinal.txt
                sleep 300
              done
          volumeMounts:
            - name: flight-data
              mountPath: /flight-data
  volumeClaimTemplates:
    - metadata:
        name: flight-data
      spec:
        accessModes:
          - ReadWriteMany
        storageClassName: efs-sc
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mission-control
  namespace: ${NAMESPACE}
spec:
  selector:
    app: mission-control
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: flight-recorder
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector:
    app: flight-recorder
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mission-control
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: mission-control
  port:
    targetPort: http
EOF

oc rollout status deployment/mission-control -n "$NAMESPACE" --timeout=600s
oc rollout status deployment/telemetry-transmitter -n "$NAMESPACE" --timeout=600s
oc rollout status statefulset/flight-recorder -n "$NAMESPACE" --timeout=600s

oc wait pvc/shared-flight-data -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s
oc wait pvc/flight-data-flight-recorder-0 -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s
oc wait pvc/flight-data-flight-recorder-1 -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s

oc get serviceaccount,deploy,sts,svc,route,pvc -n "$NAMESPACE"

echo "Phoenix Mission Control deployed to $NAMESPACE on $PRIMARY_CLUSTER_NAME."
