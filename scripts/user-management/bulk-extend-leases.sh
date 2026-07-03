#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bulk extend all active leases matching a filter.
#
# Usage:
#   ./scripts/user-management/bulk-extend-leases.sh [options]
#
# Options:
#   --hours <N>             Add N hours to each lease (default: 48)
#   --budget <N>            Set new max budget (default: keep current)
#   --group <name>          Only extend leases in this costReportGroup
#   --expiring-within <N>   Only extend leases expiring within N hours (default: all active)
#   --dry-run               Show what would be extended without making changes
#
# Examples:
#   # Extend all MMU finalist leases by 7 days
#   ./scripts/user-management/bulk-extend-leases.sh --group cendekiawan-mmu-finalist --hours 168
#
#   # Extend leases expiring within 24 hours by 48h (dry run first)
#   ./scripts/user-management/bulk-extend-leases.sh --expiring-within 24 --hours 48 --dry-run
#
#   # Extend all active leases and increase budget to $100
#   ./scripts/user-management/bulk-extend-leases.sh --hours 168 --budget 100

set -euo pipefail

EXTEND_HOURS=48
NEW_BUDGET=""
FILTER_GROUP=""
EXPIRING_WITHIN=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) EXTEND_HOURS="$2"; shift 2;;
    --budget) NEW_BUDGET="$2"; shift 2;;
    --group) FILTER_GROUP="$2"; shift 2;;
    --expiring-within) EXPIRING_WITHIN="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    *) echo "Unknown: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

# Get API endpoint
API_ENDPOINT="${ISB_API_ENDPOINT:-}"
if [[ -z "$API_ENDPOINT" ]]; then
  API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Compute \
    --profile "$HUB_PROFILE" --region "$REGION" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'RestApi')].OutputValue" --output text)
fi

log() { printf "\033[1;36m[bulk-extend]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }

if [[ -z "${ISB_TOKEN:-}" ]]; then
  err "ISB_TOKEN not set. Export your admin JWT token first."
  exit 1
fi

log "Fetching active leases..."
ALL_LEASES=$(curl -sf "${API_ENDPOINT}leases" \
  -H "Authorization: Bearer ${ISB_TOKEN}" \
  -H "Content-Type: application/json")

# Filter to active/frozen leases and apply group/expiry filters
FILTERED=$(echo "$ALL_LEASES" | python3 -c "
import json, sys
from datetime import datetime, timedelta, timezone

data = json.load(sys.stdin)
leases = data.get('data', data) if isinstance(data, dict) else data
if isinstance(leases, dict) and 'leases' in leases:
    leases = leases['leases']
elif isinstance(leases, dict) and 'data' in leases:
    leases = leases['data']
    if isinstance(leases, dict) and 'leases' in leases:
        leases = leases['leases']

filter_group = '${FILTER_GROUP}'
expiring_within = '${EXPIRING_WITHIN}'
now = datetime.now(timezone.utc)

results = []
for lease in (leases if isinstance(leases, list) else []):
    status = lease.get('status', '')
    if status not in ('Active', 'Frozen'):
        continue
    
    if filter_group and lease.get('costReportGroup', '') != filter_group:
        continue
    
    if expiring_within:
        expiry = lease.get('expirationDate', '')
        if expiry:
            exp_dt = datetime.fromisoformat(expiry.replace('Z', '+00:00'))
            hours_left = (exp_dt - now).total_seconds() / 3600
            if hours_left > float(expiring_within):
                continue
    
    results.append({
        'uuid': lease.get('uuid', ''),
        'userEmail': lease.get('userEmail', ''),
        'expirationDate': lease.get('expirationDate', ''),
        'maxSpend': lease.get('maxSpend', ''),
        'costReportGroup': lease.get('costReportGroup', ''),
        'status': status,
    })

print(json.dumps(results))
")

COUNT=$(echo "$FILTERED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

log "Found $COUNT leases matching filters:"
[[ -n "$FILTER_GROUP" ]] && log "  Group: $FILTER_GROUP"
[[ -n "$EXPIRING_WITHIN" ]] && log "  Expiring within: ${EXPIRING_WITHIN}h"
log "  Extend by: +${EXTEND_HOURS}h"
[[ -n "$NEW_BUDGET" ]] && log "  New budget: \$$NEW_BUDGET"
echo

if [[ "$COUNT" == "0" ]]; then
  log "No leases to extend."
  exit 0
fi

# Show summary
echo "$FILTERED" | python3 -c "
import json, sys
leases = json.load(sys.stdin)
print(f'{'ID':<40} {'User':<40} {'Expires':<25} {'Budget':<8} {'Group'}')
print('-' * 130)
for l in leases:
    print(f\"{l['uuid']:<40} {l['userEmail']:<40} {l['expirationDate'][:19]:<25} \${l['maxSpend']:<7} {l['costReportGroup']}\")
"
echo

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN — no changes made. Remove --dry-run to apply."
  exit 0
fi

# Confirm
read -rp "Extend $COUNT leases by ${EXTEND_HOURS}h? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  log "Cancelled."
  exit 0
fi

# Execute extensions
SUCCESS=0
FAILED=0

echo "$FILTERED" | python3 -c "import json,sys; [print(l['uuid']) for l in json.load(sys.stdin)]" | while read -r LEASE_UUID; do
  if "$ROOT/scripts/user-management/extend-lease.sh" "$LEASE_UUID" \
      --hours "$EXTEND_HOURS" \
      ${NEW_BUDGET:+--budget "$NEW_BUDGET"} 2>&1 | grep -q "extended successfully"; then
    ((SUCCESS++)) || true
  else
    ((FAILED++)) || true
    err "Failed to extend: $LEASE_UUID"
  fi
done

echo
log "Done. Extended: $SUCCESS, Failed: $FAILED"
