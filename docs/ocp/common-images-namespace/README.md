# OpenShift - Sharing Common images

**Paul Czarkowski**

*21 June 2021*

In OpenShift images (stored in the in-cluster registry) are protected by Kubernetes RBAC and by default only the namespace in which the image was built can access it.

For example if you build an image in `project-a` only `project-a` can use that image, or build from it. If you wanted the default service account in `project-b` to have access to the images in `project-a` you would run the following.

```bash
oc policy add-role-to-user \
    system:image-puller system:serviceaccount:project-b:default \
    --namespace=project-a
```

However if you had to do this for every namespace it could become quite combersome. Instead if you choose to have a set of common images in a `common-images` namespace you could make them available to all authenticated users like so.

```bash
oc adm policy add-cluster-role-to-group system:image-puller \
  system:authenticated --namespace=common-images

oc adm policy add-role-to-group view system:authenticated \
  -n common-images
```

> Note: It's important to understand and accept the security implications that come with this. If *any* Pod in the cluster is compromised it will have access to pull any images in this namespace.

See [Global Image Puller](https://github.com/rh-mobb/global-image-puller) for an example Kubernetes Controller that may allow for a more surgical (but still automated) way to grant access to images.