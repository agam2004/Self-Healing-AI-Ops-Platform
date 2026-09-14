# kms.tf — customer-managed keys for encryption at rest
#
# Using our own KMS keys (rather than the AWS-managed defaults) means we
# control and can audit the key policy, rotation, and — if this were ever
# compromised — revocation, independently for each data class.

resource "aws_kms_key" "eks" {
  description             = "Encrypts EKS Kubernetes Secrets (envelope encryption)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name_prefix}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_kms_key" "rds" {
  description             = "Encrypts RDS storage and automated backups"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}
