---
date: '2022-09-14T22:07:09.854151'
title: Configuring IDP for ROSA and OSD
---

Red Hat OpenShift on AWS (ROSA) and OpenShift Dedicated (OSD) provide a simple way for the cluster administrator to configure one or more identity providers for their cluster[s] via the [OpenShift Cluster Manager (OCM)](https://console.redhat.com/openshift), while Azure Red Hat OpenShift relies on the internal cluster OAuth provider.

The identity providers available for use are:

+ GitHub
+ GitLab
+ Google
+ LDAP
+ OpenID
+ HTPasswd

## Configuring Specific Identity Providers

### ARO
* [GitLab](./gitlab-aro)
* [Azure AD](./azuread-aro)
* [Azure AD with Group Claims](./group-claims/aro)
* [Azure AD via CLI](./azuread-aro-cli)

### ROSA/OSD

* [GitLab](./gitlab)
* [Azure AD](./azuread)
* [Azure AD with Group Claims](./group-claims/rosa) (ROSA Only)

## Configuring Group Synchronization

* [Using Group Sync Operator with Azure Active Directory and ROSA/OSD](./az-ad-grp-sync)
* [Using Group Sync Operator with Okta and ROSA/OSD](./okta-grp-sync)
