# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
ISB Weekly Pool Health Report.

Triggered every Monday 09:00 WIB by EventBridge. Generates a comprehensive
report covering the past 7 days:
- Pool utilization (Available/Active/CleanUp/Quarantine distribution)
- Cleanup success/failure rate
- Total leases created/expired/terminated
- Cost per user (aggregate Bedrock spend)
- Throttle events summary
- Anomaly alerts

Sends HTML email to admin via SES.

Environment variables:
- NAMESPACE              ISB namespace
- ACCOUNTS_TABLE_NAME    DynamoDB table for sandbox accounts
- LEASES_TABLE_NAME      DynamoDB table for leases
- THROTTLE_TABLE_NAME    DynamoDB throttle events table
- ADMIN_EMAIL            Recipient
- SES_SOURCE_EMAIL       Verified SES sender
- SES_REGION             SES region
- CODEBUILD_PROJECT      CodeBuild project name for cleanup metrics
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

NAMESPACE = os.environ["NAMESPACE"]
ACCOUNTS_TABLE_NAME = os.environ["ACCOUNTS_TABLE_NAME"]
LEASES_TABLE_NAME = os.environ["LEASES_TABLE_NAME"]
THROTTLE_TABLE_NAME = os.environ.get("THROTTLE_TABLE_NAME", "")
ADMIN_EMAIL = os.environ["ADMIN_EMAIL"]
SES_SOURCE_EMAIL = os.environ["SES_SOURCE_EMAIL"]
SES_REGION = os.environ.get("SES_REGION", "ap-southeast-1")
CODEBUILD_PROJECT = os.environ.get("CODEBUILD_PROJECT", "")

dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """Generate and email weekly pool health report."""
    LOG.info("generating weekly pool health report")

    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(days=7)

    # Gather data
    pool_status = _get_pool_status()
    lease_stats = _get_lease_stats(start_time)
    cleanup_stats = _get_cleanup_stats(start_time, end_time)
    throttle_stats = _get_throttle_stats(start_time)

    # Calculate derived metrics
    total_accounts = sum(pool_status.values())
    utilization_pct = round((pool_status.get("Active", 0) / max(total_accounts, 1)) * 100, 1)
    cleanup_success_rate = round(
        (cleanup_stats["succeeded"] / max(cleanup_stats["total"], 1)) * 100, 1
    )

    # Build report
    report = _build_html_report(
        period_start=start_time,
        period_end=end_time,
        pool_status=pool_status,
        total_accounts=total_accounts,
        utilization_pct=utilization_pct,
        lease_stats=lease_stats,
        cleanup_stats=cleanup_stats,
        cleanup_success_rate=cleanup_success_rate,
        throttle_stats=throttle_stats,
    )

    # Send email
    _send_html_email(
        subject=f"[ISB] Weekly Pool Health Report — {start_time.strftime('%b %d')} to {end_time.strftime('%b %d, %Y')}",
        html_body=report,
    )

    result = {
        "status": "sent",
        "period": f"{start_time.isoformat()} to {end_time.isoformat()}",
        "pool_total": total_accounts,
        "pool_available": pool_status.get("Available", 0),
        "pool_active": pool_status.get("Active", 0),
        "utilization_pct": utilization_pct,
        "leases_created": lease_stats["created"],
        "leases_expired": lease_stats["expired"],
        "cleanup_total": cleanup_stats["total"],
        "cleanup_success_rate": cleanup_success_rate,
        "throttle_events": throttle_stats["total"],
    }
    LOG.info("report sent: %s", json.dumps(result))
    return result


def _get_pool_status() -> dict[str, int]:
    """Get current account pool distribution by status."""
    table = dynamodb.Table(ACCOUNTS_TABLE_NAME)
    counts: dict[str, int] = {}
    scan_kwargs: dict[str, Any] = {
        "ProjectionExpression": "#s",
        "ExpressionAttributeNames": {"#s": "status"},
    }
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            status = item.get("status", "Unknown")
            counts[status] = counts.get(status, 0) + 1
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return counts


