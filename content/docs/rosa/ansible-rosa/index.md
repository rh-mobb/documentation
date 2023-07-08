# Deploying ROSA PrivateLink Cluster with Ansible
Draft v0.1

## Background
This guide shows an example of how to deploy Red Hat OpenShift Services on AWS (ROSA) cluster with [PrivateLink](https://aws.amazon.com/privatelink/) with [STS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html) enabled using [Ansible](https://docs.ansible.com/) playbook from our [MOBB GitHub repo](https://github.com/rh-mobb/ansible-rosa) and [Makefiles](https://www.gnu.org/software/make/manual/make.html#Introduction) to compile them. Note that this is an unofficial Red Hat guide and your implementation may vary. 

Before we move into the deployment, let's talk about the architectural landscape of this deployment scenario including the AWS services and open source products and services that we will be using in high level. 


## Architecture

### ROSA Cluster with PrivateLink
PrivateLink allows you to securely access AWS services over private network connections, without exposing your traffic to the public internet. In this scenario, we will be using [Transit Gateway (TGW)](https://aws.amazon.com/transit-gateway/) allowing inter-VPC and VPC-to-on-premises communications by providing a scalable and efficient way to handle traffic between these networks. 

To help with DNS resolution, we will be using DNS forwarder to forward the queries to [Route 53 Inbound Resolver](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html) allowing the cluster to accept incoming DNS queries from external sources and thus establishing the desired connection without exposing the underlying infrastructure. 

![ROSA with PL and TGW](images/rosa-pl-tgw-newicons.png)

In addition, [Egress VPC](https://docs.aws.amazon.com/managedservices/latest/onboardingguide/networking-vpc.html) will be provisioned serving as a dedicated network component for managing outbound traffic from the cluster. A [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html) will be created within the public subnet of the Egress VPC and along with it a [Squid](http://www.squid-cache.org/)-based proxy to restrict egress traffic from the cluster to only the permitted endpoints or destinations. 

We will also be using [VPC Endpoints](https://docs.aws.amazon.com/whitepapers/latest/aws-privatelink/what-are-vpc-endpoints.html) to privately access AWS resources, e.g. gateway endpoint for S3 bucket, interface endpoint for STS, interface endpoint for EC2 instances, etc.     

Finally, once the cluster is created, we will access it by establishing secure SSH connection using a jump host that is set up within the Egress VPC, and to do so we will be using [sshuttle](https://sshuttle.readthedocs.io/en/stable/). 

### Ansible
Ansible is an open-source automation tool that simplifies system management and configuration. It uses a declarative approach, allowing users to define desired states using YAML-based [Playbooks](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_intro.html). With an agentless architecture and a vast [library of modules](https://docs.ansible.com/ansible/2.9/modules/modules_by_category.html), Ansible enables automation of tasks such as configuration management, package installation, and user management. 

### Git
Git is version control system that tracks changes to files and enables collaboration, and in this scenario, the deployment will be based on the Ansible playbook from MOBB GitHub repo at [https://github.com/rh-mobb/ansible-rosa](https://github.com/rh-mobb/ansible-rosa). 

We are specifying the environment and variables in the following directories:
* <mark>./environment/*/group_vars/all.yaml</mark> - environment setup
* <mark>./roles/_vars/defaults/main.yml</mark> - variables

Modules used: ***BTW, do we need to list this?***
* https://docs.ansible.com/ansible/latest/collections/amazon/aws/ec2_vpc_nat_gateway_module.html#parameter-connectivity_type 

### Make
Make is a build automation tool to manage the compilation and execution of programs. It reads a file called a "makefile" that contains a set of rules and dependencies, allowing developers to define how source code files should be compiled, linked, and executed.

## Implementation

### Prerequisites 
* AWS CLI
* ROSA CLI >= 1.2.22
* python >= 3.6
* boto3 >= 1.22.0
* botocore >= 1.25.0
* make
* sshuttle
* ansible (check min version)

### Deployment 
Once you have all of the prerequisites installed, clone our repo and go to the <mark>ansible-rosa</mark> directory.

```bash
git clone https://github.com/rh-mobb/ansible-rosa
cd ansible-rosa
``` 

Then, run the following command to create python virtual environment.

```bash
make virtualenv
```

Next, run the following command to allow Ansible playbook to create the cluster.

```bash
make create.tgw
```

Once the cluster is successfully deployed, login to your cluster using the credentials provided by Ansible upon the creation task completion.

And when you are done with the cluster, use the following command to delete the cluster.

```bash
make delete.tgw
```
