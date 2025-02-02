---
date: '2022-07-29'
title: Migrate Kubernetes Applications with Konveyer Crane
aliases: ['/experts/demos/crane/']
tags: []
authors:
  - Paul Czarkowski
  - JJ Asghar
---

## Introduction

Occasionally when you're moving between major version of Kubernetes or Red Hat OpenShift, you'll want to migrate your applications between clusters. Or if you're moving between two clouds, you'll want an easy way to migrate your workloads from one platform to another.

The Crane operator from the open source Konveyer project automates this migration process for you. The [Konveyer](https://konveyer.io) site offers a selection of helpful
projects to administer your cluster. Crane is designed to automate migration from one cluster to another and is surprisingly easy to get working.

This article shows you how we moved a default sample application from a Red Hat OpenShift on AWS (ROSA) to a Red Hat OpenShift on IBM Cloud (ROIC) cluster. To see how it's done, watch the video or read the steps below.

<iframe width="1085" height="610" src="https://www.youtube.com/embed/LK23k1RDt14" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

## Install the Crane operator

First, log into the cluster console where your original application is hosted and also log into the console of the destination where you want to migrate your application. In our example, we logged into the OpenShift Service on AWS as our origin console and, in another tab, logged into to the Red Hat OpenShift on IBM Cloud console as our destination console.

From the Operator Hub in both consoles, search for "Crane Operator" and follow the default prompts to install the operator.

## Set up your sample application

From your origin cluster, choose the Developer profile and then click **+Add** to add a project where you will deploy your application into.

Choose a sample app to play with. In our example, we chose the Python application. Name it and then click “Create”. It will pull the source information from GitHub and build an image, deploy the image, and expose it as a PHP endpoint.

You can change back from a Developer profile to the Admin profile in order to see if the operator has been installed correctly.

## Create a migration (MIG) controller

Now it’s time to create your migration controller.

1. Go to your m migration cluster (in this example, our IBM console), select the Crane operator, and select **Create migration controller**. Do the same on the origin cluster (in our example, AWS).

1. Switch to the `openshift-migration` namespace.

1. Update the host MIG controller.

    ```yaml
    apiVersion: migration.openshift.io/v1alpha1
    kind: MigCluster
    metadata:
      name: host
      namespace: openshift-migration
    spec:
      isHostCluster: true
    ```

1. Then you can apply your migration cluster.

    ```bash
    kubectl apply -f origin-migcluster.yaml
    ```

* **NOTE**: Run only _this_ following command on the remote cluster

1. Save your service account secret for the destination cluster.

    ```bash
    oc sa get-token migration-controller -n openshift-migration | base64 -w 0
    ```

1. Write this into `sa-secret-remote.yaml` on your origin cluster:

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: sa-token-remote
      namespace: openshift-config
    type: Opaque
    data:
      # [!] Change saToken to contain a base64 encoded SA token with cluster-admin
      #     privileges on the remote cluster.
      #     `oc sa get-token migration-controller -n openshift-migration | base64 -w 0`
      saToken: <your-base64-encoded-aws-sa-token-here>
    ```

    ```bash
    kubectl apply -f sa-secret-remote.yaml
    ```

1. Add your destination cluster:

    ```yaml
    apiVersion: migration.openshift.io/v1alpha1
    kind: MigCluster
    metadata:
      name: src-ocp-3-cluster
      namespace: openshift-migration
    spec:
      insecure: true
      isHostCluster: false
      serviceAccountSecretRef:
        name: sa-token-remote
        namespace: openshift-config
      url: 'https://master.ocp3.mycluster.com/'
    ```

    ```bash
    kubectl apply -f dest-migcluster.yaml
    ```

1. Configure s3 credentials to host migration storage. Included here is the correct access key for my files. You'll need to have that handy.

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      namespace: openshift-config
      name: migstorage-creds
    type: Opaque
    data:
      aws-access-key-id: aGVsbG8K
      aws-secret-access-key: aGVsbG8K
    ```

    ```bash
    kubectl apply -f mig-storage-creds.yaml
    ```

1. Configure MIG storage to use s3

    ```yaml
    apiVersion: migration.openshift.io/v1alpha1
    kind: MigStorage
    metadata:
      name: aws-s3
      namespace: openshift-migration
    spec:
      backupStorageConfig:
        awsBucketName: konveyer-jj-migration # You need to change this for your s3 bucket
        credsSecretRef:
          name: migstorage-creds
          namespace: openshift-config
      backupStorageProvider: aws
      volumeSnapshotConfig:
        credsSecretRef:
          name: migstorage-creds
          namespace: openshift-config
      volumeSnapshotProvider: aws
    ```

    ```bash
    kubectl apply -f migstorage.yaml
    ```

1. Create the migration plan. THe plan is essentially saying: "This is what I want". The plan says what namespace you want to move. In this example, it’s `project-a` as referenced below.

    ```yaml
    apiVersion: migration.openshift.io/v1alpha1
    kind: MigPlan
    metadata:
      name: migrate-project-a
      namespace: openshift-migration
    spec:
      destMigClusterRef:
        name: destination
        namespace: openshift-migration
      indirectImageMigration: true
      indirectVolumeMigration: true
      srcMigClusterRef:
        name: host
        namespace: openshift-migration
      migStorageRef:
        name: aws-s3
        namespace: openshift-migration
      namespaces:
        - project-a # notice this is where you'd add other projects
      persistentVolumes: []
    ```

    ```bash
    kubectl apply -f migplan.yaml
    ```

1. Execute your migration plan.

    ```yaml
    apiVersion: migration.openshift.io/v1alpha1
    kind: MigMigration
    metadata:
      name: migrate-project-a-execute
      namespace: openshift-migration
    spec:
      migPlanRef:
        name: migrate-project-a
        namespace: openshift-migration
      quiescePods: true
      stage: false
    ```

    ```bash
    kubectl apply -f migplanexecute.yaml
    ```

## Watch the magic

Back in your original console, you can find the correct namespace and see that things have moved.

1. Go back to the origin OpenShift console (AWS in our example). Bring up the migration GUI from the openshift-migration namespace. Check through the migration plans which show you the migration or watch the logs to see the migration happening.

1. Or, watch the progress via the CLI if you prefer.

```bash
 kubectl logs -f migration-log-reader-<hash> color
```

You can also open your destination console (Red Hat OpenShift on IBM Cloud in our example) and see if the new cluster has migrated.

## Conclusion

Hopefully walking through these steps has helped you understand the power that Crane can offer you when migrating workloads between clusters. This was only a sample application. With a little
work and testing, you should be able to leverage Crane for your applications. If you
have any questions or thoughts, come around to #konveyer on the
Kubernetes public Slack channel, and the team would me more then willing to help advise
you.

Happy migrating your apps!
