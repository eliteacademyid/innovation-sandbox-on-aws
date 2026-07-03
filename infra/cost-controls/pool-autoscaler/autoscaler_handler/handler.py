# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
ISB Pool Auto-Scaler.

Triggered by EventBridge schedule (every 15 min). Checks the sandbox account
pool — if Available accounts drop below a threshold, automatically creates
new AWS accounts and registers them to the ISB pool.

Safety guardrails:
- Max accounts per execution (default: 5)
- Max total pool size cap (default: 150)
- Notification on every scale event
- Dry-run mode for testing

Environment variables:
- NAMESPACE                ISB namespace
- ACCOUNTS_TABLE_NAME      DynamoDB table for sandbox accounts
- MIN_AVAILABLE_THRESHOLD  Trigger when Available < this (default: 10)
- MAX_PER_EXECUTION        Max accounts to create per run (default: 5)
- MAX_POOL_SIZE            Hard cap on total pool size (default: 150)
- ORG_ROLE_ARN             Role in management account for Organizations API
- ISB_API_ENDPOINT         ISB API endpoint for registering accounts
- ISB_ADMIN_TOKEN_SECRET   Secrets Manager ARN for admin JWT token
- NOTIFICATION_TOPIC_ARN   SNS topic for scale notifications
- ACCOUNT_EMAIL_DOMAIN     Email domain for new accounts (e.g. aws+sandbox{}@eliteacademy.id)
- ACCOUNT_NAME_PREFIX      Prefix for new account names (e.g. isb-sandbox-)
- DRY_RUN                  Set to "true" to skip actual creation
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

NAMESPACE = os.environ["NAMESPACE"]
ACCOUNTS_TABLE_NAME = os.environ["ACCOUNTS_TABLE_NAME"]
MIN_AVAILABLE = int(os.environ.get("MIN_AVAILABLE_THRESHOLD", "10"))
MAX_PER_EXECUTION = int(os.environ.get("MAX_PER_EXECUTION", "5"))
MAX_POOL_SIZE = int(os.environ.get("MAX_POOL_SIZE", "150"))
ORG_ROLE_ARN = os.environ["ORG_ROLE_ARN"]
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")
ACCOUNT_EMAIL_DOMAIN = os.environ.get("ACCOUNT_EMAIL_DOMAIN", "eliteacademy.id")
ACCOUNT_NAME_PREFIX = os.environ.get("ACCOUNT_NAME_PREFIX", "isb-sandbox-")
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
sts = boto3.client("sts")


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """Check pool and auto-scale if needed."""
    LOG.info("pool autoscaler triggered (threshold=%d, max_per_exec=%d, dry_run=%s)",
             MIN_AVAILABLE, MAX_PER_EXECUTION, DRY_RUN)

    # Get current pool status
    pool_status = _get_pool_status()
    available = pool_status.get("Available", 0)
    total = sum(pool_status.values())

    LOG.info("pool status: available=%d, total=%d, status=%s", available, total, pool_status)

    # Check if scale needed
    if available >= MIN_AVAILABLE:
        LOG.info("pool healthy: %d available >= %d threshold. No action.", available, MIN_AVAILABLE)
        return {"action": "none", "available": available, "total": total, "reason": "above_threshold"}

    # Check hard cap
    if total >= MAX_POOL_SIZE:
        LOG.warning("pool at max cap (%d >= %d). Cannot scale.", total, MAX_POOL_SIZE)
        _notify(f"⚠️ Pool at max cap ({total}/{MAX_POOL_SIZE}). Available: {available}. Cannot auto-scale.")
        return {"action": "blocked", "available": available, "total": total, "reason": "max_cap_reached"}

    # Calculate how many to create
    deficit = MIN_AVAILABLE - available
    to_create = min(deficit, MAX_PER_EXECUTION, MAX_POOL_SIZE - total)

    LOG.info("scaling: deficit=%d, creating=%d accounts", deficit, to_create)

    if DRY_RUN:
        LOG.info("DRY RUN — would create %d accounts", to_create)
        return {"action": "dry_run", "would_create": to_create, "available": available, "total": total}

    # Create accounts
    orgs = _get_orgs_client()
    created = []
    failed = []

    for i in range(to_create):
        account_name = f"{ACCOUNT_NAME_PREFIX}{int(time.time())}-{i:02d}"
        account_email = f"aws+{account_name}@{ACCOUNT_EMAIL_DOMAIN}"

        try:
            result = _create_account(orgs, account_name, account_email)
            created.append(result)
            LOG.info("created account: %s (%s)", result.get("account_id"), account_name)
            time.sleep(2)  # Rate limit: Organizations API throttles at ~1 req/sec
        except Exception as exc:
            LOG.error("failed to create account %s: %s", account_name, exc)
            failed.append({"name": account_name, "error": str(exc)})

    # Notify
    if created:
        _notify(
            f"📈 Pool auto-scaled: +{len(created)} accounts\n\n"
            f"Trigger: Available dropped to {available} (threshold: {MIN_AVAILABLE})\n"
            f"Created: {len(created)}, Failed: {len(failed)}\n"
            f"New total: {total + len(created)}\n\n"
            f"Accounts:\n" + "\n".join(f"  • {a['account_id']} ({a['name']})" for a in created) +
            f"\n\nNote: New accounts need region enabling + ISB registration before they're usable.\n"
            f"Run: scripts/account-management/register-accounts-to-pool.sh"
        )

    return {
        "action": "scaled",
        "available_before": available,
        "created": len(created),
        "failed": len(failed),
        "new_total": total + len(created),
        "accounts": created,
    }


def _get_pool_status() -> dict[str, int]:
    """Get account pool distribution by status."""
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


def _get_orgs_client():
    """Assume role into management account for Organizations API."""
    creds = sts.assume_role(
        RoleArn=ORG_ROLE_ARN,
        RoleSessionName="isb-pool-autoscaler",
        DurationSeconds=900,
    )["Credentials"]
    return boto3.client(
        "organizations",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _create_account(orgs, name: str, email: str) -> dict[str, str]:
    """Create a new AWS account via Organizations."""
    resp = orgs.create_account(
        AccountName=name,
        Email=email,
    )
    request_id = resp["CreateAccountStatus"]["Id"]

    # Poll for completion (account creation takes 30-60s)
    for _ in range(30):
        time.sleep(5)
        status = orgs.describe_create_account_status(
            CreateAccountRequestId=request_id
        )["CreateAccountStatus"]

        if status["State"] == "SUCCEEDED":
            return {
                "account_id": status["AccountId"],
                "name": name,
                "email": email,
                "request_id": request_id,
            }
        elif status["State"] == "FAILED":
            raise RuntimeError(f"Account creation failed: {status.get('FailureReason', 'unknown')}")

    raise RuntimeError(f"Account creation timed out after 150s (request: {request_id})")


def _notify(message: str) -> None:
    """Send notification to admin."""
    if not NOTIFICATION_TOPIC_ARN:
        return
    try:
        sns.publish(
            TopicArn=NOTIFICATION_TOPIC_ARN,
            Subject="[ISB] Pool Auto-Scale Event"[:100],
            Message=message,
        )
    except ClientError as exc:
        LOG.error("SNS notify failed: %s", exc)
