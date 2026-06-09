#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# List currently throttled sandbox accounts.
#
# Usage:
#   ./scripts/cost-controls/list-throttled-accounts.sh         # human-readable
#   ./scripts/cost-controls/list-throttled-accounts.sh -q      # account IDs only

set -euo pipefail

NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

TABLE="isb-${NAMESPACE}-bedrock-throttle-events"

ITEMS=$(aws dynamodb scan --table-name "$TABLE" \
  --filter-expression "#s = :a" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":a":{"S":"ACTIVE"}}' \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --output json 2>/dev/null) || ITEMS='{"Items":[]}'

if [[ -z "$ITEMS" ]]; then
  ITEMS='{"Items":[]}'
fi

if [[ "$QUIET" == "1" ]]; then
  echo "$ITEMS" | python3 -c '
import json, sys
for it in json.load(sys.stdin)["Items"]:
    print(it["account_id"]["S"])
'
  exit 0
fi

python3 -c '
import json, sys, time
data = json.loads(sys.argv[1])
items = sorted(data["Items"], key=lambda x: int(x["throttled_at"]["N"]))
if not items:
    print("No active throttles.")
    sys.exit(0)
print(f"{'ACCOUNT_ID':<14} {'REASON':<8} {'THROTTLED_AT':<22} {'EXPIRES_AT':<22} {'ALARM'}")
print("-" * 100)
for it in items:
    aid = it["account_id"]["S"]
    reason = it.get("reason", {"S": "?"})["S"]
    t_at = int(it["throttled_at"]["N"])
    e_at = int(it["expires_at"]["N"])
    alarm = it.get("alarm_name", {"S": "?"})["S"]
    print(f"{aid:<14} {reason:<8} "
          f"{time.strftime(chr(37)+"Y-"+chr(37)+"m-"+chr(37)+"d "+chr(37)+"H:"+chr(37)+"M:"+chr(37)+"S UTC", time.gmtime(t_at)):<22} "
          f"{time.strftime(chr(37)+"Y-"+chr(37)+"m-"+chr(37)+"d "+chr(37)+"H:"+chr(37)+"M:"+chr(37)+"S UTC", time.gmtime(e_at)):<22} "
          f"{alarm}")
' "$ITEMS"
