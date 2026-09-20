# gatekeeper.tf — installs OPA Gatekeeper only. The policies themselves
# (../gatekeeper-policies.yaml) are applied via plain `kubectl apply`, not
# Terraform — same reasoning as chaos-mesh.tf's HTTPChaos experiment:
# Gatekeeper's ConstraintTemplate CRDs don't exist until this Helm release
# installs them, so a kubernetes_manifest for a Constraint in this same
# apply would hit the identical CRD chicken-and-egg problem observability.tf
# already ran into with the Probe resource — apply this first, then the
# policies as a clearly separate, deliberate step.

resource "helm_release" "gatekeeper" {
  name             = "gatekeeper"
  repository       = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart            = "gatekeeper"
  version          = "3.17.1"
  namespace        = "gatekeeper-system"
  create_namespace = true
  timeout          = 300

  values = [
    yamlencode({
      controllerManager = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      audit = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
        }
      }
      # Fail closed: if the admission webhook itself is unreachable, the
      # API server rejects the request rather than silently admitting it.
      # Right for a demo cluster where nothing else depends on the API
      # server staying available no matter what; a real production
      # cluster would weigh this against an outage in Gatekeeper blocking
      # all deploys.
      validatingWebhookFailurePolicy = "Fail"
      emitAdmissionEvents            = true
    })
  ]
}
