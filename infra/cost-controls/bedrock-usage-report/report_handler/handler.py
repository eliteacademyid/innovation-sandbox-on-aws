# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Daily Usage Report — Report Handler.

Triggered daily by EventBridge. Scans active sandbox accounts, queries
CloudWatch Bedrock metrics for the last 24 hours, calculates estimated costs,
and emails a CSV report to the admin via SES.

Environment variables:
- NAMESPACE                ISB namespace (e.g. "myisb")
- ACCOUNTS_TABLE_NAME      DynamoDB table for sandbox accounts
- LEASES_TABLE_NAME        DynamoDB table for leases
- THROTTLE_TABLE_NAME      DynamoDB table for throttle events
- ADMIN_EMAIL              Recipient email
- SES_SOURCE_EMAIL         Verified SES sender
- SES_REGION               SES region
- METRICS_REGIONS          Comma-separated regions to query metrics from
"""

from __future__ import annotations

import csv
import io
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
METRICS_REGIONS = os.environ.get("METRICS_REGIONS", "us-east-1,ap-southeast-1").split(",")

# CloudWatch Bedrock metrics here are queried account-wide with no ModelId
# dimension (see _query_bedrock_metrics), so token counts can't be attributed
# to a specific model. Cost is therefore always a blended estimate using this
# single rate, not real per-model pricing.
BLENDED_PRICING = {"input": 0.001, "output": 0.005}  # USD per 1K tokens

dynamodb = boto3.resource("dynamodb")
sts = boto3.client("sts")


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """Generate and email daily Bedrock usage report."""
    LOG.info("generating daily bedrock usage report")

    # Time window: last 24 hours
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(hours=24)

    # Get active accounts and leases
    active_accounts = _get_active_accounts()
    active_leases = _get_active_leases()
    throttle_counts = _get_throttle_counts(start_time) if THROTTLE_TABLE_NAME else {}

    LOG.info("active_accounts=%d active_leases=%d", len(active_accounts), len(active_leases))

    # Build lease lookup: account_id → user email
    lease_by_account = {}
    for lease in active_leases:
        account_id = lease.get("accountId", "")
        user_email = lease.get("userEmail", lease.get("userId", "unknown"))
        lease_by_account[account_id] = user_email

    # Query metrics for each active account
    rows: list[dict[str, Any]] = []
    for account in active_accounts:
        account_id = account["awsAccountId"]
        metrics = _query_bedrock_metrics(account_id, start_time, end_time)
        est_cost = _estimate_cost(metrics)
        rows.append({
            "account_id": account_id,
            "account_name": account.get("name", ""),
            "user": lease_by_account.get(account_id, "—"),
            "input_tokens": metrics["input_tokens"],
            "output_tokens": metrics["output_tokens"],
            "invocations": metrics["invocations"],
            "est_cost_usd": round(est_cost, 4),
            "throttle_events": throttle_counts.get(account_id, 0),
        })

    # Sort by cost descending
    rows.sort(key=lambda r: r["est_cost_usd"], reverse=True)

    # Build CSV
    csv_content = _build_csv(rows)

    # Build summary
    total_input = sum(r["input_tokens"] for r in rows)
    total_output = sum(r["output_tokens"] for r in rows)
    total_invocations = sum(r["invocations"] for r in rows)
    total_cost = sum(r["est_cost_usd"] for r in rows)
    active_with_usage = len([r for r in rows if r["invocations"] > 0])

    summary = (
        f"ISB Bedrock Daily Usage Report\n"
        f"Period: {start_time.strftime('%Y-%m-%d %H:%M UTC')} → {end_time.strftime('%Y-%m-%d %H:%M UTC')}\n\n"
        f"Active accounts:       {len(active_accounts)}\n"
        f"Accounts with usage:   {active_with_usage}\n"
        f"Total invocations:     {total_invocations:,}\n"
        f"Total input tokens:    {total_input:,}\n"
        f"Total output tokens:   {total_output:,}\n"
        f"Estimated total cost:  ${total_cost:.2f}\n"
        f"Throttle events (24h): {sum(throttle_counts.values())}\n\n"
        f"Top 5 accounts by cost:\n"
    )
    for r in rows[:5]:
        if r["est_cost_usd"] > 0:
            summary += f"  {r['account_id']} ({r['user']}): ${r['est_cost_usd']:.4f} — {r['invocations']} calls\n"

    summary += f"\nFull CSV attached.\n"

    # Send email
    _send_report_email(summary, csv_content, start_time)

    LOG.info("report sent: accounts=%d total_cost=$%.2f", len(rows), total_cost)
    return {
        "status": "sent",
        "active_accounts": len(active_accounts),
        "accounts_with_usage": active_with_usage,
        "total_cost_usd": round(total_cost, 4),
        "total_invocations": total_invocations,
    }


def _get_active_accounts() -> list[dict[str, Any]]:
    """Get all accounts with Active status from DynamoDB."""
    table = dynamodb.Table(ACCOUNTS_TABLE_NAME)
    items: list[dict[str, Any]] = []
    scan_kwargs: dict[str, Any] = {
        "FilterExpression": "#s = :active",
        "ExpressionAttributeNames": {"#s": "status", "#n": "name"},
        "ExpressionAttributeValues": {":active": "Active"},
        "ProjectionExpression": "awsAccountId, #s, #n, email",
    }
    while True:
        resp = table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items


def _get_active_leases() -> list[dict[str, Any]]:
    """Get active leases to map accounts → users."""
    table = dynamodb.Table(LEASES_TABLE_NAME)
    items: list[dict[str, Any]] = []
    scan_kwargs: dict[str, Any] = {
        "FilterExpression": "#s = :active",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":active": "Active"},
    }
    while True:
        resp = table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items


def _get_throttle_counts(since: datetime) -> dict[str, int]:
    """Count throttle events per account in the last 24h."""
    table = dynamodb.Table(THROTTLE_TABLE_NAME)
    since_epoch = int(since.timestamp())
    counts: dict[str, int] = {}
    scan_kwargs: dict[str, Any] = {
        "FilterExpression": "throttled_at >= :since",
        "ExpressionAttributeValues": {":since": since_epoch},
        "ProjectionExpression": "account_id",
    }
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            aid = item["account_id"]
            counts[aid] = counts.get(aid, 0) + 1
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return counts


def _query_bedrock_metrics(account_id: str, start: datetime, end: datetime) -> dict[str, int]:
    """Query CloudWatch Bedrock metrics by assuming role into the sandbox account."""
    total_input = 0
    total_output = 0
    total_invocations = 0

    # Assume role into sandbox account
    try:
        creds = sts.assume_role(
            RoleArn=f"arn:aws:iam::{account_id}:role/OrganizationAccountAccessRole",
            RoleSessionName="isb-usage-report",
            DurationSeconds=900,
        )["Credentials"]
    except ClientError as exc:
        LOG.warning("cannot assume role in account %s: %s", account_id, exc)
        return {"input_tokens": 0, "output_tokens": 0, "invocations": 0}

    for region in METRICS_REGIONS:
        try:
            cw = boto3.client(
                "cloudwatch",
                region_name=region,
                aws_access_key_id=creds["AccessKeyId"],
                aws_secret_access_key=creds["SecretAccessKey"],
                aws_session_token=creds["SessionToken"],
            )
            # Query without AccountId dimension (metrics are local to the account)
            total_input += _get_metric_sum(cw, "AWS/Bedrock", "InputTokenCount", start, end)
            total_output += _get_metric_sum(cw, "AWS/Bedrock", "OutputTokenCount", start, end)
            total_invocations += _get_metric_sum(cw, "AWS/Bedrock", "Invocations", start, end)
        except ClientError as exc:
            LOG.warning("metrics query failed region=%s account=%s: %s", region, account_id, exc)

    return {
        "input_tokens": int(total_input),
        "output_tokens": int(total_output),
        "invocations": int(total_invocations),
    }


def _get_metric_sum(
    cw, namespace: str, metric_name: str,
    start: datetime, end: datetime
) -> float:
    """Get sum of a metric for 24h period (no dimension filter — account-local query)."""
    resp = cw.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=[],
        StartTime=start,
        EndTime=end,
        Period=86400,  # 24h in one datapoint
        Statistics=["Sum"],
    )
    datapoints = resp.get("Datapoints", [])
    return sum(dp.get("Sum", 0) for dp in datapoints)


def _estimate_cost(metrics: dict[str, int]) -> float:
    """Estimate cost based on token counts (using blended average pricing)."""
    input_cost = (metrics["input_tokens"] / 1000) * BLENDED_PRICING["input"]
    output_cost = (metrics["output_tokens"] / 1000) * BLENDED_PRICING["output"]
    return input_cost + output_cost


def _build_csv(rows: list[dict[str, Any]]) -> str:
    """Build CSV string from rows."""
    output = io.StringIO()
    fieldnames = [
        "account_id", "account_name", "user", "input_tokens",
        "output_tokens", "invocations", "est_cost_usd", "throttle_events"
    ]
    writer = csv.DictWriter(output, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def _send_report_email(summary: str, csv_content: str, report_date: datetime) -> None:
    """Send report via SES with CSV attachment."""
    import email.mime.application
    import email.mime.multipart
    import email.mime.text

    ses = boto3.client("ses", region_name=SES_REGION)
    date_str = report_date.strftime("%Y-%m-%d")

    msg = email.mime.multipart.MIMEMultipart("mixed")
    msg["Subject"] = f"[ISB] Daily Bedrock Usage Report — {date_str}"
    msg["From"] = SES_SOURCE_EMAIL
    msg["To"] = ADMIN_EMAIL

    # Text body
    body = email.mime.text.MIMEText(summary, "plain")
    msg.attach(body)

    # CSV attachment
    attachment = email.mime.application.MIMEApplication(csv_content.encode("utf-8"))
    attachment.add_header(
        "Content-Disposition", "attachment",
        filename=f"bedrock-usage-{date_str}.csv"
    )
    msg.attach(attachment)

    try:
        ses.send_raw_email(
            Source=SES_SOURCE_EMAIL,
            Destinations=[ADMIN_EMAIL],
            RawMessage={"Data": msg.as_string()},
        )
        LOG.info("report email sent to %s", ADMIN_EMAIL)
    except ClientError as exc:
        LOG.error("SES send failed: %s", exc)
        raise
