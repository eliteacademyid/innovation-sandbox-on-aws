#!/usr/bin/env bash
# ISB Bedrock Rate Limiter — 24h Soak Test Check
#
# Run this after 24h of passive monitoring to verify no false positives.
# Usage: ./scripts/cost-controls/soak-test-check.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

TABLE="isb-${NAMESPACE}-bedrock-throttle-events"
LAMBDA="isb-${NAMESPACE}-bedrock-throttle-handler"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
pass() { printf "\033[1;32m✓ PASS\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m✗ FAIL\033[0m %s\n" "$*"; }

bold "=== ISB Bedrock Rate Limiter — 24h Soak Test ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "Region: $REGION | Table: $TABLE"
echo ""

# 1. Check for any throttle events in last 24h
bold "1. Throttle events (last 24h)"
SINCE=$(date -u -v-24H '+%s' 2>/dev/null || date -u -d '24 hours ago' '+%s')
ITEMS=$(aws dynamodb scan --table-name "$TABLE" \
  --filter-expression "throttled_at > :since" \
  --expression-attribute-values "{\":since\":{\"N\":\"$SINCE\"}}" \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --query 'Count' --output text 2>/dev/null) || ITEMS=0
if [[ "$ITEMS" == "0" || "$ITEMS" == "None" ]]; then
  pass "No throttle events in last 24h"
else
  fail "$ITEMS throttle event(s) detected — check for false positives!"
  aws dynamodb scan --table-name "$TABLE" \
    --filter-expression "throttled_at > :since" \
    --expression-attribute-values "{\":since\":{\"N\":\"$SINCE\"}}" \
    --region "$REGION" --profile "$HUB_PROFILE" \
    --output table 2>/dev/null
fi

# 2. Throttle Lambda invocations
bold "2. Throttle Lambda invocations (last 24h)"
INVOCATIONS=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$LAMBDA" \
  --start-time "$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 86400 --statistics Sum \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --query 'Datapoints[0].Sum' --output text 2>/dev/null) || INVOCATIONS="None"
if [[ "$INVOCATIONS" == "None" || "$INVOCATIONS" == "0" || "$INVOCATIONS" == "0.0" ]]; then
  pass "Throttle Lambda not invoked (no alarms fired)"
else
  fail "Throttle Lambda invoked ${INVOCATIONS} time(s) — investigate!"
fi

# 3. Lambda errors
bold "3. Throttle Lambda errors (last 24h)"
ERRORS=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value="$LAMBDA" \
  --start-time "$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 86400 --statistics Sum \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --query 'Datapoints[0].Sum' --output text 2>/dev/null) || ERRORS="None"
if [[ "$ERRORS" == "None" || "$ERRORS" == "0" || "$ERRORS" == "0.0" ]]; then
  pass "No Lambda errors"
else
  fail "${ERRORS} Lambda error(s) detected"
fi

# 4. Currently active throttles
bold "4. Currently active throttles"
ACTIVE=$(aws dynamodb scan --table-name "$TABLE" \
  --filter-expression "#s = :a" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":a":{"S":"ACTIVE"}}' \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --query 'Count' --output text 2>/dev/null) || ACTIVE=0
if [[ "$ACTIVE" == "0" || "$ACTIVE" == "None" ]]; then
  pass "No active throttles"
else
  fail "$ACTIVE account(s) currently throttled!"
fi

echo ""
bold "=== Soak Test Complete ==="
