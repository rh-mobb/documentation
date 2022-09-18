---
date: '2022-09-14T22:07:10.024151'
title: Installing the Open Data Hub Operator
---

The Open Data Hub operator is available for deployment in the OpenShift OperatorHub as a Community Operators. You can install it from the OpenShift web console:

1. From the OpenShift web console, log in as a user with cluster-admin privileges. For a developer installation from try.openshift.com including AWS and CRC, the kubeadmin user will work.

2. Create a new project named ‘jph-demo’ for your installation of Open Data Hub
![UI Create Project](/docs/jup/images/3-createprojectname.png)

3. Find Open Data Hub in the OperatorHub catalog.
    - Select the new namespace if not already selected.
    - Under Operators, select OperatorHub for a list of operators available for deployment.
    - Filter for Open Data Hub or look under Big Data for the icon for Open Data Hub.

![UI Install Open Data Hub](/docs/jup/images/3-installedoperator.png)

4. Click the Install button and follow the installation instructions to install the Open Data Hub operator.(optional if operator not installed)

5. The subscription creation view will offer a few options including Update Channel, keep the rolling channel selected.

6. To view the status of the Open Data Hub operator installation, find the Open Data Hub Operator under Operators -> Installed Operators (inside the project you created earlier). Once the STATUS field displays InstallSucceeded, you can proceed to create a new Open Data Hub deployment.

7. Find the Open Data Hub Operator under Installed Operators (inside the project you created earlier)

8. Click on the Open Data Hub Operator to bring up the details for the version that is currently installed.

9. Click Create Instance to create a new deployment.

![UI Install Open Data Hub](/docs/jup/images/3-createinstance.png)

10. Select the YAML View radio button to be presented with a YAML file to customize your deployment. Most of the components available in ODH have been removed, and only components for JupyterHub are required for this example.

```
apiVersion: kfdef.apps.kubeflow.org/v1
kind: KfDef
metadata:
  creationTimestamp: '2022-06-24T18:55:12Z'
  finalizers:
    - kfdef-finalizer.kfdef.apps.kubeflow.org
  generation: 2
  managedFields:
    - apiVersion: kfdef.apps.kubeflow.org/v1
      fieldsType: FieldsV1
      fieldsV1:
        'f:spec':
          .: {}
          'f:applications': {}
          'f:repos': {}
      manager: Mozilla
      operation: Update
      time: '2022-06-24T18:55:12Z'
    - apiVersion: kfdef.apps.kubeflow.org/v1
      fieldsType: FieldsV1
      fieldsV1:
        'f:metadata':
          'f:finalizers':
            .: {}
            'v:"kfdef-finalizer.kfdef.apps.kubeflow.org"': {}
        'f:status': {}
      manager: opendatahub-operator
      operation: Update
      time: '2022-06-24T18:55:12Z'
  name: opendatahub
  namespace: jph-demo
  resourceVersion: '27393048'
  uid: f54399a6-faa7-4724-bf3d-be04a63d3120
spec:
  applications:
    - kustomizeConfig:
        repoRef:
          name: manifests
          path: odh-common
      name: odh-common
    - kustomizeConfig:
        parameters:
          - name: s3_endpoint_url
            value: s3.odh.com
        repoRef:
          name: manifests
          path: jupyterhub/jupyterhub
      name: jupyterhub
    - kustomizeConfig:
        overlays:
          - additional
        repoRef:
          name: manifests
          path: jupyterhub/notebook-images
      name: notebook-images
  repos:
    - name: kf-manifests
      uri: >-
        https://github.com/opendatahub-io/manifests/tarball/v1.4.0-rc.2-openshift
    - name: manifests
      uri: 'https://github.com/opendatahub-io/odh-manifests/tarball/v1.2'
status: {}
```
![UI KFyaml](/docs/jup/images/3-KFyaml.png)

11. Update the spec of the resource to match the above and click Create. If you accepted the default name, this will trigger the creation of an Open Data Hub deployment named opendatahub with JupyterHub.

12. Verify the installation by viewing the project workload. JupyterHub and traefik-proxy should be running.
![UI Project workload](/docs/jup/images/3-projectworkload.png)

13. Click Routes under Networking and url to launch Jupyterhub is created
![UI Project workload routes](/docs/jup/images/3-projectworkload-routes.png)

14. Open JupyterHub on web browser
![UI JupyterHub](/docs/jup/images/3-jupyterhub.png)

15. Configure GPU and start server
![UI Start Server](/docs/jup/images/3-jupyterhub-gpu-size-startserver.png)

16. Check for GPU in notebook
![UI GPUCheck](/docs/jup/images/3-GPUcheck_notebook.png)

Reference: Check the blog on [Using the NVIDIA GPU Operator to Run Distributed TensorFlow 2.4 GPU Benchmarks in OpenShift 4](https://cloud.redhat.com/blog/using-the-nvidia-gpu-operator-to-run-distributed-tensorflow-2.4-gpu-benchmarks-in-openshift-4)
