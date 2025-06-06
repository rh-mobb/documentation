---
date: '2025-06-05'
title: Simple Application to Compare Claude 3 Sonnet and Llama 3 70B via Amazon Bedrock with Red Hat OpenShift AI on ROSA 
tags: ["ROSA", "RHOAI", "Bedrock"]
authors:
  - Diana Sari
  - Deepika Ranganathan
---

## 1. Introduction

Agentic AI can be defined as systems that are capable of interpreting natural language instructions, in this case users' prompts, making decisions based on those prompts, and then autonomously executing tasks on behalf of users. In this guide, we will create one that is intelligent enough that not only that it can understand/parse users' prompts, but it can also take action upon it by deploying (and destroying) [Azure Red Hat OpenShift (ARO)](https://www.redhat.com/en/technologies/cloud-computing/openshift/azure) cluster using Terraform. 

[Terraform](https://www.terraform.io/) is an automation tool, sometimes referred to as an Infrastructure as Code (IaC) tool, that allows us to provision infrastructure using declarative configuration files. The agentic AI in this guide will provision those clusters based on our MOBB Terraform repository for [ARO](https://github.com/rh-mobb/terraform-aro). Here it runs on [Red Hat OpenShift AI (RHOAI)](https://www.redhat.com/en/products/ai/openshift-ai), which is our platform for managing AI/ML projects lifecycle, running on a [Red Hat OpenShift Service on AWS (ROSA)](https://www.redhat.com/en/technologies/cloud-computing/openshift/aws) cluster. In addition, we will be using Anthropic's Claude Sonnet 3 model via [Amazon Bedrock](https://aws.amazon.com/bedrock/).

In short, the objective of this guide to introduce you to what I'd like to call **Prompt-based Infrastructure** or perhaps, **Text-to-Terraform**. That said, the agentic AI we are creating will be able to deploy (and destroy) ARO cluster based on users' prompts such as whether it is private/public, which region, what types of worker nodes, number of worker nodes, which cluster version, and so forth. I will specify the prompts' parameters in the relevant sections and highlight the differences between the default parameters in this guide and in the Terraform repository.

Note that since real deployment could be costly, I set up simulator test with `mock` toggle that you can set to `True` for mock results and `False` for real cluster deployment. 

As usual, before we move forward, kindly note on the disclaimers below.

*Disclaimers: 
1. Note that this guide references Terraform repositories that are actively maintained by MOBB team and may change over time. Always check the repository documentation for the latest syntax, variables, and best practices before deployment. 

2. When using this agentic AI, please be aware that while the system is designed to interpret natural language instructions and autonomously execute infrastructure configurations, it is not infallible. The agentic AI may occasionally misinterpret requirements or generate suboptimal configurations. It is your responsibility to review all generated Terraform configurations before applying them to your cloud environment. Neither the author of this implementation nor the service providers can be held responsible for any unexpected infrastructure deployments, service disruptions, or cloud usage charges resulting from configurations executed by the agentic AI. 

3. Lastly, please note that user interfaces may change over time as the products evolve. Some screenshots and instructions may not exactly match what you see.*

## 2. Prerequisites

1. A [classic](https://cloud.redhat.com/experts/rosa/terraform/classic/) or [HCP](https://cloud.redhat.com/experts/rosa/terraform/hcp/) ROSA cluster   
- I tested this on an HCP ROSA 4.18.14 with `m5.8xlarge` instance size for the worker nodes. 

2. Amazon Bedrock
 - You could use any model of your choice via Amazon Bedrock, but in this guide, we'll use Anthropic Claude 3 Sonnet, so if you have not already, please proceed to your AWS Console and be sure that you enable the model (or the model of your choice) and that your account has the right permissions for Amazon Bedrock. 

3. RHOAI operator  
- You can install it using console per [Section 3 in this tutorial](https://cloud.redhat.com/experts/rhoai/rosa-s3) or using CLI per [Section 3 in this tutorial](https://cloud.redhat.com/experts/rhoai/rosa-gpu/). 
- Once you have the operator installed, be sure to install `DataScienceCluster` instance, wait for a few minute for the changes to take effect, and then launch the RHOAI dashboard for next step.  
- I tested this tutorial using RHOAI version 2.19.0. 

## 3. Setup 

First, we will create the setup file and to do so, you would need your Azure credentials such as your Azure Client ID, Azure Client Secret, Azure Tenant ID, and Azure Subscription ID. Keep these credentials handy for the this step. 
