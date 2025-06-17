---
date: '2025-06-16'
title: Scalability and Cost Management for Azure Red Hat OpenShift
tags: ["ARO"]
authors:
  - Nerav Doshi
---

With Azure Red Hat OpenShift (ARO), you can take advantage of flexible pricing models, including pay-as-you-go and reserved instances, to further optimize your cloud spending. Its auto-scaling capabilities help reduce costs by avoiding over-provisioning, making it a cost-effective solution for organizations seeking to balance performance and expenditure

This guide demonstrates how to implement scheduled scaling in Azure Red Hat OpenShift (ARO), enabling your cluster to automatically adjust its size according to a predefined schedule. By configuring scale-downs during periods of low activity and scale-ups when additional resources are needed, you can ensure both cost efficiency and optimal performance.

Leveraging ARO's automated scaling capabilities allows for dynamic adjustment of worker node capacity, eliminating wasteful spending on idle infrastructure resources. This approach reduces the need for manual intervention and ensures consistent compute resources for both traditional workloads and AI/ML operations during peak hours.

## Prerequisites

The following three CLIs need to be installed.
* `oc` cli 
* Access to [Azure Red Hat OpenShift cluster](https://cloud.redhat.com/experts/quickstart-aro/)

> Note: You must log into your ARO cluster via your oc cli before going through the following steps.

## Step 1: Create a New project and Service Account

### Create a new project
```bash
oc new-project worker-scaling
```

### Create the service account

```bash
oc create serviceaccount worker-scaler -n worker-scaling
```

## Step 2: Create RBAC Resources

Create the necessary ClusterRole and ClusterRoleBinding to grant permissions:

```bash
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: worker-scaler
rules:
- apiGroups: ["machine.openshift.io"]
  resources: ["machinesets"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
EOF
```

```bash
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: worker-scaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: worker-scaler
subjects:
- kind: ServiceAccount
  name: worker-scaler
  namespace: worker-scaling
EOF
```

## Step 3: Create the Scaling Script

### Environment Variables
- `DESIRED_REPLICAS`: Number of replicas per machineset (default: 3)
- `MACHINESET_LABEL`: Label selector for machinesets (default: worker role)

Create a ConfigMap containing the scaling script:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: scaling-script
  namespace: worker-scaling
data:
  scale-workers.sh: |
    #!/bin/bash
    set -e

    # Configuration
    DESIRED_REPLICAS="${DESIRED_REPLICAS:-3}"
    MACHINESET_LABEL="machine.openshift.io/cluster-api-machine-role=worker"

    echo "Starting worker node scaling..."
    echo "Target replicas: $DESIRED_REPLICAS"

    # Get worker machinesets
    MACHINESETS=$(oc get machinesets -n openshift-machine-api \
      -l "$MACHINESET_LABEL" -o name)

    if [ -z "$MACHINESETS" ]; then
        echo "No machinesets found with label: $MACHINESET_LABEL"
        exit 1
    fi

    # Scale each machineset
    for MACHINESET in $MACHINESETS; do
        MACHINESET_NAME=$(echo $MACHINESET | cut -d'/' -f2)
        echo "Scaling $MACHINESET_NAME to $DESIRED_REPLICAS replicas"

        # Get current replicas
        CURRENT_REPLICAS=$(oc get $MACHINESET -n openshift-machine-api \
          -o jsonpath='{.spec.replicas}')
        echo "Current replicas for $MACHINESET_NAME: $CURRENT_REPLICAS"

        if [ "$CURRENT_REPLICAS" != "$DESIRED_REPLICAS" ]; then
            # Scale the machineset
            oc patch $MACHINESET -n openshift-machine-api \
              -p "{\"spec\":{\"replicas\":$DESIRED_REPLICAS}}" --type=merge
            echo "Scaled $MACHINESET_NAME from $CURRENT_REPLICAS to" \
                 "$DESIRED_REPLICAS replicas"
        else
            echo "$MACHINESET_NAME already has $DESIRED_REPLICAS replicas"
        fi
    done

    echo "Scaling operation completed"

    # Wait and report status
    echo "Waiting 30 seconds before checking status..."
    sleep 30

    echo "Current machineset status:"
    oc get machinesets -n openshift-machine-api -l "$MACHINESET_LABEL"

    echo "Current node count:"
    oc get nodes --no-headers | wc -l
EOF
```

## Step 4: Create the CronJob

#### For testing you can adjust accordingly. For example
- `"0 8 * * *"` - Daily at 8:00 AM
- `"0 8 * * 1-5"` - Weekdays at 8:00 AM
- `"0 8,20 * * *"` - Daily at 8:00 AM and 8:00 PM
- `"*/30 * * * *"` - Every 30 minutes

Create a CronJob that will execute the scaling script:

```bash
oc apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: worker-scaler
  namespace: worker-scaling
spec:
  # Schedule: Run every day at 8:00 AM (adjust as needed)
  schedule: "0 8 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: worker-scaler
          restartPolicy: OnFailure
          containers:
          - name: worker-scaler
            image: quay.io/openshift/origin-cli:latest
            command: ["/bin/bash"]
            args: ["/scripts/scale-workers.sh"]
            env:
            # Set desired number of replicas per machineset
            - name: DESIRED_REPLICAS
              value: "3"
            # Optional: Specify machineset label selector
            - name: MACHINESET_LABEL
              value: "machine.openshift.io/cluster-api-machine-role=worker"
            volumeMounts:
            - name: scaling-script
              mountPath: /scripts
            resources:
              requests:
                memory: "64Mi"
                cpu: "50m"
              limits:
                memory: "128Mi"
                cpu: "100m"
          volumes:
          - name: scaling-script
            configMap:
              name: scaling-script
              defaultMode: 0755
  # Keep last 3 successful jobs and 1 failed job
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
EOF
```

## Step 5: Verify the Setup

Check that all resources are created correctly:

#### Verify service account
```bash
oc get serviceaccount worker-scaler -n worker-scaling
```

Example output:

```bash
aro-cluster$ oc get serviceaccount worker-scaler -n worker-scaling
NAME            SECRETS   AGE
worker-scaler   1         101m
```

#### Verify RBAC
```bash
oc get clusterrole worker-scaler
oc get clusterrolebinding worker-scaler
```
Example output:

```bash
aro-cluster$ oc get clusterrole worker-scaler
NAME            CREATED AT
worker-scaler   2025-06-16T18:35:12Z
aro-cluster$ oc get clusterrolebinding worker-scaler
NAME            ROLE                        AGE
worker-scaler   ClusterRole/worker-scaler   106m
```
#### Verify ConfigMap
```bash
oc get configmap scaling-script -n worker-scaling
```

Example output:

```bash
aro-cluster$ oc get configmap scaling-script -n worker-scaling
NAME             DATA   AGE
scaling-script   1      107m
```
#### Verify CronJob
```bash
oc get cronjob worker-scaler -n worker-scaling
```
Example output:
```bash
aro-cluster$ oc get cronjob worker-scaler -n worker-scaling
NAME            SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
worker-scaler   0 8 * * *   False     0        <none>          6s
```
## Step 6: Test the CronJob

You can manually trigger the CronJob to test it:
#### Create a manual job from the CronJob
```bash
oc create job --from=cronjob/worker-scaler manual-test-1 -n worker-scaling
```

#### Check the job status
```bash
oc get jobs -n worker-scaling
```
#### Check the pod logs
```
oc logs -f job/manual-test-1 -n worker-scaling
```
Example output:

```bash
aro-cluster$ oc get jobs -n worker-scaling
NAME            COMPLETIONS   DURATION   AGE
manual-test-1   0/1           17s        17s
```
## Step 7: Monitor and Manage
Monitor the CronJob execution:

#### Check CronJob status
```bash
oc get cronjob worker-scaler -n worker-scaling
```
Example output:
```bash
aro-cluster$ oc get cronjob worker-scaler -n worker-scaling
NAME            SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
worker-scaler   0 8 * * *   False     0        <none>          3m15s
```

#### View recent jobs
```bash
oc get jobs -n worker-scaling
```

Example output:
```bash
aro-cluster$ oc get jobs -n worker-scaling
NAME            COMPLETIONS   DURATION   AGE
manual-test-1   1/1           55s        2m51s
```


## Creating a Scale-Down CronJob

To create a complementary scale-down job:

```bash
oc apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: worker-scaler-down
  namespace: worker-scaling
spec:
  # Schedule: Run every day at 6:00 PM
  schedule: "0 18 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: worker-scaler
          restartPolicy: OnFailure
          containers:
          - name: worker-scaler
            image: quay.io/openshift/origin-cli:latest
            command: ["/bin/bash"]
            args: ["/scripts/scale-workers.sh"]
            env:
            - name: DESIRED_REPLICAS
              value: "1"  # Scale down to 1 replica
            volumeMounts:
            - name: scaling-script
              mountPath: /scripts
          volumes:
          - name: scaling-script
            configMap:
              name: scaling-script
              defaultMode: 0755
EOF
```
### Finally sit back and watch the machinesets scale on the schedule you configured.  

#### Check machinesets
```bash
oc get machinesets -n openshift-machine-api
```
#### Check machines
```bash
oc get machines -n openshift-machine-api
```

#### Check nodes
```bash
oc get nodes
```
