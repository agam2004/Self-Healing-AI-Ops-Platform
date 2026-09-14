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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
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

# Both providers authenticate the same way kubectl does — a short-lived
# token from `aws eks get-token`, not a static credential — so Helm/K8s
# access here dies with the calling identity's AWS session, same as the
# CI role and my own kubectl access.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  # Isolated from this machine's global Helm repo config/cache — this
  # project's chart pulls (prometheus-community, chaos-mesh) shouldn't
  # depend on, or perturb, whatever other repos happen to be configured
  # for interactive `helm` use on this machine.
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm/cache"

  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
