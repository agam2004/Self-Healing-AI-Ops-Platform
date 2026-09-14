"""AI-Ops root-cause responder and remediator.

Triggered by the in-cluster alert-forwarder, which relays Alertmanager's
webhook payload (https://prometheus.io/docs/alerting/latest/configuration/#webhook_config)
via a direct lambda:InvokeFunction call (no public endpoint).

For each firing alert:
  1. Ask Bedrock (Claude) for a short root-cause summary.
  2. Post that summary to Slack.
  3. If the alert carries `namespace`/`deployment` labels and
     REMEDIATION_ENABLED is true, restart that Deployment via the
     Kubernetes API — a rolling restart, not a scale-to-zero or delete, so
     the blast radius of a wrong call is "an unnecessary rollout," not an
     outage.

Step 3 authenticates to the K8s API the same way `aws eks get-token` does:
a short-lived presigned STS GetCallerIdentity URL, base64-encoded. No
long-lived Kubernetes credential exists anywhere in this function. The
IAM role this runs as only has edit access to one namespace (see
lambda.tf's aws_eks_access_policy_association), so even a bug here can't
reach kube-system or any other workload.
"""

import base64
import datetime
import json
import os
import ssl
import urllib.request
import boto3
from botocore.signers import RequestSigner

BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
SLACK_WEBHOOK_SECRET_ARN = os.environ.get("SLACK_WEBHOOK_SECRET_ARN")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
EKS_CLUSTER_NAME = os.environ.get("EKS_CLUSTER_NAME")
EKS_CLUSTER_ENDPOINT = os.environ.get("EKS_CLUSTER_ENDPOINT")
EKS_CLUSTER_CA = os.environ.get("EKS_CLUSTER_CA")
REMEDIATION_ENABLED = os.environ.get("REMEDIATION_ENABLED", "false").lower() == "true"

_bedrock = boto3.client("bedrock-runtime")
_secrets = boto3.client("secretsmanager")

_slack_webhook_url_cache = None


def _slack_webhook_url() -> str | None:
    global _slack_webhook_url_cache
    if _slack_webhook_url_cache is not None:
        return _slack_webhook_url_cache
    if not SLACK_WEBHOOK_SECRET_ARN:
        return None
    value = _secrets.get_secret_value(SecretId=SLACK_WEBHOOK_SECRET_ARN)["SecretString"]
    _slack_webhook_url_cache = value
    return value if value.startswith("https://hooks.slack.com/") else None


def _root_cause_summary(alert: dict) -> str:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    prompt = (
        "You are an SRE assistant. An alert fired in a Kubernetes cluster. "
        "In 3-4 sentences: (1) restate what's wrong in plain language, "
        "(2) give the single most likely root cause, (3) suggest one concrete "
        "next diagnostic or remediation step. Be specific, not generic.\n\n"
        f"Alert name: {labels.get('alertname', 'unknown')}\n"
        f"Severity: {labels.get('severity', 'unknown')}\n"
        f"Labels: {json.dumps(labels)}\n"
        f"Annotations: {json.dumps(annotations)}\n"
    )

    response = _bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 400,
                "messages": [{"role": "user", "content": prompt}],
            }
        ),
    )
    body = json.loads(response["body"].read())
    return body["content"][0]["text"]


def _post_to_slack(alert: dict, summary: str, remediation_note: str) -> None:
    webhook_url = _slack_webhook_url()
    alertname = alert.get("labels", {}).get("alertname", "unknown")
    text = f"*{alertname}*\n{summary}\n\n_{remediation_note}_"

    if not webhook_url:
        print(f"[no Slack webhook configured] {alertname}: {summary} | {remediation_note}")
        return

    payload = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        webhook_url, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        resp.read()


def _k8s_token() -> str:
    """Replicates `aws eks get-token`: a presigned STS GetCallerIdentity URL,
    base64-encoded, is how EKS's IAM authenticator webhook maps an AWS
    identity to a Kubernetes user — no separate K8s credential exists."""
    session = boto3.session.Session()
    sts = session.client("sts", region_name=AWS_REGION)
    signer = RequestSigner(
        sts.meta.service_model.service_id, AWS_REGION, "sts", "v4", session.get_credentials(), session.events
    )
    params = {
        "method": "GET",
        "url": f"https://sts.{AWS_REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": {},
        "headers": {"x-k8s-aws-id": EKS_CLUSTER_NAME},
        "context": {},
    }
    signed_url = signer.generate_presigned_url(params, region_name=AWS_REGION, expires_in=60, operation_name="")
    return "k8s-aws-v1." + base64.urlsafe_b64encode(signed_url.encode()).decode().rstrip("=")


def _k8s_ssl_context() -> ssl.SSLContext:
    ca_path = "/tmp/eks-ca.crt"
    if not os.path.exists(ca_path):
        with open(ca_path, "wb") as f:
            f.write(base64.b64decode(EKS_CLUSTER_CA))
    return ssl.create_default_context(cafile=ca_path)


def _restart_deployment(namespace: str, name: str) -> str:
    if not (EKS_CLUSTER_NAME and EKS_CLUSTER_ENDPOINT and EKS_CLUSTER_CA):
        return "remediation skipped: cluster connection not configured"

    url = f"{EKS_CLUSTER_ENDPOINT}/apis/apps/v1/namespaces/{namespace}/deployments/{name}"
    patch = json.dumps(
        {
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {"aiops.dev/restartedAt": datetime.datetime.utcnow().isoformat() + "Z"}
                    }
                }
            }
        }
    ).encode()

    req = urllib.request.Request(
        url,
        data=patch,
        method="PATCH",
        headers={
            "Authorization": f"Bearer {_k8s_token()}",
            "Content-Type": "application/strategic-merge-patch+json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10, context=_k8s_ssl_context()) as resp:
            resp.read()
        return f"remediation: restarted deployment/{name} in namespace/{namespace}"
    except Exception as exc:  # noqa: BLE001 — remediation failure must never crash the summary/notify path
        return f"remediation failed for deployment/{name} in namespace/{namespace}: {exc}"


def _remediate(alert: dict) -> str:
    labels = alert.get("labels", {})
    namespace = labels.get("namespace")
    deployment = labels.get("deployment")

    if not REMEDIATION_ENABLED:
        return "remediation disabled (REMEDIATION_ENABLED=false)"
    if not (namespace and deployment):
        return "remediation skipped: alert has no namespace/deployment labels"
    return _restart_deployment(namespace, deployment)


def handler(event, context):
    body = event.get("body", event) if isinstance(event, dict) else event
    if isinstance(body, str):
        body = json.loads(body)

    alerts = body.get("alerts", [])
    results = []

    for alert in alerts:
        if alert.get("status") != "firing":
            continue

        # Root-cause analysis and remediation are independent concerns —
        # Bedrock being down (rate-limited, account not onboarded, model
        # deprecated, whatever) must never block restarting a broken
        # deployment, and a remediation bug must never suppress the
        # summary. Each is isolated so one failing degrades, not cascades.
        try:
            summary = _root_cause_summary(alert)
        except Exception as exc:  # noqa: BLE001
            summary = f"(root-cause analysis unavailable: {exc})"

        remediation_note = _remediate(alert)
        _post_to_slack(alert, summary, remediation_note)
        results.append(
            {
                "alertname": alert.get("labels", {}).get("alertname"),
                "summary": summary,
                "remediation": remediation_note,
            }
        )

    return {"statusCode": 200, "body": json.dumps({"processed": results})}
