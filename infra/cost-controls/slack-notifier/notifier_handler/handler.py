# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
ISB Discord Notifier — forwards SNS messages to Discord webhook.

Receives SNS notifications (throttle alerts, cleanup failures, anomaly
detections) and posts formatted embed messages to a Discord webhook URL.

Environment variables:
- WEBHOOK_URL        Discord webhook URL
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
NAMESPACE = os.environ.get("NAMESPACE", "myisb")

# Map keywords in subject to emoji + color (Discord color is decimal integer)
ALERT_TYPES = {
    "throttle applied": {"emoji": "🚨", "color": 14034728, "type": "Throttle"},         # #d62728
    "throttle lifted": {"emoji": "✅", "color": 2928930, "type": "Recovery"},            # #2ca02c
    "cleanup failure": {"emoji": "💀", "color": 14034728, "type": "Cleanup Failure"},    # #d62728
    "anomaly": {"emoji": "📈", "color": 16744206, "type": "Cost Anomaly"},              # #ff7f0e
    "duration": {"emoji": "⏱️", "color": 16744206, "type": "Stuck Cleanup"},            # #ff7f0e
    "kill-switch": {"emoji": "🛑", "color": 14034728, "type": "Emergency"},             # #d62728
    "weekly": {"emoji": "📊", "color": 2062516, "type": "Weekly Report"},               # #1f77b4
    "daily": {"emoji": "📋", "color": 2062516, "type": "Daily Report"},                 # #1f77b4
}


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """Process SNS records and forward to Discord."""
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
    """Parse SNS message and post to Discord."""
    sns_message = record.get("Sns", {})
    subject = sns_message.get("Subject", "ISB Alert")
    message = sns_message.get("Message", "")
    timestamp = sns_message.get("Timestamp", "")

    # Detect alert type from subject
    alert_info = _detect_alert_type(subject)

    # Try to parse JSON message (CloudWatch Alarm format)
    parsed = _try_parse_alarm(message)

    # Build Discord payload
    payload = _build_discord_message(subject, message, timestamp, alert_info, parsed)

    # Post to webhook
    _post_to_webhook(payload)

    LOG.info("posted to discord: %s", subject[:50])
    return {"status": "sent", "subject": subject[:50]}


def _detect_alert_type(subject: str) -> dict[str, Any]:
    """Match subject line to alert type for formatting."""
    subject_lower = subject.lower()
    for keyword, info in ALERT_TYPES.items():
        if keyword in subject_lower:
            return info
    return {"emoji": "ℹ️", "color": 10066329, "type": "Info"}  # #999999


def _try_parse_alarm(message: str) -> dict[str, Any] | None:
    """Try to parse as CloudWatch Alarm JSON."""
    try:
        data = json.loads(message)
        if "AlarmName" in data:
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    return None


def _build_discord_message(
    subject: str,
    message: str,
    timestamp: str,
    alert_info: dict[str, Any],
    parsed_alarm: dict[str, Any] | None,
) -> dict[str, Any]:
    """Build Discord webhook payload with embed."""
    emoji = alert_info["emoji"]
    color = alert_info["color"]
    alert_type = alert_info["type"]

    # Build embed fields
    fields = []

    if parsed_alarm:
        fields = [
            {"name": "Alarm", "value": parsed_alarm.get("AlarmName", "?"), "inline": True},
            {"name": "State", "value": parsed_alarm.get("NewStateValue", "?"), "inline": True},
            {"name": "Account", "value": parsed_alarm.get("AWSAccountId", "?"), "inline": True},
            {"name": "Region", "value": parsed_alarm.get("Region", "?"), "inline": True},
            {"name": "Reason", "value": parsed_alarm.get("NewStateReason", "?")[:200], "inline": False},
        ]
    else:
        # Plain text — split into chunks if needed
        body = message[:1024]
        if len(message) > 1024:
            body += "\n*(truncated)*"
        fields = [
            {"name": "Details", "value": body, "inline": False},
        ]

    embed = {
        "title": f"{emoji} [ISB] {alert_type}",
        "description": subject,
        "color": color,
        "fields": fields,
        "footer": {
            "text": f"ISB {NAMESPACE} • {timestamp[:19] if timestamp else 'now'}",
        },
    }

    if timestamp:
        embed["timestamp"] = timestamp

    return {
        "username": "ISB Alert Bot",
        "avatar_url": "https://a0.awsstatic.com/libra-css/images/logos/aws_smile-header-desktop-en-white_59x35@2x.png",
        "embeds": [embed],
    }


def _post_to_webhook(payload: dict[str, Any]) -> None:
    """POST JSON payload to the Discord webhook URL."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            # Discord returns 204 No Content on success
            if resp.status not in (200, 204):
                body = resp.read().decode()
                LOG.error("webhook returned %d: %s", resp.status, body)
                raise RuntimeError(f"Webhook returned {resp.status}: {body}")
    except urllib.error.HTTPError as exc:
        LOG.error("webhook HTTP error %d: %s", exc.code, exc.read().decode()[:200])
        raise
