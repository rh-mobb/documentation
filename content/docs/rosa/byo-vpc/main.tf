provider "aws" {
  region = "us-east-2"
}

variable "vpc_name" {
  type = string
  default = "rosa-byo-vpc"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.78.0"

  name = var.vpc_name
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a"]
  private_subnets = ["10.0.1.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}