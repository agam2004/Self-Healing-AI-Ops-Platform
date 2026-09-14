# outputs.tf

output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC — put this in the AWS_ROLE_ARN repo secret"
  value       = aws_iam_role.github_actions.arn
}

output "ecr_repo_url" {
  description = "URL of the ECR repository for the app container image"
  value       = aws_ecr_repository.aiops_app.repository_url
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster (pass to `aws eks update-kubeconfig`)"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS control plane API endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials (username/password/host/port/dbname)"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_endpoint" {
  description = "RDS connection endpoint (host:port) — not sensitive on its own, credentials live in Secrets Manager"
  value       = aws_db_instance.this.endpoint
}
