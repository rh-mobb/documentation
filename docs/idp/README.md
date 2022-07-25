# Configuring Identity Providers for ROSA and OSD #

**Andrea Bozzoni, Steve Mirman**

*16 February 2022*

Red Hat OpenShift on AWS (ROSA) and OpenShift Dedicated (OSD) provide a simple way for the cluster administrator to configure one or more indentity providers for their cluster[s]  through the [OpenShift Cluster Manager (OCM)](https://cloud.redhat.com/openshift).

The identity providers available for the configuration are:

+ GitHub
+ GitLab
+ Google
+ LDAP
+ OpenID
+ HTPasswd

## Configuring Specific Identity Providers

* [Configure GitLab as an identity provider for ROSA/OSD](./gitlab)
* [Configure GitLab as an identity provider for ARO](./gitlab-aro)
* [Configure Azure AD as an identity provider for ARO](./azuread-aro)
* [Configure Azure AD using OpenID](./azuread)
* [Configure Azure AD using OpenID via cli in ARO](./azuread-aro-cli)
## Configuring Group Synchronization

* [Configure Azure AD with ROSA/OSD](./az-ad-grp-sync)
