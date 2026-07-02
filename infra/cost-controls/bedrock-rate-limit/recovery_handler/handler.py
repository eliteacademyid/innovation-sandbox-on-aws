# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Rate Limit — Recovery Handler (SCP-based).

Triggered every 5 minutes by EventBridge. Scans DynamoDB for ACTIVE throttle
records that have passed their expires_at, detaches and deletes the deny-Bedrock
SCP from the sandbox account, and marks the record CLEARED.

Environment variables:
- NAMESPACE              e.g. "myisb"
- THROTTLE_TABLE_NAME    DynamoDB table name
- NOTIFICATION_TOPIC_ARN SNS topic for admin notifications
- ORG_ROLE_ARN           Role ARN in management account with Organizations permissions
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

NAMESPACE = os.environ["NAMESPACE"]
THROTTLE_TABLE_NAME = os.environ["THROTTLE_TABLE_NAME"]
NOTIFICATION_TOPIC_ARN = os.environ["NOTIFICATION_TOPIC_ARN"]
ORG_ROLE_ARN = os.environ["ORG_ROLE_ARN"]

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
sts = boto3.client("sts")
table = dynamodb.Table(THROTTLE_TABLE_NAME)


def lambda_handler(_event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    now = int(time.time())
    LOG.info("recovery sweep at %s", now)
    expired = _scan_expired(now)
    LOG.info("found %d expired throttles", len(expired))

    if not expired:
        return {"cleared": [], "failed": []}

    orgs = _get_orgs_client()
    cleared: list[str] = []
    failed: list[dict[str, str]] = []

    for item in expired:
        try:
            _clear_throttle(orgs, item)
            cleared.append(item["account_id"])
        except Exception as exc:
            LOG.exception("Failed to clear throttle for %s: %s", item.get("account_id"), exc)
            failed.append({"account_id": item.get("account_id", ""), "error": str(exc)})

    return {"cleared": cleared, "failed": failed}


def _scan_expired(now: int) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {
        "FilterExpression": Attr("status").eq("ACTIVE") & Attr("expires_at").lte(now),
    }
    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items


def _clear_throttle(orgs, item: dict[str, Any]) -> None:
    account_id = item["account_id"]
    policy_id = item.get("scp_policy_id")
    scp_name = item.get("scp_name")

    if policy_id:
        # Detach SCP from account
        try:
            orgs.detach_policy(PolicyId=policy_id, TargetId=account_id)
            LOG.info("detached SCP %s from %s", policy_id, account_id)
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "PolicyNotAttachedException":
                LOG.info("SCP already detached from %s", account_id)
            else:
                raise

        # Delete the SCP (one per account, no longer needed)
        try:
            orgs.delete_policy(PolicyId=policy_id)
            LOG.info("deleted SCP %s", policy_id)
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "PolicyInUseException":
                LOG.warning("SCP %s still in use, skipping delete", policy_id)
            else:
                raise

    # Mark cleared in DynamoDB
    table.update_item(
        Key={"account_id": account_id, "throttled_at": int(item["throttled_at"])},
        UpdateExpression="SET #s = :cleared, cleared_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":cleared": "CLEARED", ":ts": int(time.time())},
    )

    _send_notification(
        subject=f"[ISB] Bedrock throttle lifted — account {account_id}",
        body=(
            f"Bedrock rate-limit throttle auto-recovered.\n\n"
            f"Account ID:    {account_id}\n"
            f"Originally:    {item.get('reason', '?')} breach at "
            f"{time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(int(item['throttled_at'])))}\n"
            f"Cleared at:    {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}\n"
            f"SCP removed:   {scp_name} ({policy_id})\n\n"
            f"Bedrock access restored for this account.\n"
        ),
    )


def _get_orgs_client():
    creds = sts.assume_role(RoleArn=ORG_ROLE_ARN, RoleSessionName="isb-bedrock-recovery")["Credentials"]
    return boto3.client(
        "organizations",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _send_notification(subject: str, body: str) -> None:
    try:
        sns.publish(TopicArn=NOTIFICATION_TOPIC_ARN, Subject=subject[:100], Message=body)
    except ClientError as exc:
        LOG.error("SNS publish failed: %s", exc)
