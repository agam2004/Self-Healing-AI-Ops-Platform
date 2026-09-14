# backend-bootstrap.tf — S3 bucket + DynamoDB lock table for remote state
#
# Chicken-and-egg: the S3 backend config in providers.tf can't reference
# resources from this same configuration, so these are created once with
# local state, then providers.tf's `backend "s3"` block is uncommented and
# `terraform init -migrate-state` moves state into the bucket it just
# created. After that migration, these resources are managed remotely like
# everything else — this file doesn't change.

resource "aws_s3_bucket" "tf_state" {
  bucket = "aiops-terraform-state-${data.aws_caller_identity.current.account_id}"

  # State can contain sensitive values (e.g. this file's own history before
  # RDS moved its password to Secrets Manager); block any accidental
  # deletion via `terraform destroy` of an unrelated resource.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled" # recover a previous state if a bad apply corrupts it
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "aiops-terraform-lock"
  billing_mode = "PAY_PER_REQUEST" # a few writes a day at most — on-demand is cheapest
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
