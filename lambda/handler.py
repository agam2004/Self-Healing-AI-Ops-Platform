"""AI-Ops root-cause responder.

Triggered by an Alertmanager webhook (POST body shaped per Alertmanager's
webhook_config: https://prometheus.io/docs/alerting/latest/configuration/#webhook_config).
For each firing alert: ask Bedrock (Claude) for a short root-cause summary
given the alert's labels/annotations, then post that summary to Slack.

Deliberately does not take any remediation action (restart/scale a pod) —
that's a separate, RBAC-scoped step (see terraform/irsa.tf) exercised
against Chaos Mesh once that stage is built. This function's blast radius
is "reads an alert, calls two APIs" — nothing it does can make an incident
worse.
"""

import json
import os
import urllib.request
import boto3

BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
SLACK_WEBHOOK_SECRET_ARN = os.environ.get("SLACK_WEBHOOK_SECRET_ARN")

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


def _post_to_slack(alert: dict, summary: str) -> None:
    webhook_url = _slack_webhook_url()
    alertname = alert.get("labels", {}).get("alertname", "unknown")

    if not webhook_url:
        print(f"[no Slack webhook configured] {alertname}: {summary}")
        return

    payload = json.dumps({"text": f"*{alertname}*\n{summary}"}).encode()
    req = urllib.request.Request(
        webhook_url, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        resp.read()


def handler(event, context):
    body = event.get("body", event) if isinstance(event, dict) else event
    if isinstance(body, str):
        body = json.loads(body)

    alerts = body.get("alerts", [])
    results = []

    for alert in alerts:
        if alert.get("status") != "firing":
            continue
        summary = _root_cause_summary(alert)
        _post_to_slack(alert, summary)
        results.append({"alertname": alert.get("labels", {}).get("alertname"), "summary": summary})

    return {"statusCode": 200, "body": json.dumps({"processed": results})}