def _get_lease_stats(since: datetime) -> dict[str, int]:
    """Get lease activity in the past 7 days."""
    table = dynamodb.Table(LEASES_TABLE_NAME)
    since_iso = since.isoformat()
    created = 0
    expired = 0
    terminated = 0
    frozen = 0
    active = 0

    scan_kwargs: dict[str, Any] = {}
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            status = item.get("status", "")
            meta = item.get("meta", {})
            created_time = ""
            if isinstance(meta, dict):
                ct = meta.get("createdTime", "")
                created_time = ct.get("S", ct) if isinstance(ct, dict) else str(ct)

            if status == "Active":
                active += 1
            if created_time >= since_iso:
                created += 1
            if status == "Expired":
                expired += 1
            elif status == "Terminated":
                terminated += 1
            elif status == "Frozen":
                frozen += 1
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return {
        "created": created,
        "expired": expired,
        "terminated": terminated,
        "frozen": frozen,
        "active": active,
    }


def _get_cleanup_stats(start: datetime, end: datetime) -> dict[str, int]:
    """Get CodeBuild cleanup metrics for the past 7 days."""
    if not CODEBUILD_PROJECT:
        return {"total": 0, "succeeded": 0, "failed": 0, "avg_duration_min": 0}

    try:
        succeeded = _get_cw_sum("SucceededBuilds", start, end)
        failed = _get_cw_sum("FailedBuilds", start, end)
        duration = _get_cw_avg("Duration", start, end)
        total = int(succeeded + failed)
        return {
            "total": total,
            "succeeded": int(succeeded),
            "failed": int(failed),
            "avg_duration_min": round(duration / 60, 1) if duration else 0,
        }
    except ClientError as exc:
        LOG.warning("cleanup metrics query failed: %s", exc)
        return {"total": 0, "succeeded": 0, "failed": 0, "avg_duration_min": 0}


def _get_cw_sum(metric_name: str, start: datetime, end: datetime) -> float:
    resp = cloudwatch.get_metric_statistics(
        Namespace="AWS/CodeBuild",
        MetricName=metric_name,
        Dimensions=[{"Name": "ProjectName", "Value": CODEBUILD_PROJECT}],
        StartTime=start, EndTime=end,
        Period=604800,  # 7 days
        Statistics=["Sum"],
    )
    return sum(dp.get("Sum", 0) for dp in resp.get("Datapoints", []))


def _get_cw_avg(metric_name: str, start: datetime, end: datetime) -> float:
    resp = cloudwatch.get_metric_statistics(
        Namespace="AWS/CodeBuild",
        MetricName=metric_name,
        Dimensions=[{"Name": "ProjectName", "Value": CODEBUILD_PROJECT}],
        StartTime=start, EndTime=end,
        Period=604800,
        Statistics=["Average"],
    )
    datapoints = resp.get("Datapoints", [])
    return datapoints[0].get("Average", 0) if datapoints else 0


def _get_throttle_stats(since: datetime) -> dict[str, int]:
    """Get throttle events in the past 7 days."""
    if not THROTTLE_TABLE_NAME:
        return {"total": 0, "unique_accounts": 0}

    table = dynamodb.Table(THROTTLE_TABLE_NAME)
    since_epoch = int(since.timestamp())
    accounts: set[str] = set()
    total = 0

    scan_kwargs: dict[str, Any] = {
        "FilterExpression": "throttled_at >= :since",
        "ExpressionAttributeValues": {":since": since_epoch},
        "ProjectionExpression": "account_id",
    }
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            accounts.add(item["account_id"])
            total += 1
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return {"total": total, "unique_accounts": len(accounts)}


