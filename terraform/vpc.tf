# vpc.tf — Stage 2 step 1: networking for the EKS cluster
#
# Public subnets: NAT gateway + internet-facing load balancers.
# Private subnets: EKS worker nodes and RDS — no direct internet route in.

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:only the first var.az_count names are ever
  #  used (via slice() below) — if AWS adds a new AZ to this region, the
  #  slice still takes just the first N, so there's no silent expansion
  #  in what this config actually does with the result.
  state = "available"
}

locals {
  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + var.az_count)]
}

module "vpc" {
  #checkov:skip=CKV_TF_1:pinned to a semver constraint against the
  #  official terraform-aws-modules registry module, not an arbitrary git
  #  source — the Terraform Registry itself content-addresses and
  #  checksums each published version, which is what commit-hash pinning
  #  exists to approximate for a raw git source. Trading that for easy
  #  patch-version updates on a widely-used, actively maintained module.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT for the whole VPC — cheaper for a dev/demo cluster
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required so the EKS/ALB controllers know which subnets to use for
  # internet-facing vs. internal load balancers, and which subnets belong
  # to this cluster.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  # The default SG/NACL/route table that come with every VPC are left wide
  # open by AWS and are easy to forget about. Lock the default SG down to
  # deny-all so nothing accidentally lands in it; every real workload gets
  # its own purpose-built security group instead (see eks.tf, rds.tf).
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # VPC Flow Logs: record all accepted/rejected traffic at the ENI level for
  # incident investigation (the AI-Ops root-cause step can correlate a
  # network deny with an alert) and for basic intrusion visibility.
  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 14
  flow_log_max_aggregation_interval               = 60
}
