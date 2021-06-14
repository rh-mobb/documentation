## Creating a Public/Private BYO VPC for ROSA

This is example Terraform to create a single AZ VPC in which to deploy a single AZ ROSA cluster. This is intended to be used as a guide to get started quickly, not to be used in production.

## Pre-Requisites

* [Terraform](https://www.terraform.io/downloads.html)

## Deploy

1. Download this repo

    ```bash
    git clone https://github.com/rh-mobb/documentation.git
    cd documentation/docs/rosa/byo-vpc
    ```

1. Modify main.tf as needed, then run

    ```bash
    terraform init
    terraform plan
    terraform apply
    ```

## Cleanup

1. To destroy resources

  ```bash
  terraform destroy
  ```
