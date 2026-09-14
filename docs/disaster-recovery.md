# Disaster Recovery Strategy

This is a design decision, not built infrastructure — cross-region
resources cost money to keep warm, and this is a demo/portfolio project.
Documenting the plan is the deliverable; the trigger to actually build it is
a real production workload.

## Current single-region posture (us-east-1)

| Component | Recovery mechanism today |
|---|---|
| Terraform state | S3 versioned bucket, own recovery via version history |
| RDS | Automated backups, 7-day retention, encrypted, single-AZ |
| EKS | Stateless control plane; workloads redeployed from Git via CI/CD |
| ECR images | Immutable tags, `scan_on_push` |

Single-AZ RDS and single-NAT-gateway VPC are deliberate cost/complexity
trade-offs for a demo cluster — see `vpc.tf`/`rds.tf` comments. The
"scale it up" path for each is one flag flip, not a redesign:
`multi_az = true` on the DB instance, `single_nat_gateway = false` (one NAT
per AZ) on the VPC module.

## RTO/RPO targets (as if this were production)

- **RPO (data loss tolerance):** 5 minutes for RDS via cross-region
  automated snapshot copy (see below); Terraform state and container images
  are already durable (S3 versioning, ECR) so their RPO is effectively zero.
- **RTO (time to restore service):** under 1 hour for a full region
  failure, driven almost entirely by EKS + node group provisioning time in
  the DR region — everything else (Terraform apply, RDS snapshot restore,
  CI/CD redeploy) is faster than that.

## What a real cross-region DR build would add

1. **RDS**: enable `copy_tags_to_snapshot` (already on) plus cross-region
   automated backup replication (`aws_db_instance_automated_backups_replication`
   or a scheduled `aws_rds_cluster_snapshot` copy to a second region). On
   failover, restore the latest replicated snapshot into a new `aws_db_instance`
   in the DR region — accept the replication lag as the RPO.
2. **Terraform state**: already region-agnostic (S3 is a global namespace);
   the DR region's stack reads the same state, or — cleaner — a fully
   separate `envs/dr` root module with its own state, so a DR deploy can't
   accidentally touch primary-region resources.
3. **EKS**: DR is "redeploy from Git", not "keep a warm standby cluster" —
   cheaper and matches the GitOps story already in place. A `terraform apply`
   of the same module set with `region = "us-west-2"` stands up a cluster;
   the CI/CD workflow's `kubectl set image` step (already OIDC-authenticated,
   not tied to a region) redeploys the app against it.
4. **ECR**: cross-region replication (`aws_ecr_replication_configuration`)
   so the DR region's cluster isn't blocked on pulling images across
   regions during an actual outage.
5. **DNS/traffic**: Route 53 with a failover routing policy and health
   checks against the app's `/health` endpoint, so failover is automatic
   rather than a manual DNS change.
6. **Runbook**: the actual failover procedure (who decides to fail over,
   how the RDS snapshot restore is triggered, how DNS cutover is verified)
   documented and — ideally — exercised via a GameDay, the same way
   Chaos Mesh (Stage 5) exercises the auto-remediation loop in-region.

## Why this wasn't built now

Every item above is either an idle-cost item (a warm standby cluster, a
second NAT gateway per region) or requires a second full region's worth of
VPC/EKS/RDS to demo end-to-end. For an interview conversation, the design
above — with the concrete Terraform resources named — demonstrates the same
understanding as having built it, without doubling this project's AWS bill
for infrastructure that would sit idle.
