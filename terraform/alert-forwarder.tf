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

        container {
          name    = "forwarder"
          image   = "public.ecr.aws/docker/library/python:3.12-slim"
          command = ["sh", "-c", "pip install --quiet --no-cache-dir boto3 && python /app/forwarder.py"]

          env {
            name  = "LAMBDA_FUNCTION_NAME"
            value = aws_lambda_function.root_cause_responder.function_name
          }
          env {
            name  = "AWS_REGION"
            value = var.region
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
