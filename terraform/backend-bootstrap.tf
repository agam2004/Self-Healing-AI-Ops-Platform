# backend-bootstrap.tf — S3 bucket + DynamoDB lock table for remote state
#
# Chicken-and-egg: the S3 backend config in providers.tf can't reference
# resources from this same configuration, so these are created once with
# local state, then providers.tf's `backend "s3"` block is uncommented and
# `terraform init -migrate-state` moves state into the bucket it just
# created. After that migration, these resources are managed remotely like
# everything else — this file doesn't change.

resource "aws_s3_bucket" "tf_state" {
  #checkov:skip=CKV_AWS_18:access logging needs a second bucket to receive
  #  logs nobody reviews for a single-user personal-account state bucket —
  #  CloudTrail already records every API call against this bucket at the
  #  account level, which is what would actually get looked at in a real
  #  incident, without paying to duplicate that into per-request logs too.
  #checkov:skip=CKV_AWS_144:cross-region replication protects against a
  #  regional S3 outage — versioning already protects against the actual
  #  realistic risk here (a bad apply corrupting state); this project has
  #  no DR requirement that justifies paying to store a second copy of a
  #  Terraform state file in a second region.
  #checkov:skip=CKV2_AWS_62:event notifications need a destination
  #  (SNS/SQS/Lambda) nothing in this project subscribes to — state
  #  changes are already visible via S3 versioning and this session's own
  #  terraform apply/destroy logs.
  bucket = "aiops-terraform-state-${data.aws_caller_identity.current.account_id}"

  # State can contain sensitive values (e.g. this file's own history before
  # RDS moved its password to Secrets Manager); block any accidental
  # deletion via `terraform destroy` of an unrelated resource.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning (below) means every state write keeps its predecessor around
# forever by default; this bounds that growth instead of paying to store
# an ever-growing history of a file that gets rewritten every apply.
resource "aws_s3_bucket_lifecycle_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # A separate, real gap this rule doesn't otherwise cover: an
    # interrupted multipart upload (network blip mid state-push, the
    # exact failure mode this session hit more than once) leaves orphaned
    # parts that never show up as a bucket "object" and so never expire
    # on their own.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
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
  #checkov:skip=CKV_AWS_119:AWS-owned default encryption already covers
  #  this table at rest; the table holds nothing but a lock ID and a
  #  timestamp while an apply is running — there's no sensitive content a
  #  customer-managed key would meaningfully protect here.
  name         = "aiops-terraform-lock"
  billing_mode = "PAY_PER_REQUEST" # a few writes a day at most — on-demand is cheapest
  hash_key     = "LockID"

  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = "LockID"
    type = "S"
  }
}
