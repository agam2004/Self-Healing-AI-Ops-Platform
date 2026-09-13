# outputs.tf

output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC — put this in the AWS_ROLE_ARN repo secret"
  value       = aws_iam_role.github_actions.arn
}

output "ecr_repo_url" {
  description = "URL of the ECR repository for the app container image"
  value       = aws_ecr_repository.aiops_app.repository_url
}
