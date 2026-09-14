# oidc-cicd.tf — GitHub Actions OIDC provider + IAM role for CI/CD
#
# Stage 2: the EKS cluster now exists (eks.tf), so this role also gets
# eks:DescribeCluster (needed for `aws eks update-kubeconfig`) plus a scoped
# EKS access entry so `kubectl set image` from the workflow can actually
# reach the cluster — limited to editing Deployments, not cluster-admin.

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
      # Matches repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/<branch> —
      # see the github_owner_id/github_repo_id variables for why.
      values = ["repo:*@${var.github_owner_id}/*@${var.github_repo_id}:ref:refs/heads/${var.github_branch}"]
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

  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [module.eks.cluster_arn]
  }
}

# Grant the CI role just enough Kubernetes RBAC to roll a Deployment image —
# not cluster-admin. EKS access entries replace the old aws-auth ConfigMap
# approach and are auditable as plain Terraform-managed resources.
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions.arn
}

resource "aws_eks_access_policy_association" "github_actions_edit" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
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
