# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Rate Limit — Throttle Handler.

Triggered by SNS messages from CloudWatch alarms in member sandbox accounts.
Assumes a cross-account role into the offending sandbox account, finds the
SSO IsbUsers role, and attaches an inline deny-Bedrock policy. Records the
throttle event in DynamoDB with an expiry timestamp so the recovery Lambda
can lift it later. Publishes a notification to the admin SNS topic.

Environment variables:
- NAMESPACE                   e.g. "myisb"
- THROTTLE_TABLE_NAME         DynamoDB table for throttle state
- THROTTLE_DURATION_SECONDS   Default lifetime for a throttle (e.g. 3600)
- NOTIFICATION_TOPIC_ARN      SNS topic ARN for admin email notifications
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
THROTTLE_TABLE_NAME = os.environ["THROTTLE_TABLE_NAME"]
THROTTLE_DURATION_SECONDS = int(os.environ.get("THROTTLE_DURATION_SECONDS", "3600"))
NOTIFICATION_TOPIC_ARN = os.environ["NOTIFICATION_TOPIC_ARN"]

DENY_POLICY_NAME = "BedrockRateLimitDeny"
DENY_POLICY_DOCUMENT = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "BedrockRateLimitDeny",
            "Effect": "Deny",
            "Action": "bedrock:*",
            "Resource": "*",
        }
    ],
}

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
sts = boto3.client("sts")
table = dynamodb.Table(THROTTLE_TABLE_NAME)


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    LOG.info("event=%s", json.dumps(event))
    results: list[dict[str, Any]] = []
    for record in event.get("Records", []):
        try:
            results.append(_handle_record(record))
        except Exception as exc:  # pragma: no cover - top-level safety net
            LOG.exception("Failed handling record: %s", exc)
            results.append({"status": "error", "error": str(exc)})
    return {"results": results}


def _handle_record(record: dict[str, Any]) -> dict[str, Any]:
    sns_msg_raw = record["Sns"]["Message"]
    sns_msg = json.loads(sns_msg_raw)

    alarm_name = sns_msg.get("AlarmName", "unknown")
    new_state = sns_msg.get("NewStateValue")
    if new_state != "ALARM":
        LOG.info("ignoring non-ALARM transition (%s) for %s", new_state, alarm_name)
        return {"status": "ignored", "reason": "non-alarm-state", "alarm": alarm_name}

    # SNS comes from the alarm's source account
    member_account_id = sns_msg.get("AWSAccountId") or _account_from_alarm_arn(sns_msg)
    if not member_account_id:
        raise RuntimeError(f"Could not derive AWS account id from SNS message {sns_msg_raw}")

    metric_kind = "TPM" if "tpm" in alarm_name.lower() else "RPM"
    LOG.info("throttling account=%s alarm=%s kind=%s", member_account_id, alarm_name, metric_kind)

    creds = _assume_role(member_account_id)
    iam = _iam_client(creds)
    sso_role_name = _find_sso_isb_users_role(iam)

    iam.put_role_policy(
        RoleName=sso_role_name,
        PolicyName=DENY_POLICY_NAME,
        PolicyDocument=json.dumps(DENY_POLICY_DOCUMENT),
    )
    LOG.info("attached deny policy to role=%s in account=%s", sso_role_name, member_account_id)

    now = int(time.time())
    expires_at = now + THROTTLE_DURATION_SECONDS
    item = {
        "account_id": member_account_id,
        "throttled_at": now,
        "expires_at": expires_at,
        "reason": metric_kind,
        "alarm_name": alarm_name,
        "alarm_arn": sns_msg.get("AlarmArn", ""),
        "sso_role_name": sso_role_name,
        "status": "ACTIVE",
    }
    table.put_item(Item=item)

    _send_notification(
        subject=f"[ISB] Bedrock throttle applied — account {member_account_id}",
        body=_build_notification_body(item, sns_msg),
    )

    return {"status": "throttled", "account_id": member_account_id, "expires_at": expires_at}


def _account_from_alarm_arn(sns_msg: dict[str, Any]) -> str | None:
    arn = sns_msg.get("AlarmArn", "")
    parts = arn.split(":")
    if len(parts) >= 5 and parts[4].isdigit():
        return parts[4]
    return None


def _assume_role(member_account_id: str) -> dict[str, str]:
    role_arn = f"arn:aws:iam::{member_account_id}:role/isb-{NAMESPACE}-bedrock-throttle-role"
    resp = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName="isb-bedrock-throttle",
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
    """Find the AWSReservedSSO_<namespace>_IsbUsers_<hash> role in the target account."""
    needle = f"AWSReservedSSO_{NAMESPACE}_IsbUsers_"
    paginator = iam.get_paginator("list_roles")
    for page in paginator.paginate(PathPrefix="/aws-reserved/sso.amazonaws.com/"):
        for role in page["Roles"]:
            if role["RoleName"].startswith(needle):
                return role["RoleName"]
    raise RuntimeError(f"No SSO role matching {needle}* found in target account")


def _send_notification(subject: str, body: str) -> None:
    try:
        sns.publish(TopicArn=NOTIFICATION_TOPIC_ARN, Subject=subject[:100], Message=body)
    except ClientError as exc:
        LOG.error("SNS publish failed: %s", exc)


def _build_notification_body(item: dict[str, Any], sns_msg: dict[str, Any]) -> str:
    return (
        f"Bedrock rate-limit throttle applied.\n\n"
        f"Account ID:      {item['account_id']}\n"
        f"Reason:          {item['reason']} threshold breached\n"
        f"Alarm:           {item['alarm_name']}\n"
        f"Throttled at:    {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(item['throttled_at']))}\n"
        f"Auto-recovers:   {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(item['expires_at']))}\n"
        f"SSO role:        {item['sso_role_name']}\n\n"
        f"Alarm description:\n{sns_msg.get('AlarmDescription', '')}\n\n"
        f"To unfreeze early:\n"
        f"  ./scripts/cost-controls/unfreeze-bedrock.sh {item['account_id']}\n\n"
        f"To investigate:\n"
        f"  ./scripts/cost-controls/check-bedrock-incident.sh {item['account_id']}\n"
    )
