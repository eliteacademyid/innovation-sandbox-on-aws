# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Rate Limit — Recovery Handler.

Triggered every 5 minutes by EventBridge. Scans DynamoDB for ACTIVE throttle
records that have passed their expires_at, assumes role into the member
account, removes the deny inline policy from the SSO IsbUsers role, and
marks the record CLEARED.

Environment variables:
- NAMESPACE              e.g. "myisb"
- THROTTLE_TABLE_NAME    DynamoDB table name
- NOTIFICATION_TOPIC_ARN SNS topic for admin notifications
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

DENY_POLICY_NAME = "BedrockRateLimitDeny"

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
sts = boto3.client("sts")
table = dynamodb.Table(THROTTLE_TABLE_NAME)


def lambda_handler(_event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    now = int(time.time())
    LOG.info("recovery sweep at %s", now)
    expired = _scan_expired(now)
    LOG.info("found %d expired throttles", len(expired))

    cleared: list[str] = []
    failed: list[dict[str, str]] = []
    for item in expired:
        try:
            _clear_throttle(item)
            cleared.append(item["account_id"])
        except Exception as exc:  # pragma: no cover
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


def _clear_throttle(item: dict[str, Any]) -> None:
    account_id = item["account_id"]
    sso_role_name = item.get("sso_role_name")

    creds = _assume_role(account_id)
    iam = _iam_client(creds)

    if not sso_role_name:
        sso_role_name = _find_sso_isb_users_role(iam)

    try:
        iam.delete_role_policy(RoleName=sso_role_name, PolicyName=DENY_POLICY_NAME)
        LOG.info("removed deny policy from role=%s account=%s", sso_role_name, account_id)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "NoSuchEntity":
            LOG.info("deny policy already absent on %s — marking cleared", account_id)
        else:
            raise

    table.update_item(
        Key={"account_id": account_id, "throttled_at": int(item["throttled_at"])},
        UpdateExpression="SET #s = :cleared, cleared_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":cleared": "CLEARED", ":ts": int(time.time())},
    )

    _send_notification(
        subject=f"[ISB] Bedrock throttle lifted — account {account_id}",
        body=(
            f"Bedrock rate-limit throttle has been auto-recovered.\n\n"
            f"Account ID:    {account_id}\n"
            f"Originally:    {item.get('reason', '?')} breach at "
            f"{time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(int(item['throttled_at'])))}\n"
            f"Cleared at:    {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}\n\n"
            f"Bedrock access restored to IsbUsers SSO sessions in this account.\n"
        ),
    )


def _assume_role(member_account_id: str) -> dict[str, str]:
    role_arn = f"arn:aws:iam::{member_account_id}:role/isb-{NAMESPACE}-bedrock-throttle-role"
    resp = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName="isb-bedrock-recovery",
        DurationSeconds=900,
    )
    return resp["Credentials"]


def _iam_client(creds: dict[str, str]):
    return boto3.client(
        "iam",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _find_sso_isb_users_role(iam) -> str:
    needle = f"AWSReservedSSO_{NAMESPACE}_IsbUsers_"
    paginator = iam.get_paginator("list_roles")
    for page in paginator.paginate(PathPrefix="/aws-reserved/sso.amazonaws.com/"):
        for role in page["Roles"]:
            if role["RoleName"].startswith(needle):
                return role["RoleName"]
    raise RuntimeError(f"No SSO role matching {needle}* found")


def _send_notification(subject: str, body: str) -> None:
    try:
        sns.publish(TopicArn=NOTIFICATION_TOPIC_ARN, Subject=subject[:100], Message=body)
    except ClientError as exc:
        LOG.error("SNS publish failed: %s", exc)
