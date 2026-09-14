# blackbox-exporter.tf — the thing that actually observes aiops-app's HTTP
# error rate from the outside.
#
# Why blackbox-exporter instead of instrumenting app.py directly: Chaos
# Mesh's HTTPChaos (used in the chaos experiment) injects faults by
# rewriting responses in transit, between the app and its caller — the app
# itself never sees the mutated status code, so app-side metrics wouldn't
# reflect the injected failure. blackbox-exporter probes the Service from
# outside, the same vantage point a real client has, so it sees exactly
# what Chaos Mesh injects. This is the standard pattern for this exact
# scenario (see docs/disaster-recovery.md's DR section for the same
# "measure what the client sees" principle applied to failover).

resource "kubernetes_namespace_v1" "blackbox" {
  metadata {
    name = "blackbox"
  }
}

resource "kubernetes_deployment_v1" "blackbox_exporter" {
  metadata {
    name      = "blackbox-exporter"
    namespace = kubernetes_namespace_v1.blackbox.metadata[0].name
    labels    = { app = "blackbox-exporter" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "blackbox-exporter" }
    }

    template {
      metadata {
        labels = { app = "blackbox-exporter" }
      }

      spec {
        container {
          name  = "blackbox-exporter"
          image = "prom/blackbox-exporter:v0.25.0" # ships a default http_2xx module — no config needed for this demo

          port {
            name           = "http"
            container_port = 9115
          }

          resources {
            requests = { cpu = "25m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 9115
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "blackbox_exporter" {
  metadata {
    name      = "blackbox-exporter"
    namespace = kubernetes_namespace_v1.blackbox.metadata[0].name
  }

  spec {
    selector = { app = "blackbox-exporter" }
    port {
      name        = "http"
      port        = 9115
      target_port = 9115
    }
  }
}
