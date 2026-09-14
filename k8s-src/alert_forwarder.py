"""Alertmanager -> AI-Ops Lambda bridge.

Alertmanager's webhook_config can only do a plain HTTP POST — it has no
way to produce the SigV4 signature a directly-exposed Lambda endpoint
would need. This tiny in-cluster service is the fix: it accepts that
plain POST and re-sends it as an authenticated lambda:InvokeFunction call
using its pod's own IRSA credentials (see terraform/irsa.tf). No public
network path to the Lambda exists anywhere.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3

FUNCTION_NAME = os.environ["LAMBDA_FUNCTION_NAME"]
_lambda = boto3.client("lambda", region_name=os.environ.get("AWS_REGION", "us-east-1"))


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            _lambda.invoke(FunctionName=FUNCTION_NAME, InvocationType="Event", Payload=body)
            self.send_response(202)
        except Exception as exc:  # noqa: BLE001 — Alertmanager just needs a status code back
            print(f"lambda invoke failed: {exc}")
            self.send_response(502)
        self.end_headers()

    def do_GET(self) -> None:
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format: str, *args) -> None:  # noqa: A002 — matches http.server's signature
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
