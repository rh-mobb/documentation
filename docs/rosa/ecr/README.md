# Configuring a ROSA cluster to pull images from AWS Elastic Container Registry (ECR)

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Openshift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/) 4.8+
* [Docker](https://docs.docker.com/get-docker/)

## STS ROSA Clusters
With STS clusters, you can attach an ECR policy role to your cluster giving the cluster permissions to pull images from your registries.

### Attach ECR Policy Role
In order to be able to pull images from AWS ECR, you need to assign a policy role.  ROSA comes with a pre-defined policy role `ManagedOpenShift-Worker-Role` which is an IAM role used by ROSA compute instances.

ECR has several pre-defined policies that give permissions to interact with the service.  In the case of ROSA, we will be pulling images from ECR and will only need to add the `AmazonEC2ContainerRegistryReadOnly` policy.  

To add the `AmazonEC2ContainerRegistryReadOnly` policy to the `ManagedOpenShift-Worker-Role` run the following command:
```
 aws iam attach-role-policy \
  --role-name ManagedOpenShift-Worker-Role \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
```

## Test it Out
##### Log into ECR
```
aws ecr get-login-password --region region | docker login --username AWS --password-stdin aws_account_id.dkr.ecr.region.amazonaws.com
```

##### Create a repository
```
aws ecr create-repository \
    --repository-name hello-world \
    --image-scanning-configuration scanOnPush=true \
    --region region
```

##### Pull an image
```
docker pull openshift/hello-openshift
```

##### Tag the image for ecr
```
docker tag openshift/hello-openshift:latest <registry id>.dkr.ecr.<region>.amazonaws.com/hello-world:latest
```

note: you can find the registry id and URI with the following command
```
aws ecr describe-repositories
```

![resulting output](./images/repositories.png)
##### Push the image to ECR
```
docker push <registry id>.dkr.ecr.<region>.amazonaws.com/hello-world:latest
```

##### Create a new project
```
oc new project hello-world
```
##### Create a pull secret - only needed for non-STS Clusters 
```
oc create secret docker-registry ecr-pull-secret  --docker-server=<registry id>.dkr.ecr.<region>.amazonaws.com  --docker-username=AWS --docker-password=$(aws ecr get-login-password)  --namespace=hello-world
```



##### Link the secret to a service account - only needed for non-STS Clusters
```
oc secrets link default ecr-pull-secret --for=pull
```


##### Create a new app using the image on ECR
```
oc new-app --name hello-world --image <registry id>.dkr.ecr.<region>.amazonaws.com/hello-world:latest
```
