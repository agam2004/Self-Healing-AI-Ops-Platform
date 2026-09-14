# eks.tf — Stage 2 step 1: the EKS cluster
#
# Security posture:
#  - Worker nodes live only in private subnets (no public IPs).
#  - Control plane API: private access always on (nodes/Lambda reach it
#    in-VPC); public access on but locked to eks_public_access_cidrs so
#    kubectl works from a known IP, never from 0.0.0.0/0.
#  - Kubernetes Secrets are envelope-encrypted with our own KMS key, not the
#    AWS default.
#  - Control plane audit/api/authenticator logs ship to CloudWatch so the
#    AI-Ops Lambda (and a human) has something to correlate an incident
#    against.
#  - IRSA (IAM Roles for Service Accounts) is enabled via the module's OIDC
#    provider, so pods (and later, the auto-remediation controller) get
#    scoped IAM permissions instead of sharing the node's instance role.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # We supply our own KMS key (kms.tf) rather than letting the module
  # create a second, redundant one.
  create_kms_key = false
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = 14

  # The identity running `terraform apply` becomes a cluster-admin via
  # EKS access entries, so kubectl works immediately without hand-editing
  # aws-auth.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "SPOT" # demo/portfolio cluster — spot is fine and materially cheaper

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = module.vpc.private_subnets

      # Nodes talk to the control plane, pull images, ship logs/metrics —
      # they never need to accept unsolicited inbound traffic from the
      # internet, and they can't (private subnets), but keep the SG tight
      # regardless of subnet placement as defense in depth.
      security_group_rules = {
        egress_all = {
          description = "Node egress (control plane, ECR, package repos, etc.)"
          protocol    = "-1"
          from_port   = 0
          to_port     = 0
          type        = "egress"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
  }

  tags = {
    Project = var.name_prefix
  }
}
