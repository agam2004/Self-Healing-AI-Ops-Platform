# oidc-cicd.tf — GitHub Actions OIDC provider + IAM role for CI/CD
#
# Stage 1: only ECR push permissions (no EKS yet — the cluster doesn't exist
# until Stage 2). Once the EKS module is added, extend
# `deploy_permissions` with an EKSDescribe statement and add an
# aws_eks_access_entry / aws_eks_access_policy_association for this role,
# so `kubectl` from the workflow can actually reach the cluster.

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# --- Trust policy: only this repo, only this branch, can assume the role ---
data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-aiops-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# --- Permissions: push images to ECR ---
data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.aiops_app.arn]
  }
}

resource "aws_iam_policy" "deploy_permissions" {
  name   = "github-actions-aiops-deploy-policy"
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.deploy_permissions.arn
}

# --- ECR repository ---
resource "aws_ecr_repository" "aiops_app" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