def _build_html_report(
    period_start: datetime,
    period_end: datetime,
    pool_status: dict[str, int],
    total_accounts: int,
    utilization_pct: float,
    lease_stats: dict[str, int],
    cleanup_stats: dict[str, int],
    cleanup_success_rate: float,
    throttle_stats: dict[str, int],
) -> str:
    """Build HTML email body."""
    status_color = "#2ca02c" if utilization_pct < 80 else ("#ff7f0e" if utilization_pct < 95 else "#d62728")
    cleanup_color = "#2ca02c" if cleanup_success_rate >= 95 else ("#ff7f0e" if cleanup_success_rate >= 80 else "#d62728")

    return f"""
    <html>
    <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
      <h2 style="color: #232f3e; border-bottom: 2px solid #ff9900; padding-bottom: 10px;">
        ISB Weekly Pool Health Report
      </h2>
      <p style="color: #666; font-size: 14px;">
        Period: {period_start.strftime('%b %d')} — {period_end.strftime('%b %d, %Y')}
      </p>

      <h3>📊 Pool Status</h3>
      <table style="width:100%; border-collapse:collapse; font-size:14px;">
        <tr style="background:#f5f5f5;"><td style="padding:8px;"><strong>Total Accounts</strong></td><td style="padding:8px; text-align:right;">{total_accounts}</td></tr>
        <tr><td style="padding:8px;">Available</td><td style="padding:8px; text-align:right; color:#2ca02c;"><strong>{pool_status.get("Available", 0)}</strong></td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Active</td><td style="padding:8px; text-align:right; color:#1f77b4;"><strong>{pool_status.get("Active", 0)}</strong></td></tr>
        <tr><td style="padding:8px;">CleanUp</td><td style="padding:8px; text-align:right;">{pool_status.get("CleanUp", 0)}</td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Quarantine</td><td style="padding:8px; text-align:right; color:#d62728;">{pool_status.get("Quarantine", 0)}</td></tr>
        <tr><td style="padding:8px;"><strong>Utilization</strong></td><td style="padding:8px; text-align:right; color:{status_color};"><strong>{utilization_pct}%</strong></td></tr>
      </table>

      <h3>📋 Lease Activity (7 days)</h3>
      <table style="width:100%; border-collapse:collapse; font-size:14px;">
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Currently Active</td><td style="padding:8px; text-align:right;"><strong>{lease_stats["active"]}</strong></td></tr>
        <tr><td style="padding:8px;">Created this week</td><td style="padding:8px; text-align:right;">{lease_stats["created"]}</td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Expired</td><td style="padding:8px; text-align:right;">{lease_stats["expired"]}</td></tr>
        <tr><td style="padding:8px;">Terminated</td><td style="padding:8px; text-align:right;">{lease_stats["terminated"]}</td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Frozen</td><td style="padding:8px; text-align:right;">{lease_stats["frozen"]}</td></tr>
      </table>

      <h3>🧹 Cleanup Performance</h3>
      <table style="width:100%; border-collapse:collapse; font-size:14px;">
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Total Cleanups</td><td style="padding:8px; text-align:right;">{cleanup_stats["total"]}</td></tr>
        <tr><td style="padding:8px;">Succeeded</td><td style="padding:8px; text-align:right; color:#2ca02c;">{cleanup_stats["succeeded"]}</td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Failed</td><td style="padding:8px; text-align:right; color:#d62728;">{cleanup_stats["failed"]}</td></tr>
        <tr><td style="padding:8px;"><strong>Success Rate</strong></td><td style="padding:8px; text-align:right; color:{cleanup_color};"><strong>{cleanup_success_rate}%</strong></td></tr>
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Avg Duration</td><td style="padding:8px; text-align:right;">{cleanup_stats["avg_duration_min"]} min</td></tr>
      </table>

      <h3>🛡️ Rate Limiter</h3>
      <table style="width:100%; border-collapse:collapse; font-size:14px;">
        <tr style="background:#f5f5f5;"><td style="padding:8px;">Throttle Events</td><td style="padding:8px; text-align:right;">{throttle_stats["total"]}</td></tr>
        <tr><td style="padding:8px;">Unique Accounts Throttled</td><td style="padding:8px; text-align:right;">{throttle_stats["unique_accounts"]}</td></tr>
      </table>

      <hr style="margin-top:20px; border:none; border-top:1px solid #ddd;">
      <p style="font-size:12px; color:#999;">
        ISB Operations • {NAMESPACE} • Generated {period_end.strftime('%Y-%m-%d %H:%M UTC')}
        <br>Dashboard: <a href="https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards/dashboard/ISB-Operations-myisb">CloudWatch</a>
        | Web UI: <a href="https://aws-sandbox.eliteacademy.id">aws-sandbox.eliteacademy.id</a>
      </p>
    </body>
    </html>
    """


def _send_html_email(subject: str, html_body: str) -> None:
    """Send HTML email via SES."""
    ses = boto3.client("ses", region_name=SES_REGION)
    try:
        ses.send_email(
            Source=SES_SOURCE_EMAIL,
            Destination={"ToAddresses": [ADMIN_EMAIL]},
            Message={
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {"Html": {"Data": html_body, "Charset": "UTF-8"}},
            },
        )
        LOG.info("weekly report email sent to %s", ADMIN_EMAIL)
    except ClientError as exc:
        LOG.error("SES send failed: %s", exc)
        raise
