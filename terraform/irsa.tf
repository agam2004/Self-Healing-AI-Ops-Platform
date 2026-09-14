# irsa.tf — IAM Roles for Service Accounts (IRSA) for the in-cluster alert
# forwarder (see alert-forwarder.tf), which receives Alertmanager's webhook
# and hands it to the AI-Ops Lambda.
#
# Why IRSA instead of sharing the node's instance role: without it, every
# pod on a node inherits whatever AWS permissions that node has — a
# compromised or buggy pod in any namespace could invoke arbitrary Lambdas
# or worse. IRSA maps one Kubernetes ServiceAccount to one IAM role via the
# cluster's OIDC provider, so only pods running as
# system:serviceaccount:aiops:remediation-controller can assume this role,
# and the role itself only grants exactly what the forwarder needs:
# invoking one specific Lambda function, nothing else.

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

# The forwarder does exactly one thing: hand the Alertmanager payload to
# the root-cause Lambda. It has no Bedrock/Secrets Manager/K8s-write
# access of its own — if this pod were compromised, the blast radius is
# "can invoke one Lambda function," not "can read every secret."
data "aws_iam_policy_document" "remediation_controller_permissions" {
  statement {
    sid       = "InvokeRootCauseLambda"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.root_cause_responder.arn]
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
