#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Manually clear a Bedrock rate-limit throttle for one sandbox account.
# Removes the deny inline policy from the SSO IsbUsers role and marks
# any ACTIVE throttle records in DynamoDB as CLEARED.
#
# Usage:
#   ./scripts/cost-controls/unfreeze-bedrock.sh <account-id>

set -euo pipefail

ACCOUNT_ID="${1:?account-id required}"
NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

TABLE="isb-${NAMESPACE}-bedrock-throttle-events"
LAMBDA_NAME="isb-${NAMESPACE}-bedrock-recovery-handler"

log()  { printf "\033[1;36m[unfreeze]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

log "Forcing throttle expiry on account $ACCOUNT_ID then invoking recovery"

# Set expires_at to past for any ACTIVE record so the recovery Lambda picks it up
ITEMS=$(aws dynamodb query --table-name "$TABLE" \
  --key-condition-expression "account_id = :a" \
  --expression-attribute-values "{\":a\":{\"S\":\"$ACCOUNT_ID\"}}" \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --query 'Items[?#s.S==`ACTIVE`]' \
  --expression-attribute-names '{"#s":"status"}' \
  --output json 2>/dev/null || echo '[]')

COUNT=$(echo "$ITEMS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [[ "$COUNT" == "0" ]]; then
  log "No ACTIVE throttle records found — running recovery anyway in case of stale policy"
else
  log "Found $COUNT ACTIVE throttle record(s). Forcing expiry..."
  echo "$ITEMS" | python3 -c '
import json, sys
for it in json.load(sys.stdin):
    print(it["throttled_at"]["N"])
' | while read -r ts; do
    aws dynamodb update-item --table-name "$TABLE" \
      --key "{\"account_id\":{\"S\":\"$ACCOUNT_ID\"},\"throttled_at\":{\"N\":\"$ts\"}}" \
      --update-expression "SET expires_at = :z" \
      --expression-attribute-values '{":z":{"N":"0"}}' \
      --region "$REGION" --profile "$HUB_PROFILE" >/dev/null
  done
fi

log "Invoking recovery Lambda synchronously"
TMPFILE=$(mktemp)
aws lambda invoke --function-name "$LAMBDA_NAME" \
  --invocation-type RequestResponse \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region "$REGION" --profile "$HUB_PROFILE" \
  "$TMPFILE" >/dev/null
log "Result: $(cat "$TMPFILE")"
rm -f "$TMPFILE"
log "Done. Bedrock access should be restored within 1 minute."
