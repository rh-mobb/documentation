
## Pre-requisites

* You need the `git` binary installed on your machine.  You can download it from the [git website](https://git-scm.com/downloads).

* You need to have the `terraform` binary installed on your machine.  You can download it from the [Terraform website](https://www.terraform.io/downloads.html).

* You need to have the `jq` binary installed on your machine.  You can download it from the [jq website](https://stedolan.github.io/jq/download/).

* You need to have the `oc` binary installed on your machine.  You can download it from the [OpenShift website](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/).

* You need to have the `rosa` binary installed on your machine.  You can download it from the [ROSA website](https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/).

* You need to have an OpenShift Cluster Manager (OCM) account.  You can sign up for an account on the [OCM website](https://cloud.redhat.com/openshift/).

* Get an OCM API token.  You can do this by logging into OCM and going to the [API tokens page](https://cloud.redhat.com/openshift/token/rosa).

*  You need to log in to OCM and create a refresh token.  You can do this by running the following command:

    ```
    rosa login
    ```

    Use the OCM API token you created in the previous step to log in.
