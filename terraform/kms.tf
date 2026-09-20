# kms.tf — customer-managed keys for encryption at rest
#
# Using our own KMS keys (rather than the AWS-managed defaults) means we
# control and can audit the key policy, rotation, and — if this were ever
# compromised — revocation, independently for each data class. Deliberately
# three keys, not one-per-resource: every additional CMK sits in a mandatory
# 7-day "pending deletion" window (still lightly billed) after every
# `terraform destroy`, so on a project torn down between sessions, key count
# is a real, if small, recurring cost — grouped by data class, not maximized.
#
# Every key gets an explicit policy (not just the default AWS-managed one)
# so IAM alone, not an implicit KMS default, decides who can use it —
# CKV2_AWS_64 flags a key with no explicit policy for exactly this reason.

data "aws_iam_policy_document" "kms_default" {
  #checkov:skip=CKV_AWS_109:this IS the standard AWS default KMS key
  #  policy pattern, not a broadened grant — every AWS-created key ships
  #  with exactly this "account root gets kms:* on *" statement, because
  #  its purpose is to delegate all real authorization to IAM instead of
  #  the key policy. Removing it doesn't add a constraint; it risks
  #  permanently locking the account out of its own key if an IAM policy
  #  is ever misconfigured — AWS's own documented reason for including it.
  #checkov:skip=CKV_AWS_111:same statement, same reasoning as CKV_AWS_109.
  #checkov:skip=CKV_AWS_356:"*" here is the key's own resource ("this
  #  key"), which is how AWS key policies are written — a key policy
  #  scopes access to itself, not to an arbitrary other resource, so
  #  there's nothing narrower to constrain it to.
  statement {
    sid       = "AccountRootFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "eks" {
  description             = "Encrypts EKS Kubernetes Secrets (envelope encryption)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_default.json
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name_prefix}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_kms_key" "rds" {
  description             = "Encrypts RDS storage, automated backups, and the DB master-credential secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_default.json
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# CloudWatch Logs needs its own explicit grant on top of the account-root
# statement — a log group encrypted with a CMK is created via the logs
# service principal, not directly by whichever IAM identity ran
# `terraform apply`, so without this statement log group creation fails
# with an access-denied even though the calling user has kms:* via root.
data "aws_iam_policy_document" "kms_lambda" {
  #checkov:skip=CKV_AWS_109:standard AWS default key-policy statement —
  #  see kms_default's identical statement above for the full reasoning.
  #checkov:skip=CKV_AWS_111:same statement, same reasoning.
  #checkov:skip=CKV_AWS_356:a key policy's "*" is scoped to the key
  #  itself, not an arbitrary resource — see kms_default above.
  statement {
    sid       = "AccountRootFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "CloudWatchLogsUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-root-cause-responder"]
    }
  }
}

resource "aws_kms_key" "lambda" {
  description             = "Encrypts the root-cause responder's log group, environment variables, and Slack webhook secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_lambda.json
}

resource "aws_kms_alias" "lambda" {
  name          = "alias/${var.name_prefix}-lambda"
  target_key_id = aws_kms_key.lambda.key_id
}
