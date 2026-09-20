# observability.tf — Stage 3: kube-prometheus-stack + the HighErrorRate
# SLO rule that closes the loop into the AI-Ops Lambda.
#
# No persistent volumes are requested anywhere in these values — Prometheus
# and Grafana fall back to emptyDir, which avoids needing the EBS CSI
# driver (not installed on this cluster). Fine for a demo; data doesn't
# survive a pod restart, which is an explicit, deliberate trade-off, not
# an oversight.

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "62.7.0"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          # Pick up ServiceMonitors/PrometheusRules/Probes cluster-wide,
          # not just ones carrying this release's own labels — one less
          # label-matching footgun for a small demo cluster.
          serviceMonitorSelectorNilUsesHelmValues = false
          ruleSelectorNilUsesHelmValues           = false
          probeSelectorNilUsesHelmValues          = false
        }
      }

      alertmanager = {
        alertmanagerSpec = {
          resources = {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
        }
        config = {
          global = {}
          # Default receiver is a no-op — kube-prometheus-stack ships a
          # standing "Watchdog" alert (always firing, proves the pipeline
          # is alive) plus other bundled alerts; without this split, every
          # one of them would also hit the Lambda/Bedrock on a 10m repeat,
          # not just the one alert we actually want to respond to.
          route = {
            receiver       = "null"
            group_by       = ["alertname"]
            group_wait     = "10s"
            group_interval = "30s"
            routes = [
              {
                receiver        = "aiops-webhook"
                matchers        = ["alertname = \"HighErrorRate\""]
                repeat_interval = "10m"
              }
            ]
          }
          receivers = [
            { name = "null" },
            {
              name = "aiops-webhook"
              webhook_configs = [
                {
                  # Same-cluster DNS — this never leaves the pod network.
                  url           = "http://alert-forwarder.${var.remediation_namespace}.svc.cluster.local:8080/webhook"
                  send_resolved = false
                }
              ]
            }
          ]
        }
      }

      grafana = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # The SLO rule from the roadmap: >5% request-level failure for 5
      # minutes. Driven by blackbox-exporter's probe of aiops-app (see
      # blackbox-exporter.tf + the Probe resource below), because that's
      # what actually observes what Chaos Mesh's HTTPChaos injects.
      additionalPrometheusRulesMap = {
        aiops-rules = {
          groups = [
            {
              name = "aiops"
              rules = [
                {
                  alert = "HighErrorRate"
                  expr  = "probe_success{job=\"aiops-app\"} == 0"
                  # Quoted, not bare: `for` is a reserved word in HCL's
                  # own grammar (for-expressions), and Checkov's bundled
                  # hcl2 parser — a separate, simpler implementation than
                  # Terraform's own — chokes on it as an unquoted map key
                  # even though real `terraform validate` accepts it fine.
                  "for"  = "1m"
                  labels = { severity = "critical", namespace = "default", deployment = "aiops-app" }
                  annotations = {
                    summary     = "aiops-app is failing its HTTP health probe"
                    description = "blackbox-exporter's probe of aiops-app has been failing for over 1 minute — treated as a high error rate."
                  }
                }
              ]
            }
          ]
        }
      }
    })
  ]
}

# Tells Prometheus Operator to scrape blackbox-exporter's /probe endpoint
# against aiops-app's Service — the "measure what the client sees"
# mechanism this whole alert depends on.
resource "kubernetes_manifest" "aiops_app_probe" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "Probe"
    metadata = {
      name      = "aiops-app"
      namespace = "monitoring"
    }
    spec = {
      jobName  = "aiops-app"
      interval = "15s"
      module   = "http_2xx"
      prober = {
        url = "blackbox-exporter.blackbox.svc.cluster.local:9115"
      }
      targets = {
        staticConfig = {
          static = ["http://aiops-app.default.svc.cluster.local/"]
        }
      }
    }
  }

  depends_on = [helm_release.kube_prometheus_stack, kubernetes_service_v1.blackbox_exporter]
}
