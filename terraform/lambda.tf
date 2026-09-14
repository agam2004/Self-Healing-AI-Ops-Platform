# lambda.tf — Stage 4: AI-Ops root-cause responder + Stage 5 remediation
#
# Triggered by the in-cluster alert-forwarder (alert-forwarder.tf), which
# Alertmanager's webhook_config posts to. No public endpoint: the forwarder
# calls lambda:InvokeFunction directly over the AWS API using its own IRSA
# credentials, so nothing about this function is reachable from the
# internet. For manual testing, invoke directly:
#   aws lambda invoke --function-name aiops-root-cause-responder \
#     --payload file://lambda/sample-alert.json out.json
#
# Remediation: after the Bedrock summary + Slack post, the function
# restarts the Deployment named in the alert's labels (namespace/
# deployment) via the Kubernetes API, authenticated the same way kubectl
# is (a presigned STS token, see lambda/handler.py's get_k8s_token). Its
# IAM role is granted edit access scoped to one namespace via an EKS
# access entry below — it cannot reach any other namespace, and has no
# AWS-level EKS/EC2 permissions at all (the K8s API is the only path).

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/../lambda/handler.zip"
}

resource "aws_secretsmanager_secret" "slack_webhook" {
  name                    = "${var.name_prefix}/lambda/slack-webhook-url"
  description             = "Slack incoming webhook URL the AI-Ops Lambda posts root-cause summaries to"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id     = aws_secretsmanager_secret.slack_webhook.id
  secret_string = "https://hooks.slack.com/REPLACE_ME"

  # Terraform generated the placeholder above; once a real webhook is
  # created in Slack, update the value out-of-band (console or
  # `aws secretsmanager put-secret-value`) and ignore it here so a
  # `terraform apply` doesn't silently revert it back to the placeholder.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-root-cause-responder"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${var.name_prefix}-root-cause-responder:*"]
  }

  statement {
    # Active Anthropic models on Bedrock are invoked via a cross-region
    # inference profile, which itself dispatches to a foundation-model ARN
    # in whichever underlying region serves the request — both ARN shapes
    # need to be allowed.
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
    ]
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid       = "ReadSlackWebhook"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_webhook.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name_prefix}-root-cause-responder-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# Required for Lambda to create/attach the ENI that puts it inside the
# VPC's private subnets (see aws_lambda_function.root_cause_responder's
# vpc_config below) — this is the standard AWS-managed policy for exactly
# that, not a custom grant.
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-root-cause-responder"
  retention_in_days = 14
}

# The Lambda runs inside the VPC so it reaches the EKS API over its
# private endpoint (always enabled) rather than the public one — the same
# CIDR-restricted public endpoint that blocks GitHub Actions blocks any
# AWS-managed compute with a non-fixed IP, Lambda included. Being in-VPC
# side-steps that instead of widening the CIDR. Bedrock/Secrets
# Manager/CloudWatch Logs are still reachable through the VPC's existing
# NAT gateway (vpc.tf) — no VPC interface endpoints needed for this scale.
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Root-cause responder Lambda - outbound only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS to AWS APIs (via NAT) and the EKS private endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "eks_cluster_from_lambda" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = aws_security_group.lambda.id
  description              = "EKS API from the root-cause responder Lambda"
}

resource "aws_lambda_function" "root_cause_responder" {
  function_name = "${var.name_prefix}-root-cause-responder"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      BEDROCK_MODEL_ID         = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
      EKS_CLUSTER_NAME         = module.eks.cluster_name
      EKS_CLUSTER_ENDPOINT     = module.eks.cluster_endpoint
      EKS_CLUSTER_CA           = module.eks.cluster_certificate_authority_data
      REMEDIATION_ENABLED      = "true"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda, aws_iam_role_policy_attachment.lambda_vpc_access]
}

# Same shape as the CI role's access entry (oidc-cicd.tf) — edit access
# scoped to the default namespace only, not cluster-admin. This is what
# lets the Lambda restart aiops-app's Deployment without being able to
# touch kube-system or any other namespace.
resource "aws_eks_access_entry" "lambda" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.lambda.arn
}

resource "aws_eks_access_policy_association" "lambda_edit" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.lambda.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }
}
