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

We will elaborate more about the variable defaults that we are overriding for this scenario in the scenario-specific section below. FIX THIS SHI


### Make
Make is a build automation tool to manage the compilation and execution of programs. It reads a file called a "makefile" that contains a set of rules and dependencies, allowing developers to define how source code files should be compiled, linked, and executed.

The makefile can be found in the root directory of the GitHub repo, and here below is the snippet:

```bash
.DEFAULT_GOAL := help
.PHONY: help virtualenv kind image deploy


CLUSTER_NAME ?= ans-$(shell whoami)
EXTRA_VARS ?= --extra-vars "cluster_name=$(CLUSTER_NAME)"

VIRTUALENV ?= "./virtualenv/"
ANSIBLE = $(VIRTUALENV)/bin/ansible-playbook $(EXTRA_VARS)


<details>
  <summary>
    omitted
  </summary>
  
  help:
	@echo GLHF

virtualenv:
		LC_ALL=en_US.UTF-8 python3 -m venv $(VIRTUALENV)
		. $(VIRTUALENV)/bin/activate
		pip install pip --upgrade
		LC_ALL=en_US.UTF-8 $(VIRTUALENV)/bin/pip3 install -r requirements.txt #--use-feature=2020-resolver
		$(VIRTUALENV)/bin/ansible-galaxy collection install -r requirements.yml

docker.image:
	docker build -t quay.io/pczar/ansible-rosa .

docker.image.push:
	docker push quay.io/pczar/ansible-rosa

docker.image.pull:
	docker pull quay.io/pczar/ansible-rosa

# docker shortcuts
build: docker.image
image: docker.image
push: docker.image.push
pull: docker.image.pull


create:
	$(ANSIBLE) -v create-cluster.yaml

delete:
	$(ANSIBLE) -v delete-cluster.yaml

create.multiaz:
	$(ANSIBLE) -v create-cluster.yaml -i ./environment/multi-az/hosts

create.private:
	$(ANSIBLE) -v create-cluster.yaml -i ./environment/private-link/hosts

delete.private:
	$(ANSIBLE) -v delete-cluster.yaml -i ./environment/private-link/hosts

delete.multiaz:
	$(ANSIBLE) -v delete-cluster.yaml -i ./environment/multi-az/hosts

create.tgw:
	$(ANSIBLE) -v create-cluster.yaml -i ./environment/transit-gateway-egress/hosts

delete.tgw:
	$(ANSIBLE) -v delete-cluster.yaml -i ./environment/transit-gateway-egress/hosts

create.hcp:
	$(ANSIBLE) -v create-cluster.yaml -i ./environment/hcp/hosts

delete.hcp:
	$(ANSIBLE) -v delete-cluster.yaml -i ./environment/hcp/hosts


docker.create: image
	docker run --rm \
		-v $(HOME)/.ocm.json:/home/ansible/.ocm.json \
		-v $(HOME)/.aws:/home/ansible/.aws \
	  -ti quay.io/pczar/ansible-rosa \
		$(ANSIBLE) -v create-cluster.yaml

docker.delete: image
	docker run --rm \
		-v $(HOME)/.ocm.json:/home/ansible/.ocm.json \
		-v $(HOME)/.aws:/home/ansible/.aws \
	  -ti quay.io/pczar/ansible-rosa \
		$(ANSIBLE) -v delete-cluster.yaml


galaxy.build:
	ansible-galaxy collection build --force .

galaxy.publish:
	VERSION=$$(yq e '.version' galaxy.yml); \
	ansible-galaxy collection publish rh_mobb-rosa-$$VERSION.tar.gz --api-key=$$ANSIBLE_GALAXY_API_KEY
</details>


```

## Implementation

### Scenario-specific
As mentioned previously, the variable defaults for the playbook can be found in the <mark>./roles/_vars/defaults/main.yml</mark> 

```bash
# defaults for roles/cluster_create
rosa_private: false
rosa_private_link: false
rosa_sts: true
rosa_disable_workload_monitoring: false
rosa_enable_autoscaling: false
rosa_hcp: false

# wait for rosa to finish installing
rosa_wait: true
rosa_multi_az: false
rosa_admin_password: "Rosa1234password67890"
rosa_vpc_endpoints_enabled: false
rosa_subnet_ids: []
rosa_machine_cidr: ~

# defaults for roles/juphost-create
# when not set will search based on ami_name
jumphost_ami: ""
jumphost_ami_name: "RHEL-8.8.0_HVM-*-x86_64-*Hourly*"
jumphost_instance_type: t1.micro


# enable this if you want a second jumphost in the
# rosa private subnet, useful for testing TGW connectivity
jumphost_private_instance: false
proxy_enabled: false

# when not set will search based on ami_name
# proxy_ami: ami-0ba62214afa52bec7
proxy_ami: ""
proxy_ami_name: "RHEL-8.8.0_HVM-*-x86_64-*Hourly*"
proxy_instance_type: m4.large

# defaults for roles/vpc_create
rosa_vpc_cidr: "10.0.0.0/16"
rosa_region: "us-east-2"

# defaults file for roles/tgw_create
rosa_tgw_enabled: false

# the full CIDR that TGW should route for
rosa_egress_vpc_enabled: false
rosa_egress_vpc_multi_az: false
rosa_tgw_cidr: "10.0.0.0/8"
rosa_egress_vpc_cidr: "10.10.0.0/24"

```

And for this particular scenario with Privatelink and Transit Gateway, those variables are overridden by the following FIX THIS SHI




### Prerequisites 
* AWS CLI
* ROSA CLI >= 1.2.22
* ansible >= 2.15.0
* python >= 3.6
* boto3 >= 1.22.0
* botocore >= 1.25.0
* make
* sshuttle

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

Note that the cluster setup may take up to one hour. Once the cluster is successfully deployed, connect to the jump host and login to your cluster using the credentials provided by Ansible upon the creation task completion.

And when you are done with the cluster, use the following command to delete the cluster.

```bash
make delete.tgw
```
