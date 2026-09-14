# irsa.tf — IAM Roles for Service Accounts (IRSA) scaffold for the AI-Ops
# remediation controller (Stage 4/5 of the roadmap)
#
# Why IRSA instead of sharing the node's instance role: without it, every
# pod on a node inherits whatever AWS permissions that node has — a
# compromised or buggy pod in any namespace could call Bedrock, read every
# secret, etc. IRSA maps one Kubernetes ServiceAccount to one IAM role via
# the cluster's OIDC provider, so only pods running as
# system:serviceaccount:aiops:remediation-controller can assume this role,
# and the role itself only grants exactly what that controller needs.
#
# The controller (Lambda-invoked or in-cluster) isn't built yet — this
# wires the trust relationship and a least-privilege policy ahead of it so
# the K8s-side (ServiceAccount + annotation) is a two-line addition later:
#   eks.amazonaws.com/role-arn: <aws_iam_role.remediation_controller.arn>

variable "remediation_namespace" {
  description = "Kubernetes namespace the AI-Ops remediation controller runs in"
  type        = string
  default     = "aiops"
}

variable "remediation_service_account" {
  description = "Kubernetes ServiceAccount name the remediation controller runs as"
  type        = string
  default     = "remediation-controller"
}

data "aws_iam_policy_document" "remediation_controller_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to one namespace + one ServiceAccount name — not a wildcard
    # across the cluster, so no other workload can assume this role even
    # if it discovers the role ARN.
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.remediation_namespace}:${var.remediation_service_account}"]
    }
  }
}

resource "aws_iam_role" "remediation_controller" {
  name               = "${var.name_prefix}-remediation-controller"
  assume_role_policy = data.aws_iam_policy_document.remediation_controller_trust.json
}

# Least-privilege for what root-cause-analysis + remediation actually need:
#  - Invoke Bedrock for the LLM root-cause call.
#  - Read the RDS secret only if remediation needs to check DB health
#    directly (e.g. run a read-only diagnostic query) — nothing else in
#    Secrets Manager.
# Deliberately does NOT include any EKS/K8s write permissions here: pod
# restart/scale actions go through the Kubernetes API using the
# controller's RBAC role (a K8s-native concern), not AWS IAM — keeping the
# blast radius of a leaked AWS credential separate from cluster-admin
# actions.
data "aws_iam_policy_document" "remediation_controller_permissions" {
  statement {
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/*"]
  }

  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_policy" "remediation_controller_permissions" {
  name   = "${var.name_prefix}-remediation-controller-policy"
  policy = data.aws_iam_policy_document.remediation_controller_permissions.json
}

resource "aws_iam_role_policy_attachment" "remediation_controller" {
  role       = aws_iam_role.remediation_controller.name
  policy_arn = aws_iam_policy.remediation_controller_permissions.arn
}
