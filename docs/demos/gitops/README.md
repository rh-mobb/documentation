# Demonstrate GitOps on Managed OpenShift using ArgoCD

>This demo assumes you have a Managed OpenShift Cluster available and cluster-admin rights.

### GitHub resources referenced in the demo:

1. BGD Application:  https://github.com/rh-mobb/gitops-bgd-app
2. OpenShift / ArgoCD configuration:  https://github.com/rh-mobb/gitops-demo

## Install the OpenShift GitOps operator

1. Log into OpenShift and go to the **Operator Hub**

2. Search for the **OpenShift GitOps** operator and install

![screenshot of GitOps install](./gitops_operator.png)

## Pull files from GitHub

1. Clone the `gitops-demo` GitHub repository to your local machine
```
git clone https://github.com/rh-mobb/gitops-demo gitops
```

2. Export your local path to the GitHub files
```
export GITOPS_HOME="$(pwd)/gitops"
cd $GITOPS_HOME
```

## Log in to OpenShift via the CLI

1. Retrieve the login command from the OpenShift console
![screenshot of login](./oc_login.png)

2. Enter the command in your terminal to authenticate with the OpenShift CLI (oc)
>Output should appear similar to:
```
Logged into "https://<YOUR-INSTANCE>.openshiftapps.com:6443" as "<YOUR-ID>" using the token provided.
```



