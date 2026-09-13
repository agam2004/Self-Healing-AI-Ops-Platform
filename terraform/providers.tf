# providers.tf

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Stage 1 uses local state. Once the S3 bucket + DynamoDB lock table exist
  # (created in Stage 2 alongside the VPC), uncomment this and run
  # `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket         = "aiops-terraform-state"
  #   key            = "self-healing-aiops/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "aiops-terraform-lock"
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.name_prefix
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
