#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Extend an active ISB lease — adds hours to expiration and/or budget.
#
# Uses the ISB PATCH /leases/{leaseId} API endpoint (no DynamoDB hacking).
#
# Usage:
#   ./scripts/user-management/extend-lease.sh <lease-id> [options]
#
# Options:
#   --hours <N>          Add N hours to current expiration (default: 48)
#   --budget <N>         Set new max budget in dollars (default: keep current)
#   --set-expiry <ISO>   Set exact expiration datetime (overrides --hours)
#
# Examples:
#   # Extend by 48 hours (default)
#   ./scripts/user-management/extend-lease.sh 9d620998-c9a9-4404-a97c-e0b045d3a600
#
#   # Extend by 7 days
#   ./scripts/user-management/extend-lease.sh 9d620998-... --hours 168
#
#   # Extend by 48h AND increase budget to $100
#   ./scripts/user-management/extend-lease.sh 9d620998-... --hours 48 --budget 100
#
#   # Set exact expiry date
#   ./scripts/user-management/extend-lease.sh 9d620998-... --set-expiry "2026-07-15T00:00:00.000Z"
#
# Prerequisites:
#   - ISB admin JWT token (obtained via SSO login)
#   - API endpoint (from .env or auto-detected from CFN outputs)

set -euo pipefail

LEASE_ID="${1:?Usage: $0 <lease-id> [--hours N] [--budget N] [--set-expiry ISO]}"
shift

EXTEND_HOURS=48
NEW_BUDGET=""
SET_EXPIRY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) EXTEND_HOURS="$2"; shift 2;;
    --budget) NEW_BUDGET="$2"; shift 2;;
    --set-expiry) SET_EXPIRY="$2"; shift 2;;
    *) echo "Unknown: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
NAMESPACE="${NAMESPACE:-myisb}"

# Get API endpoint
API_ENDPOINT="${ISB_API_ENDPOINT:-}"
if [[ -z "$API_ENDPOINT" ]]; then
  API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Compute \
    --profile "$HUB_PROFILE" --region "$REGION" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'RestApi')].OutputValue" --output text)
fi

log() { printf "\033[1;36m[extend]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }

log "Lease ID: $LEASE_ID"
log "API:      $API_ENDPOINT"

# ─── Get current lease ─────────────────────────────────────────────────────────

# We need an admin JWT token. Check if ISB_TOKEN is set.
if [[ -z "${ISB_TOKEN:-}" ]]; then
  err "ISB_TOKEN not set. Get a token by logging into the ISB web UI and"
  err "extracting the JWT from browser DevTools → Application → Cookies → token"
  err ""
  err "Or use:"
  err "  export ISB_TOKEN=\$(curl -s '${API_ENDPOINT}auth/login' ... | jq -r '.token')"
  exit 1
fi

log "Fetching current lease..."
CURRENT=$(curl -sf "${API_ENDPOINT}leases/${LEASE_ID}" \
  -H "Authorization: Bearer ${ISB_TOKEN}" \
  -H "Content-Type: application/json")

if [[ -z "$CURRENT" || "$CURRENT" == "null" ]]; then
  err "Lease not found: $LEASE_ID"
  exit 1
fi

CURRENT_EXPIRY=$(echo "$CURRENT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('expirationDate',''))")
CURRENT_BUDGET=$(echo "$CURRENT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('maxSpend',''))")
CURRENT_USER=$(echo "$CURRENT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('userEmail',''))")
CURRENT_STATUS=$(echo "$CURRENT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('status',''))")

log "Current status:  $CURRENT_STATUS"
log "Current user:    $CURRENT_USER"
log "Current expiry:  $CURRENT_EXPIRY"
log "Current budget:  \$$CURRENT_BUDGET"
echo

if [[ "$CURRENT_STATUS" != "Active" && "$CURRENT_STATUS" != "Frozen" ]]; then
  err "Lease is not Active or Frozen (status: $CURRENT_STATUS). Cannot extend."
  exit 1
fi

# ─── Calculate new values ──────────────────────────────────────────────────────

if [[ -n "$SET_EXPIRY" ]]; then
  NEW_EXPIRY="$SET_EXPIRY"
else
  NEW_EXPIRY=$(python3 -c "
from datetime import datetime, timedelta, timezone
current = datetime.fromisoformat('${CURRENT_EXPIRY}'.replace('Z', '+00:00'))
extended = current + timedelta(hours=${EXTEND_HOURS})
print(extended.strftime('%Y-%m-%dT%H:%M:%S.000Z'))
")
fi

log "New expiry:     $NEW_EXPIRY (+${EXTEND_HOURS}h)"
[[ -n "$NEW_BUDGET" ]] && log "New budget:     \$$NEW_BUDGET"
echo

# ─── Build PATCH body ──────────────────────────────────────────────────────────

PATCH_BODY="{\"expirationDate\": \"$NEW_EXPIRY\""
[[ -n "$NEW_BUDGET" ]] && PATCH_BODY="${PATCH_BODY}, \"maxSpend\": $NEW_BUDGET"
PATCH_BODY="${PATCH_BODY}}"

log "Applying extension..."
RESPONSE=$(curl -sf -X PATCH "${API_ENDPOINT}leases/${LEASE_ID}" \
  -H "Authorization: Bearer ${ISB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PATCH_BODY")

if echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='success'" 2>/dev/null; then
  log "✅ Lease extended successfully!"
  log "   User:    $CURRENT_USER"
  log "   Expiry:  $CURRENT_EXPIRY → $NEW_EXPIRY"
  [[ -n "$NEW_BUDGET" ]] && log "   Budget:  \$$CURRENT_BUDGET → \$$NEW_BUDGET"
else
  err "Extension failed:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi
