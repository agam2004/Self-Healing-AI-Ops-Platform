# lambda.tf — Stage 4: AI-Ops root-cause responder
#
# Not wired to a real Alertmanager webhook yet (Stage 3/observability isn't
# built), so there's no public endpoint here — test by invoking directly:
#   aws lambda invoke --function-name aiops-root-cause-responder \
#     --payload file://lambda/sample-alert.json out.json
# Once kube-prometheus-stack exists, point Alertmanager's webhook_config at
# a Lambda Function URL or API Gateway added here.

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

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-root-cause-responder"
  retention_in_days = 14
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

  environment {
    variables = {
      BEDROCK_MODEL_ID         = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}
