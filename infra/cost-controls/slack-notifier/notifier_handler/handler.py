# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
ISB Slack Notifier — forwards SNS messages to Slack/webhook.

Receives SNS notifications (throttle alerts, cleanup failures, anomaly
detections) and posts formatted messages to a Slack webhook URL.

Environment variables:
- WEBHOOK_URL        Slack incoming webhook URL
- CHANNEL           Optional: override channel (default: webhook default)
- NAMESPACE         ISB namespace for message branding
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
import urllib.error
from typing import Any

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

WEBHOOK_URL = os.environ["WEBHOOK_URL"]
CHANNEL = os.environ.get("CHANNEL", "")
NAMESPACE = os.environ.get("NAMESPACE", "myisb")

# Map keywords in subject to emoji + color
ALERT_TYPES = {
    "throttle applied": {"emoji": "🚨", "color": "#d62728", "type": "Throttle"},
    "throttle lifted": {"emoji": "✅", "color": "#2ca02c", "type": "Recovery"},
    "cleanup failure": {"emoji": "💀", "color": "#d62728", "type": "Cleanup Failure"},
    "anomaly": {"emoji": "📈", "color": "#ff7f0e", "type": "Cost Anomaly"},
    "duration": {"emoji": "⏱️", "color": "#ff7f0e", "type": "Stuck Cleanup"},
    "kill-switch": {"emoji": "🛑", "color": "#d62728", "type": "Emergency"},
    "weekly": {"emoji": "📊", "color": "#1f77b4", "type": "Weekly Report"},
    "daily": {"emoji": "📋", "color": "#1f77b4", "type": "Daily Report"},
}


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """Process SNS records and forward to Slack."""
    results = []
    for record in event.get("Records", []):
        try:
            result = _process_record(record)
            results.append(result)
        except Exception as exc:
            LOG.exception("Failed to process record: %s", exc)
            results.append({"status": "error", "error": str(exc)})
    return {"results": results}


def _process_record(record: dict[str, Any]) -> dict[str, Any]:
    """Parse SNS message and post to Slack."""
    sns_message = record.get("Sns", {})
    subject = sns_message.get("Subject", "ISB Alert")
    message = sns_message.get("Message", "")
    timestamp = sns_message.get("Timestamp", "")

    # Detect alert type from subject
    alert_info = _detect_alert_type(subject)

    # Try to parse JSON message (CloudWatch Alarm format)
    parsed = _try_parse_alarm(message)

    # Build Slack payload
    slack_payload = _build_slack_message(subject, message, timestamp, alert_info, parsed)

    # Post to webhook
    _post_to_webhook(slack_payload)

    LOG.info("posted to slack: %s", subject[:50])
    return {"status": "sent", "subject": subject[:50]}


def _detect_alert_type(subject: str) -> dict[str, str]:
    """Match subject line to alert type for formatting."""
    subject_lower = subject.lower()
    for keyword, info in ALERT_TYPES.items():
        if keyword in subject_lower:
            return info
    return {"emoji": "ℹ️", "color": "#999999", "type": "Info"}


def _try_parse_alarm(message: str) -> dict[str, Any] | None:
    """Try to parse as CloudWatch Alarm JSON."""
    try:
        data = json.loads(message)
        if "AlarmName" in data:
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    return None


def _build_slack_message(
    subject: str,
    message: str,
    timestamp: str,
    alert_info: dict[str, str],
    parsed_alarm: dict[str, Any] | None,
) -> dict[str, Any]:
    """Build Slack Block Kit message."""
    emoji = alert_info["emoji"]
    color = alert_info["color"]
    alert_type = alert_info["type"]

    # Header
    text = f"{emoji} *[ISB] {alert_type}*\n>{subject}"

    # Body
    if parsed_alarm:
        # CloudWatch Alarm format
        body = (
            f"*Alarm:* {parsed_alarm.get('AlarmName', '?')}\n"
            f"*State:* {parsed_alarm.get('NewStateValue', '?')}\n"
            f"*Reason:* {parsed_alarm.get('NewStateReason', '?')[:200]}\n"
            f"*Account:* {parsed_alarm.get('AWSAccountId', '?')}\n"
            f"*Region:* {parsed_alarm.get('Region', '?')}"
        )
    else:
        # Plain text message (truncate for readability)
        body = message[:500]
        if len(message) > 500:
            body += "\n_(truncated)_"

    payload: dict[str, Any] = {
        "attachments": [
            {
                "color": color,
                "blocks": [
                    {
                        "type": "section",
                        "text": {"type": "mrkdwn", "text": text},
                    },
                    {
                        "type": "section",
                        "text": {"type": "mrkdwn", "text": body},
                    },
                    {
                        "type": "context",
                        "elements": [
                            {
                                "type": "mrkdwn",
                                "text": f"ISB {NAMESPACE} • {timestamp[:19] if timestamp else 'now'}",
                            }
                        ],
                    },
                ],
            }
        ],
    }

    if CHANNEL:
        payload["channel"] = CHANNEL

    return payload


def _post_to_webhook(payload: dict[str, Any]) -> None:
    """POST JSON payload to the Slack webhook URL."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                body = resp.read().decode()
                LOG.error("webhook returned %d: %s", resp.status, body)
                raise RuntimeError(f"Webhook returned {resp.status}: {body}")
    except urllib.error.HTTPError as exc:
        LOG.error("webhook HTTP error %d: %s", exc.code, exc.read().decode()[:200])
        raise
