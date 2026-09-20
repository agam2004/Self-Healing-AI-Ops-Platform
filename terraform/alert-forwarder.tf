# alert-forwarder.tf — the in-cluster hop between Alertmanager and the
# AI-Ops Lambda.
#
# Why not point Alertmanager straight at the Lambda? Alertmanager's
# webhook_config does a plain HTTP POST — it can't produce the SigV4
# signature a Lambda Function URL or API Gateway would require for IAM
# auth, and an unauthenticated public URL that triggers a Bedrock call is
# a cost/abuse surface not worth opening. This forwarder is a few lines of
# Python running inside the cluster: it accepts the plain webhook POST and
# calls lambda:InvokeFunction using its own IRSA credentials (irsa.tf) —
# IAM-authenticated, with no public endpoint anywhere in the path.

resource "kubernetes_namespace_v1" "aiops" {
  metadata {
    name = var.remediation_namespace
  }
}

resource "kubernetes_service_account_v1" "alert_forwarder" {
  metadata {
    name      = var.remediation_service_account
    namespace = kubernetes_namespace_v1.aiops.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.remediation_controller.arn
    }
  }
}

resource "kubernetes_config_map_v1" "alert_forwarder_src" {
  metadata {
    name      = "alert-forwarder-src"
    namespace = kubernetes_namespace_v1.aiops.metadata[0].name
  }

  data = {
    "forwarder.py" = file("${path.module}/../k8s-src/alert_forwarder.py")
  }
}

resource "kubernetes_deployment_v1" "alert_forwarder" {
  metadata {
    name      = "alert-forwarder"
    namespace = kubernetes_namespace_v1.aiops.metadata[0].name
    labels    = { app = "alert-forwarder" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "alert-forwarder" }
    }

    template {
      metadata {
        labels = { app = "alert-forwarder" }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.alert_forwarder.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        #checkov:skip=CKV_K8S_43:public.ecr.aws/docker/library/python is a
        #  floating upstream base image, not this project's own IMMUTABLE
        #  ECR repo — pinning to a digest here means hand-tracking
        #  upstream Python patch releases for a helper container whose
        #  whole job is "run 40 lines of stdlib http.server," a
        #  maintenance cost the security gain doesn't justify at this
        #  scale. aiops-app's own image (k8s/deployment.yaml), the one
        #  that matters, is already tag-pinned against an IMMUTABLE repo.
        #checkov:skip=CKV_K8S_22:this container's own startup command
        #  (`pip install --user boto3`) genuinely needs to write to the
        #  filesystem — it installs its one dependency at container start
        #  rather than baking a custom image for a 40-line script. The
        #  trade-off is real: read-only-root-fs for a build step, or a
        #  proper Dockerfile + ECR push for a helper this small. Chose the
        #  simpler pipeline; runAsNonRoot + all-capabilities-dropped still
        #  hold even with a writable root filesystem.
        container {
          name  = "forwarder"
          image = "public.ecr.aws/docker/library/python:3.12-slim"
          # --user (not a system-wide install) + HOME=/tmp: this
          # container runs as a non-root UID with no writable system
          # site-packages directory, so boto3 has to land somewhere that
          # UID can actually write to.
          command           = ["sh", "-c", "pip install --user --quiet --no-cache-dir boto3 && python /app/forwarder.py"]
          image_pull_policy = "Always"

          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "LAMBDA_FUNCTION_NAME"
            value = aws_lambda_function.root_cause_responder.function_name
          }
          env {
            name  = "AWS_REGION"
            value = var.region
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          port {
            container_port = 8080
          }

          volume_mount {
            name       = "src"
            mount_path = "/app"
          }

          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 20
            period_seconds        = 15
          }
        }

        volume {
          name = "src"
          config_map {
            name = kubernetes_config_map_v1.alert_forwarder_src.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "alert_forwarder" {
  metadata {
    name      = "alert-forwarder"
    namespace = kubernetes_namespace_v1.aiops.metadata[0].name
  }

  spec {
    selector = { app = "alert-forwarder" }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
