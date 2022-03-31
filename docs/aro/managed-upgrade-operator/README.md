# Enable the Managed Upgrade Operator and schedule Upgrades

**Paul Czarkowski**

*03/13/2022*

> This document is a work in progress and should be relied on even less than the usual mobb.ninja disclaimer.

## Prerequisites

  * an Azure Red Hat OpenShift cluster

## Get Started

1. Run this oc command to enable the MUO operator

   ```
   oc patch cluster.aro.openshift.io cluster --patch \
    '{"spec":{"operatorflags":{"rh.srep.muo.enabled": "true","rh.srep.muo.managed": "true","rh.srep.muo.deploy.pullspec":"arosvc.azurecr.io/managed-upgrade-operator@sha256:f57615aa690580a12c1e5031ad7ea674ce249c3d0f54e6dc4d070e42a9c9a274"}}}' \
    --type=merge
   ```

1. Wait a few moments to ensure the Management Upgrade Operator is ready

   ```bash
   oc -n openshift-managed-upgrade-operator \
     get deployment managed-upgrade-operator
   ```

   ```
   NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
   managed-upgrade-operator   1/1     1            1           2m2s
   ```

1. Configure the Managed Upgrade Operator

   ```
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: managed-upgrade-operator-config
     namespace:  openshift-managed-upgrade-operator
   data:
     config.yaml: |
       configManager:
         source: LOCAL
         localConfigName: managed-upgrade-config
         watchInterval: 1
       maintenance:
         controlPlaneTime: 90
         ignoredAlerts:
           controlPlaneCriticals:
           - ClusterOperatorDown
           - ClusterOperatorDegraded
       upgradeWindow:
         delayTrigger: 30
         timeOut: 120
       nodeDrain:
         timeOut: 45
         expectedNodeDrainTime: 8
       scale:
         timeOut: 30
       healthCheck:
         ignoredCriticals:
         - PrometheusRuleFailures
         - CannotRetrieveUpdates
         - FluentdNodeDown
         ignoredNamespaces:
         - openshift-logging
         - openshift-redhat-marketplace
         - openshift-operators
         - openshift-user-workload-monitoring
         - openshift-pipelines
   EOF
   ```

1. Restart the Managed Upgrade Operator

   ```
   oc -n openshift-managed-upgrade-operator \
     scale deployment managed-upgrade-operator --replicas=0
   oc -n openshift-managed-upgrade-operator \
     scale deployment managed-upgrade-operator --replicas=1
   ```

1. Look for available Upgrades

   > If there output is `nil` there are no available upgrades and you cannot continue.

   ```bash
   oc get clusterversion version -o jsonpath='{.status.availableUpdates}'
   ```

1. Schedule an Upgrade

    > Set the Channel and Version to the desired values from the above list of available upgrades.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: upgrade.managed.openshift.io/v1alpha1
   kind: UpgradeConfig
   metadata:
     name: managed-upgrade-config
     namespace: openshift-managed-upgrade-operator
   spec:
     type: "ARO"
     upgradeAt: $(date -u --iso-8601=seconds --date "+5 minutes")
     PDBForceDrainTimeout: 60
     capacityReservation: false
     desired:
       channel: "stable-4.9"
       version: "4.9.9"
   EOF
   ```


