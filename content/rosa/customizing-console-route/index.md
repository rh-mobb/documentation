---
date: '2023-11-30'
title: Customizing the console URL in ROSA
tags: ["ROSA", "AWS"]
authors:
  - Charlotte Fung
  - Thatcher Hubbard 
  - Dustin Scott
---

Starting with ROSA 4.14.X, it is possible to modify the hostname and TLS certificate of component Routes post-install. These are the `OAuth`, `Console`, and `Downloads` routes. For example, the default ROSA console uses the built-in domain `https://console-openshift-console.apps.<cluster_name>.<random>.p1.openshiftapps.com`. You can now specify a custom domain, for example `test.example.com`, and the ROSA console will be available at a URL such as `https://console-openshift-console.test.example.com`. This guide will walk you through how to customize the console url for a ROSA Classic cluster (not tested on ROSA HCP yet).


## Prerequisites

* A Red Hat OpenShift for AWS (ROSA) cluster 4.14.0 or higher
* Cluster admin privileges (required to be able to modify cluster ingress)
* Route53 Hosted Zone
* A custom domain
* Three individual component route certificates (Console, Oauth and Downloads)
* `rosa` cli
* `oc` cli

## Deploy 

### Set up Environment

1. Set your email and domain
    
     ```bash
     export EMAIL=<YOUR-EMAIL>
     export DOMAIN=<YOUR-DOMAIN>
     ```

1. Set remaining environment variables 
   
     ```bash
     export SCRATCH_DIR=/tmp/scratch
     mkdir -p $SCRATCH_DIR
     ```

### Individual Component Route Certificates

1. Create TLS Key Pair for individual component routes

   > **NOTE:** you can use cert-manager if preferred > https://cloud.redhat.com/experts/rosa/dynamic-certificates/

   > **NOTE:** this is required because the component routes require their own individual certs

   > Skip this step if you already have key pairs for the individual component routes.  You will use those key 
   pairs to create as secrets in the next step instead

     ```bash
     for CERT in oauth downloads console; do
       mkdir -p $SCRATCH_DIR/$CERT
       certbot certonly --manual \
         --preferred-challenges=dns \
         --email $EMAIL \
         --server https://acme-v02.api.letsencrypt.org/directory \
         --agree-tos \
         --config-dir "$SCRATCH_DIR/$CERT/config" \
         --work-dir "$SCRATCH_DIR/$CERT/work" \
         --logs-dir "$SCRATCH_DIR/$CERT/logs" \
         -d "$CERT.$DOMAIN"
     done
     ```

1. Create TLS secrets for your custom domain in the openshift-config namespace

     ```bash
     for CERT in oauth downloads console; do
       CERTS=/tmp/scratch/$CERT/config/live/$DOMAIN
       oc create secret tls $CERT-cert --cert=$CERTS/fullchain. pem --key=$CERTS/privkey.pem -n openshift-config
     done
     ```


### Create wildcard DNS record and point to DNS entry of Ingress controller

1. Retrieve the cluster's default ingress id
     ```bash
     rosa list ingress -c <cluster_name>
     ```
     > Take note of the default ingress ID.  

1. Retrieve the ROSA default ingress load balancer DNS name (can use the AWS console or run the command below).
     
     ```bash
     oc get services -n openshift-ingress | grep default
     ```
   or 

   ![aws loadbalancer console](images/ingress-dns.png)

1. Add a wildcard DNS record in your custom domain Route53 Hosted Zone to CNAME to the router-default 

   ![wildcard record](images/wildcardrecord.png)

1. Update each component route to include the custom domain you are choosing, as well as each of the certificates
that were provisioned above.  It should be noted that the `tlsSecretRef` refers to the component certs created as secrets and they cannot be shared amongst one another:

     ```bash
     rosa edit ingress -c <cluster-id> <default-ingress-id> \
       --component-routes="oauth: hostname=oauth.$DOMAIN;tlsSecretRef=oauth-cert,\
       downloads: hostname=downloads.$DOMAIN;tlsSecretRef=downloads-cert,\
       console: hostname=console.$DOMAIN;tlsSecretRef=console-cert"
     ```


### Test
1. Retrieve ROSA console URL
   
     ```bash
     oc whoami --show-console
     ```

1. Navigate to your console domain in the browser to access the login page. If logged into the console already, logout before logging back in again. 
 
   > The Oauth componentRoute is also accessible on the custom domain

   ![consolelogin](images/consolelogin.png)

1. Login to the console 

    ![rosaconsole](images/consoleurlview.png)
   
   
