#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Investigation helper. For a given sandbox account, shows:
#   1. Recent throttle history from DynamoDB
#   2. Bedrock CloudWatch metrics for the last 1 hour (TPM + RPM)
#   3. Whether the deny inline policy is currently attached
#
# Usage:
#   ./scripts/cost-controls/check-bedrock-incident.sh <account-id>

set -euo pipefail

ACCOUNT_ID="${1:?account-id required}"
NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

TABLE="isb-${NAMESPACE}-bedrock-throttle-events"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }

bold "=== Throttle history for account $ACCOUNT_ID ==="
aws dynamodb query --table-name "$TABLE" \
  --key-condition-expression "account_id = :a" \
  --expression-attribute-values "{\":a\":{\"S\":\"$ACCOUNT_ID\"}}" \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --output json | python3 - <<'PY'
import json, sys, time
data = json.load(sys.stdin)
items = sorted(data.get("Items", []), key=lambda x: -int(x["throttled_at"]["N"]))
if not items:
    print("  No throttle records.")
else:
    for it in items[:10]:
        t_at = int(it["throttled_at"]["N"])
        e_at = int(it["expires_at"]["N"])
        st = it.get("status", {"S": "?"})["S"]
        rs = it.get("reason", {"S": "?"})["S"]
        al = it.get("alarm_name", {"S": "?"})["S"]
        print(f"  [{st:<8}] {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(t_at))}  "
              f"reason={rs}  expires={time.strftime('%H:%M:%S', time.gmtime(e_at))}  alarm={al}")
PY

bold ""
bold "=== Bedrock metrics (last 1 hour) — call from member account ==="
echo "  Note: requires assuming role into $ACCOUNT_ID. Skipping if no member profile."
MEMBER_PROFILE="${MEMBER_PROFILE:-}"
if [[ -z "$MEMBER_PROFILE" ]]; then
  echo "  (Set MEMBER_PROFILE env var to a profile with read access to $ACCOUNT_ID and re-run.)"
else
  END=$(date -u +%s)
  START=$((END - 3600))
  for metric in InputTokenCount OutputTokenCount Invocations; do
    SUM=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/Bedrock --metric-name "$metric" \
      --start-time "$(date -u -r "$START" +%FT%TZ 2>/dev/null || date -u -d "@$START" +%FT%TZ)" \
      --end-time   "$(date -u -r "$END"   +%FT%TZ 2>/dev/null || date -u -d "@$END"   +%FT%TZ)" \
      --period 300 --statistics Sum \
      --region "$REGION" --profile "$MEMBER_PROFILE" \
      --query 'Datapoints[].Sum' --output text 2>/dev/null \
      | awk '{s+=$1} END {printf "%.0f\n", s}')
    printf "  %-20s %s\n" "$metric (1h sum):" "$SUM"
  done
fi

bold ""
bold "=== Deny policy state (call from hub Lambda role) ==="
echo "  To check: aws iam get-role-policy --role-name AWSReservedSSO_${NAMESPACE}_IsbUsers_<hash> --policy-name BedrockRateLimitDeny"
echo "  (must be run after assuming the throttle role into the account)"
