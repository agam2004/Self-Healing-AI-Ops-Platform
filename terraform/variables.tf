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

variable "ecr_repo_name" {
  description = "Name of the ECR repository for the app container image"
  type        = string
  default     = "aiops-app"
}
