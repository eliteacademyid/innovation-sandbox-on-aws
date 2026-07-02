# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Rate Limit — Throttle Handler (SCP-based).

Triggered by SNS messages from CloudWatch alarms in member sandbox accounts.
Creates a deny-Bedrock SCP in the management account and attaches it directly
to the offending sandbox account. Records the event in DynamoDB.

Environment variables:
- NAMESPACE                   e.g. "myisb"
- THROTTLE_TABLE_NAME         DynamoDB table for throttle state
- THROTTLE_DURATION_SECONDS   Default lifetime for a throttle (e.g. 3600)
- NOTIFICATION_TOPIC_ARN      SNS topic ARN for admin email notifications
- ORG_ROLE_ARN                Role ARN in management account with Organizations permissions
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
ORG_ROLE_ARN = os.environ["ORG_ROLE_ARN"]

SCP_POLICY_CONTENT = json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "BedrockRateLimitDeny",
        "Effect": "Deny",
        "Action": "bedrock:*",
        "Resource": "*",
    }],
})

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
        except Exception as exc:
            LOG.exception("Failed handling record: %s", exc)
            results.append({"status": "error", "error": str(exc)})
    return {"results": results}


def _handle_record(record: dict[str, Any]) -> dict[str, Any]:
    sns_msg = json.loads(record["Sns"]["Message"])
    alarm_name = sns_msg.get("AlarmName", "unknown")
    new_state = sns_msg.get("NewStateValue")

    if new_state != "ALARM":
        LOG.info("ignoring non-ALARM transition (%s) for %s", new_state, alarm_name)
        return {"status": "ignored", "reason": "non-alarm-state", "alarm": alarm_name}

    member_account_id = sns_msg.get("AWSAccountId") or _account_from_alarm_arn(sns_msg)
    if not member_account_id:
        raise RuntimeError("Could not derive account ID from SNS message")

    metric_kind = "TPM" if "tpm" in alarm_name.lower() else "RPM"
    LOG.info("throttling account=%s alarm=%s kind=%s", member_account_id, alarm_name, metric_kind)

    # Create + attach SCP via management account role
    orgs = _get_orgs_client()
    scp_name = f"isb-{NAMESPACE}-bedrock-deny-{member_account_id}"

    # Check if SCP already exists (idempotent)
    policy_id = _find_existing_scp(orgs, scp_name)
    if not policy_id:
        resp = orgs.create_policy(
            Content=SCP_POLICY_CONTENT,
            Description=f"Auto-throttle: deny Bedrock for account {member_account_id}",
            Name=scp_name,
            Type="SERVICE_CONTROL_POLICY",
        )
        policy_id = resp["Policy"]["PolicySummary"]["Id"]
        LOG.info("created SCP %s (%s)", scp_name, policy_id)

    # Attach to the specific account
    try:
        orgs.attach_policy(PolicyId=policy_id, TargetId=member_account_id)
        LOG.info("attached SCP %s to account %s", policy_id, member_account_id)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "DuplicatePolicyAttachmentException":
            LOG.info("SCP already attached to %s", member_account_id)
        else:
            raise

    now = int(time.time())
    expires_at = now + THROTTLE_DURATION_SECONDS
    item = {
        "account_id": member_account_id,
        "throttled_at": now,
        "expires_at": expires_at,
        "reason": metric_kind,
        "alarm_name": alarm_name,
        "scp_policy_id": policy_id,
        "scp_name": scp_name,
        "status": "ACTIVE",
    }
    table.put_item(Item=item)

    _send_notification(
        subject=f"[ISB] Bedrock throttle applied — account {member_account_id}",
        body=(
            f"Bedrock rate-limit throttle applied via SCP.\n\n"
            f"Account ID:      {member_account_id}\n"
            f"Reason:          {metric_kind} threshold breached\n"
            f"Alarm:           {alarm_name}\n"
            f"SCP:             {scp_name} ({policy_id})\n"
            f"Throttled at:    {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(now))}\n"
            f"Auto-recovers:   {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(expires_at))}\n\n"
            f"To unfreeze early:\n"
            f"  ./scripts/cost-controls/unfreeze-bedrock.sh {member_account_id}\n"
        ),
    )

    return {"status": "throttled", "account_id": member_account_id, "expires_at": expires_at}


def _get_orgs_client():
    creds = sts.assume_role(RoleArn=ORG_ROLE_ARN, RoleSessionName="isb-bedrock-throttle")["Credentials"]
    return boto3.client(
        "organizations",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _find_existing_scp(orgs, scp_name: str) -> str | None:
    paginator = orgs.get_paginator("list_policies")
    for page in paginator.paginate(Filter="SERVICE_CONTROL_POLICY"):
        for policy in page["Policies"]:
            if policy["Name"] == scp_name:
                return policy["Id"]
    return None


def _account_from_alarm_arn(sns_msg: dict[str, Any]) -> str | None:
    parts = sns_msg.get("AlarmArn", "").split(":")
    return parts[4] if len(parts) >= 5 and parts[4].isdigit() else None


def _send_notification(subject: str, body: str) -> None:
    try:
        sns.publish(TopicArn=NOTIFICATION_TOPIC_ARN, Subject=subject[:100], Message=body)
    except ClientError as exc:
        LOG.error("SNS publish failed: %s", exc)
