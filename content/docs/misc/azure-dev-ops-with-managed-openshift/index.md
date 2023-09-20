---
date: '2023-03-14'
title: Azure DevOps with Managed OpenShift
tags: ["DevOps", "ADO", "Azure", "ARO", "ROSA"]
authors:
  - Kevin Collins
---

**Author: Kevin Collins**

*Last edited: 03/14/2023*

Adopted from [Hosting an Azure Pipelines Build Agent in OpenShift](https://cloud.redhat.com/blog/hosting-an-azure-pipelines-build-agent-in-openshift)
and [Kevin Chung Azure Pipelines OpenShift example](https://github.com/kevchu3/kevin-azure-pipelines-openshift)


Azure DevOps is a very popular DevOps tool that has a host of features including the ability for developers to create CI/CD pipelines.

In this document, I will show you how to connect your Managed OpenShift Cluster to Azure DevOps end-to-end including running the pipeline build process in the cluster, setting up the OpenShift internal image registry to store the images, and then finally deploy a sample application.  To demonstrate the flexibility of Azure DevOps, I will be deploying to a ROSA cluster, however the same procudures will apply to if you choose to deploy to any other OCP Cluster.

## Prerequisites

* A Public Cloud subscription (Azure Subscription)
* Azure Dev Ops instance
* An OpenShift Cluster *(to create an Azure Red Hat OpenShift (ROSA) cluster, click [here](https://mobb.ninja/docs/quickstart-rosa.html))*

## Clone example application and configuration files
```bash
git clone https://github.com/rh-mobb/azure-pipelines-openshift

cd azure-pipelines-openshift
```

## Configure Azure Devops
While logged into your [Azure DevOps Organization](https://aex.dev.azure.com/me?mkt=en-US), create a new project.  The examples in this document will assume the project is named azure-pipelines-openshift
![ADO New Project](./images/ado-new-project.png)


Obtain a personal access token.  While in Azure DevOPs, select Personal Access Token under User Settings.
![azpat](./images/azpat.png)


On the next screen, create a New Token.  In this example, we will create a token with Full Access.  Once you click create your token will be displayed.  Make sure to store it somewhere safe as you won't be able to see it again.  
![create-pat](./images/create-pat.png)

### Set Azure DevOps environment variables for your Azure DevOps instance
```bash
AZP_URL=https://dev.azure.com/<yourOrg>
AZP_TOKEN=<Token you retrieved above>
AZP_POOL=Default
```

## Host an Azure Pipelines Build Agent in OpenShift
note: this is an abreviated version of this [blog](https://cloud.redhat.com/blog/hosting-an-azure-pipelines-build-agent-in-openshift) by Kevin Chung and Mark Dunnett.

In this step, we will configure OpenShift to build our container image leveraging Universal Base Images ( UBI )


### Configure the Azure DevOps build agent with OpenShift
Start by creating a new project
```bash
oc new-project azure-build
```

Create the following artifacts that include a wrapper script for the build agent and an example BuildConfig that will build a .NET application using the Red Hat Universal Based Image for .NET
```bash
 oc create configmap start-sh --from-file=start.sh=assets/start.sh
 oc create imagestream azure-build-agent
 oc create -f assets/buildconfig.yaml
```

Update the azure build agent image

``` bash
oc set env bc/azure-build-agent AZP_AGENT_PACKAGE_LATEST_URL=https://vstsagentpackage.azureedge.net/agent/2.218.1/vsts-agent-linux-x64-2.218.1.tar.gz
oc start-build azure-build-agent
```

As a cluster admin, create a service account for the build agent

```bash
 oc create serviceaccount azure-build-sa
 oc create -f assets/nonroot-builder.yaml
 oc adm policy add-scc-to-user nonroot-builder -z azure-build-sa
```
Make sure to be in the root directory of the Azure Pipelines OpenShift git repository you cloned in the previous step.

Create a secret with your Azure DevOps credentials
```bash
oc create secret generic azdevops \
  --from-literal=AZP_URL=${AZP_URL} \
  --from-literal=AZP_TOKEN=${AZP_TOKEN} \
  --from-literal=AZP_POOL=${AZP_POOL}
```

Deploy the azure build agent
```bash
 oc create -f assets/deployment.yaml
```

Make sure the build agent is running:
```bash
oc get pods
```

expected output:
```
NAME                                 READY   STATUS      RESTARTS   AGE
azure-build-agent-1-build            0/1     Completed   0          18m
azure-build-agent-2-build            0/1     Completed   0          15m
azure-build-agent-5d7c455ffd-d2pcc   1/1     Running     0          46s
```

## Create an Azure DevOps Pipeline
The pipeline we will create has three steps.
1. build the image on the OpenShift cluster
2. push the image to the internal registry of the OpenShift cluster
3. deploy the application to the cluster

Before we can do steps 2 and 3, we need to create a service account in OpenShift to both authenticate with OpenShift to push an image and also the internal image registry.  

Create a new project for our application
```bash
 oc new-project ado-openshift
```

 Create a service account and grant it cluster-admin privileges
 ```bash
 oc create sa azure-sa
 oc adm policy add-cluster-role-to-user cluster-admin -z azure-sa
 ```

 Create a secret token for the service account
```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: azure-sa-secret
  annotations:
    kubernetes.io/service-account.name: "azure-sa" 
type: kubernetes.io/service-account-token
EOF
```

 Retrieve the secret name that we just created that was a token associated with it.

```bash
  oc get secrets | grep azure-sa-token | awk '{ print $1 }'
```

expected output:

```
azure-sa-token-2qrgw
```
note: your output will have a different name

Describe the secret to retrieve the token:

```bash
oc describe secret <secret name>
```
expected output:
```
Name:         azure-sa-token-2qrgw
Namespace:    ado-openshift
Labels:       <none>
Annotations:  kubernetes.io/created-by: openshift.io/create-dockercfg-secrets
              kubernetes.io/service-account.name: azure-sa
              kubernetes.io/service-account.uid: d361f12e-db7d-412b-9ab8-8ac3a0ba459b

Type:  kubernetes.io/service-account-token

Data
====
token:           eyJhbGciOiJSUzI1NiIsImtpZCI6IlFBcmE2b1N5NnA2OUJZcEh2WUVad1BCSGozck9fa2tpaG83bnctM0hUd00ifQ.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJhZG8tb3BlbnNoaWZ0Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6ImF6dXJlLXNhLXRva2VuLTJxcmd3Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQubmFtZSI6ImF6dXJlLXNhIiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQudWlkIjoiZDM2MWYxMmUtZGI3ZC00MTJiLTlhYjgtOGFjM2EwYmE0NTliIiwic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50OmFkby1vcGVuc2hpZnQ6YXp1cmUtc2EifQ.GhLVRAJcG_CHuUxPaz3H_d_E_tGkFK6VaaFv_4UGZiwLLE1Hx-nSIYOA7YsOUvKOkdY2B6fIJrcLUBe5SUjiK0ZePSJZQNry_oZ9xKqhgSRFntxHT5mUR_BXT4cnF5zv0zrT3dvqWcM11mTSs2xfmCx8eACt-uEz2CtLHmxqkvpsiZA2wFQfxekInFFwFhbZSeQk6YBRGFu5f-eawP7qzzDibmo_GmMLHH4uLnpR1CJQFYzI09fEdzSf7IK2UzBgn6dmqpSzHnxLMjgHJVkX66FztJochlGUV8bE4acZk54lu_Xo7OhKxjhiqdeMHFBzq2PeSyvdvSspFME9y6_gXcy1-4QjxLM3t_K9yj7LsJSZKWn8HcmTJy_HoTvpbPtDznz_KEYJH1yX4zdK36D0ocUAb3gBNgfXlsEPAVXYV2o75ZL-AEwpumBv49rRNs_-wZKRO_3eR5zgZWGjZpVoDRb1F_QoFkxy-pnF2sSMQXZOEjwFTapESP182mWZtzzdU8TMOcdK44cr9mYB5IYBmJ2JTRQR2K_iTLfgK-im8O2K5n6OAwWBl4w8mpZDx0eHDp4IBfCBJk2AlopGrQ4TOf-l2bkcEnbJco7ei4D39tRR6xQcPddPEPEDbwIudI9IEzNhyJmHztUnjMV5NaC17hJ05AXWS83nPxFhH_a7pN8
ca.crt:          8717 bytes
namespace:       13 bytes
service-ca.crt:  9930 bytes
```
Copy the value of the token.

Retrieve the host of your cluster image regstry.
```bash
 oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}'
```
Expected Output:
```
default-route-openshift-image-registry.apps.ado-rosa.9s68.p1.openshiftapps.com
```

Get the cluster api endpoint
```bash
oc cluster-info
```

expected output:
```
 Kubernetes control plane is running at https://api.ado-rosa.9s68.p1.openshiftapps.com:6443
```

note the api server url for usage later 

### Configure Azure DevOps service connections for the registry and OpenShift

From Azure DevOps, click on Project settings ( the gear icon ), then Service Connections, and finally Create service connection.

 
 ![create-service-connection](./images/create-service-connection.png)


Select Docker registry
 
 ![docker-registry](./images/docker-registry.png)

Enter the settings we retrieved in the previous step:

* Select Others for Docker Registry
* Docker Registry - make sure to add https:// in front of the hostname you retrieved
* Docker ID - the service account you created
* Docker Password - the service account token
* Service connection name - enter openshift-registry

Next, let's create a another serivce connection for our cluster.

Click New service connection:

 ![new-service-connection](./images/new-service-connection.png)

Select Kubernetes
 
 ![select-kubernetes](./images/select-kubernetes.png)

* Server Url - the api server you retrieved in the previous step

* Secret - using the name of the secret that we retieved earlier that has token in the name run:
   ```bash
   oc get secret azure-sa-token-2qrgw -o json
   ```

  Copy the entire json results and paste it in the Secret field

* Service connection name - select openshift

 ![openshift-settings](./images/openshift-connection.png)

## Create an Azure DevOps Pipeline

We will be deploying an application from a GitHub repo.  Fork the following Git Repo: https://github.com/rh-mobb/azure-pipelines-openshift

In Azure DevOPs, click on Pipelines and then Create Pipeline
 
 ![new-pipeline](./images/new-pipeline.png)

On the next screen, select GitHub
 
 ![pipeline-github](./images/pipeline-github.png)

On the next screen, select your github repo that you forked to.

Review the azure-pipelines.yml file and then click run.

If this is the first time running, you might see a message like the following:
 
 ![build-permissions](./images/build-permissions.png)

Clickad on the Build and Push Image tile, and then view permissions, and grat permissions to both the Default queue and the openshift-registry service connection.
 
 ![grant-build-permissions](./images/grant-build-permissions.png)

Like we saw with permissions on the build and push, we also need to give permissions to deploy.

 ![permission-deploy](./images/grant-deploy-permissions.png)

On the next screen, click on Permit to give access to the OpenShift connection.

 ![grand-openshift-permission](./images/grant-openshift-permissions.png)

After a few minutes, you should see both the Build and Push Image and Deploy to DEV stages complete.

 ![successful-pipeline](./images/successful-pipeline.png)

To verify the application was successfully deployed in openshift run:
```bash
oc get pods -n ado-openshift
```

expected output:
```
NAME                          READY   STATUS    RESTARTS   AGE
ado-dotnet-74b64db7d5-p8vr7   1/1     Running   0          98s
```