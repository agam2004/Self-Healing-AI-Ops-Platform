# chaos-mesh.tf — Stage 5: fault injection to prove the AI-Ops loop
#
# Only the platform is installed here. The actual experiment
# (k8s/chaos-http-500.yaml, an HTTPChaos that rewrites aiops-app's
# responses to 500) is deliberately NOT applied by Terraform — chaos
# experiments are things a human (or a GameDay runbook) triggers on
# purpose, not standing infrastructure. Run it with:
#   kubectl apply -f k8s/chaos-http-500.yaml
#   kubectl delete -f k8s/chaos-http-500.yaml   # to stop it early

resource "helm_release" "chaos_mesh" {
  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  version          = "2.6.3"
  namespace        = "chaos-mesh"
  create_namespace = true
  timeout          = 600

  values = [
    yamlencode({
      chaosDaemon = {
        runtime    = "containerd"
        socketPath = "/run/containerd/containerd.sock" # matches the AL2023 EKS-optimized AMI these nodes run
      }
      dashboard = {
        create = false # skip the UI — experiments are applied via kubectl for this demo
      }
      controllerManager = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
        }
      }
    })
  ]
}

# Chaos Mesh has its own RBAC-style auth layer (a validating admission
# webhook, independent of standard Kubernetes RBAC) that denies every
# identity by default until explicitly bound — even cluster-admin. This
# grants exactly the operator applying this Terraform (whoever that is —
# data.aws_caller_identity.current, not a hardcoded value) permission to
# manage chaos-mesh.org resources in the default namespace, where
# k8s/chaos-http-500.yaml targets aiops-app. Scoped to one namespace, one
# API group, one identity — not a broader grant.
resource "kubernetes_role_v1" "chaos_operator" {
  metadata {
    name      = "aiops-chaos-operator"
    namespace = "default"
  }

  rule {
    api_groups = ["chaos-mesh.org"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "chaos_operator" {
  metadata {
    name      = "aiops-chaos-operator-binding"
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.chaos_operator.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = data.aws_caller_identity.current.arn
    api_group = "rbac.authorization.k8s.io"
  }
}
