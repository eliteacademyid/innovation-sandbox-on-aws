#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# EMERGENCY: throttle Bedrock in EVERY active sandbox account at once.
# Use when something looks wrong org-wide (e.g. anomalous spend, hostile script
# replicating across accounts).
#
# Effect: attaches BedrockRateLimitDeny inline policy to AWSReservedSSO_<ns>_IsbUsers_*
# in every active sandbox account. Auto-recovery still applies, so each
# throttle expires after THROTTLE_DURATION_SECONDS (default 1h).
#
# Usage:
#   ./scripts/cost-controls/kill-switch-bedrock.sh [--duration 7200]

set -euo pipefail

NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"
DURATION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION_OVERRIDE="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

# Resolve ISB pool OU (do NOT use .env PARENT_OU_ID — may be org root)
if [[ -z "${ISB_ACCOUNT_POOL_OU_ID:-}" ]]; then
  ISB_ACCOUNT_POOL_OU_ID=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$(aws organizations list-roots --profile "$MGT_PROFILE" --query 'Roots[0].Id' --output text)" \
    --profile "$MGT_PROFILE" \
    --query "OrganizationalUnits[?Name=='${NAMESPACE}_InnovationSandboxAccountPool'].Id | [0]" \
    --output text)
  [[ -z "$ISB_ACCOUNT_POOL_OU_ID" || "$ISB_ACCOUNT_POOL_OU_ID" == "None" ]] \
    && { echo "ERROR: cannot resolve ISB pool OU"; exit 1; }
fi
LAMBDA_NAME="isb-${NAMESPACE}-bedrock-throttle-handler"

log()  { printf "\033[1;31m[KILL-SWITCH]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }

log "This will throttle Bedrock in ALL active ISB sandbox accounts."
log "Auto-recovery will lift each throttle after ${DURATION_OVERRIDE:-default} seconds."
read -rp "Type EMERGENCY to confirm: " ans
[[ "$ans" == "EMERGENCY" ]] || { log "aborted"; exit 0; }

if [[ -n "$DURATION_OVERRIDE" ]]; then
  log "Updating throttle duration to ${DURATION_OVERRIDE}s"
  TOPIC_ARN=$(aws cloudformation describe-stacks \
    --stack-name "isb-${NAMESPACE}-bedrock-rate-limit-hub" \
    --region "$REGION" --profile "$HUB_PROFILE" \
    --query "Stacks[0].Outputs[?OutputKey=='AdminNotificationTopicArn'].OutputValue | [0]" --output text)
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "Variables={NAMESPACE=$NAMESPACE,THROTTLE_TABLE_NAME=isb-${NAMESPACE}-bedrock-throttle-events,THROTTLE_DURATION_SECONDS=${DURATION_OVERRIDE},NOTIFICATION_TOPIC_ARN=${TOPIC_ARN}}" \
    --region "$REGION" --profile "$HUB_PROFILE" >/dev/null
fi

log "Listing sandbox accounts under $ISB_ACCOUNT_POOL_OU_ID"
ACCOUNTS=()
for ou in $(aws organizations list-children --parent-id "$ISB_ACCOUNT_POOL_OU_ID" \
              --child-type ORGANIZATIONAL_UNIT --profile "$MGT_PROFILE" \
              --query 'Children[].Id' --output text); do
  while read -r acct; do
    [[ -n "$acct" ]] && ACCOUNTS+=("$acct")
  done < <(aws organizations list-accounts-for-parent --parent-id "$ou" \
            --profile "$MGT_PROFILE" \
            --query 'Accounts[?Status==`ACTIVE`].Id' --output text | tr '\t' '\n')
done

log "Found ${#ACCOUNTS[@]} accounts. Throttling all in parallel..."

THROTTLED=0
FAILED=0
for acct in "${ACCOUNTS[@]}"; do
  PAYLOAD=$(cat <<EOF
{
  "Records": [
    {
      "Sns": {
        "Message": "{\"AlarmName\":\"manual-kill-switch\",\"NewStateValue\":\"ALARM\",\"AWSAccountId\":\"$acct\",\"AlarmArn\":\"arn:aws:cloudwatch:$REGION:$acct:alarm:manual-kill-switch\",\"AlarmDescription\":\"Manual kill switch invoked by admin\"}"
      }
    }
  ]
}
EOF
)
  TMPFILE=$(mktemp)
  if aws lambda invoke --function-name "$LAMBDA_NAME" \
       --invocation-type RequestResponse \
       --payload "$PAYLOAD" \
       --cli-binary-format raw-in-base64-out \
       --region "$REGION" --profile "$HUB_PROFILE" \
       "$TMPFILE" >/dev/null 2>&1; then
    THROTTLED=$((THROTTLED+1))
    printf "  \033[1;31m■\033[0m %s\n" "$acct"
  else
    FAILED=$((FAILED+1))
    warn "  failed: $acct"
  fi
  rm -f "$TMPFILE"
done

log "Throttled: $THROTTLED | Failed: $FAILED"
log "Run './scripts/cost-controls/list-throttled-accounts.sh' to verify."
log "To clear all early: for a in \$(./scripts/cost-controls/list-throttled-accounts.sh -q); do ./scripts/cost-controls/unfreeze-bedrock.sh \$a; done"
