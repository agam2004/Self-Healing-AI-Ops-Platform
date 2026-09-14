# variables.tf

variable "region" {
  description = "AWS region to deploy all resources into"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names for namespacing"
  type        = string
  default     = "aiops"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

# ─────────────────────────────────────────
# GitHub OIDC / CI-CD
# ─────────────────────────────────────────
variable "github_repo" {
  description = "GitHub \"owner/repo\" allowed to assume the CI/CD IAM role via OIDC"
  type        = string
  default     = "agam2004/Self-Healing-AI-Ops-Platform"
}

variable "github_branch" {
  description = "Branch allowed to assume the CI/CD IAM role via OIDC"
  type        = string
  default     = "main"
}

# GitHub includes these stable numeric IDs in the OIDC token's `sub` claim
# (repo:owner@owner_id/repo@repo_id:ref:...) once an account or repo has ever
# been renamed, so an old trust policy can't be hijacked by renaming into it.
# Matching on the IDs (with wildcards over the name) keeps this role's trust
# policy valid even through future renames.
variable "github_owner_id" {
  description = "Stable numeric GitHub user/org ID for github_repo's owner"
  type        = string
  default     = "54416773"
}

variable "github_repo_id" {
  description = "Stable numeric GitHub repository ID for github_repo"
  type        = string
  default     = "1368144207"
}

variable "ecr_repo_name" {
  description = "Name of the ECR repository for the app container image"
  type        = string
  default     = "aiops-app"
}

# ─────────────────────────────────────────
# VPC & Networking
# ─────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across"
  type        = number
  default     = 2
}

# ─────────────────────────────────────────
# EKS
# ─────────────────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "aiops-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.30"
}

# The control plane API is reachable both from inside the VPC (nodes, the
# AI-Ops Lambda) and from the public internet, but only from these CIDRs —
# never 0.0.0.0/0. Update this to your current IP (`curl -s
# https://checkip.amazonaws.com`) before `terraform apply` if it has
# changed since this default was set.
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint"
  type        = list(string)
  default     = ["84.95.71.22/32"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

# ─────────────────────────────────────────
# RDS
# ─────────────────────────────────────────
variable "db_name" {
  description = "Initial database name created in the RDS instance"
  type        = string
  default     = "aiops"
}

variable "db_username" {
  description = "Master username for the RDS instance (the password is generated and stored in Secrets Manager, never in tfvars)"
  type        = string
  default     = "aiops_admin"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS, in GB"
  type        = number
  default     = 20
}
