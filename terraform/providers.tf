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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket         = "aiops-terraform-state-752953536627"
    key            = "self-healing-aiops/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "aiops-terraform-lock"
  }
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
