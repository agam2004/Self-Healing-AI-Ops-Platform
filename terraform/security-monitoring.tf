# security-monitoring.tf — account-level threat detection and posture
# management, so drift/compromise has a real detection story, not just
# preventive controls.
#
# GuardDuty: continuous threat detection over CloudTrail/VPC Flow
# Logs/DNS logs, plus EKS Runtime Monitoring (agent-based, watches
# in-cluster process/file/network activity) and Malware Protection for
# EC2/EBS (the worker nodes). This is what would actually flag "a pod is
# making a C2 callback" or "a node's EBS volume has malware on it" — VPC
# Flow Logs (vpc.tf) alone only tell you traffic happened, not that it's
# malicious.
#
# Security Hub: aggregates GuardDuty findings plus continuous checks
# against the AWS Foundational Security Best Practices standard (e.g. "is
# this S3 bucket public", "is this RDS instance encrypted") — a running
# compliance score, not just point-in-time findings.

resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:this whole file is written and validated but
  #  deliberately never applied — GuardDuty/Security Hub run continuously
  #  and bill for it, which doesn't fit a project that's torn down
  #  between sessions. Documented as a considered, not missing, decision.
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }
}

resource "aws_guardduty_detector_feature" "eks_runtime_monitoring" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED" # let GuardDuty manage the runtime-monitoring EKS add-on itself
  }
}

resource "aws_securityhub_account" "this" {
  enable_default_standards = false # we opt into one specific standard below instead of every default one
}

resource "aws_securityhub_standards_subscription" "foundational" {
  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}
