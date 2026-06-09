#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Subscribe the hub-account throttle Lambda to every sandbox account's
# SNS topic created by member-stack.yaml. Run after StackSet deployment
# completes, and again whenever new sandbox accounts join the pool.
#
# Discovers sandbox accounts by listing accounts under all child OUs of
# PARENT_OU_ID. For each account, it confirms the SNS topic exists, then:
#   1. Adds a topic policy statement allowing the hub Lambda to subscribe.
#      (member-stack.yaml already does this, so we just confirm.)
#   2. From the hub side, calls sns:Subscribe with the cross-account ARN.
#
# Usage:
#   ./scripts/cost-controls/subscribe-member-topics.sh [--region ap-southeast-1]

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)    REGION="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"

# Resolve ISB pool OU (do NOT use .env PARENT_OU_ID — it may point to the org root).
if [[ -z "${ISB_ACCOUNT_POOL_OU_ID:-}" ]]; then
  ISB_ACCOUNT_POOL_OU_ID=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$(aws organizations list-roots --profile "$MGT_PROFILE" --query 'Roots[0].Id' --output text)" \
    --profile "$MGT_PROFILE" \
    --query "OrganizationalUnits[?Name=='${NAMESPACE}_InnovationSandboxAccountPool'].Id | [0]" \
    --output text)
  [[ -z "$ISB_ACCOUNT_POOL_OU_ID" || "$ISB_ACCOUNT_POOL_OU_ID" == "None" ]] \
    && { echo "ERROR: cannot resolve ISB pool OU"; exit 1; }
fi

log()  { printf "\033[1;36m[subscribe]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }

LAMBDA_ARN="arn:aws:lambda:${REGION}:${HUB_ACCOUNT_ID}:function:isb-${NAMESPACE}-bedrock-throttle-handler"

log "Listing sandbox accounts under $ISB_ACCOUNT_POOL_OU_ID"
ACCOUNTS=()
for ou in $(aws organizations list-children --parent-id "$ISB_ACCOUNT_POOL_OU_ID" \
              --child-type ORGANIZATIONAL_UNIT \
              --profile "$MGT_PROFILE" --query 'Children[].Id' --output text); do
  while read -r acct; do
    [[ -n "$acct" ]] && ACCOUNTS+=("$acct")
  done < <(aws organizations list-accounts-for-parent --parent-id "$ou" \
            --profile "$MGT_PROFILE" --query 'Accounts[?Status==`ACTIVE`].Id' --output text | tr '\t' '\n')
done

log "Found ${#ACCOUNTS[@]} active sandbox accounts"

SUBSCRIBED=0
SKIPPED=0
DEDUPED=0
FAILED=0
LIST_PERM_ERR=0

for acct in "${ACCOUNTS[@]}"; do
  TOPIC_ARN="arn:aws:sns:${REGION}:${acct}:isb-${NAMESPACE}-bedrock-throttle-trigger"
  STATEMENT_ID="sns-${acct}"

  # 1. Allow SNS in this member account to invoke our Lambda (idempotent — ResourceConflict ignored).
  aws lambda add-permission \
    --function-name "$LAMBDA_ARN" \
    --statement-id "$STATEMENT_ID" \
    --action lambda:InvokeFunction \
    --principal sns.amazonaws.com \
    --source-arn "$TOPIC_ARN" \
    --region "$REGION" --profile "$HUB_PROFILE" >/dev/null 2>&1 || true

  # 2. List existing subs and dedupe to a single subscription
  LIST_OUT=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
             --region "$REGION" --profile "$HUB_PROFILE" --output json 2>&1) || {
    LIST_PERM_ERR=$((LIST_PERM_ERR+1))
    warn "  list-subscriptions denied for $acct (topic policy may be outdated — re-deploy member stackset)"
    continue
  }

  EXISTING_SUBS=$(echo "$LIST_OUT" | python3 -c "
import json,sys
data = json.load(sys.stdin)
arn = '$LAMBDA_ARN'
print('\n'.join([s['SubscriptionArn'] for s in data.get('Subscriptions', [])
                 if s.get('Endpoint') == arn and s['SubscriptionArn'].startswith('arn:')]))
")
  EX_COUNT=$(echo -n "$EXISTING_SUBS" | grep -c '^arn:' || true)

  if [[ "$EX_COUNT" -ge 1 ]]; then
    if [[ "$EX_COUNT" -gt 1 ]]; then
      # Keep the first, unsubscribe the rest
      KEPT=0
      while read -r sub_arn; do
        [[ -z "$sub_arn" ]] && continue
        if [[ "$KEPT" -eq 0 ]]; then
          KEPT=1
          continue
        fi
        aws sns unsubscribe --subscription-arn "$sub_arn" \
          --region "$REGION" --profile "$HUB_PROFILE" >/dev/null 2>&1 && \
          DEDUPED=$((DEDUPED+1))
      done <<< "$EXISTING_SUBS"
      printf "  \033[1;33m⊖\033[0m %s (deduped %d → 1)\n" "$acct" "$EX_COUNT"
    else
      SKIPPED=$((SKIPPED+1))
    fi
    continue
  fi

  # 3. Subscribe
  if aws sns subscribe \
       --topic-arn "$TOPIC_ARN" \
       --protocol lambda \
       --notification-endpoint "$LAMBDA_ARN" \
       --region "$REGION" --profile "$HUB_PROFILE" >/dev/null 2>&1; then
    SUBSCRIBED=$((SUBSCRIBED+1))
    printf "  \033[1;32m✓\033[0m %s\n" "$acct"
  else
    FAILED=$((FAILED+1))
    warn "  failed to subscribe to $TOPIC_ARN (member stack may not be deployed yet)"
  fi
done

log "Subscribed: $SUBSCRIBED | Already-subscribed: $SKIPPED | Deduped: $DEDUPED | Failed: $FAILED | List-perm-denied: $LIST_PERM_ERR"
if [[ "$LIST_PERM_ERR" -gt 0 ]]; then
  warn "Some accounts had old topic policies. Re-deploy the StackSet to push the new policy, then re-run this script."
fi
