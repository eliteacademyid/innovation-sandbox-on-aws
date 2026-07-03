#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Per-program cost report — shows spending breakdown by costReportGroup.
#
# Usage:
#   ./scripts/cost-controls/program-cost-report.sh [--group <name>] [--format csv]
#
# Examples:
#   # All programs summary
#   ./scripts/cost-controls/program-cost-report.sh
#
#   # Specific program detail
#   ./scripts/cost-controls/program-cost-report.sh --group cendekiawan-mmu-finalist
#
#   # Export as CSV
#   ./scripts/cost-controls/program-cost-report.sh --format csv > report.csv

set -euo pipefail

FILTER_GROUP=""
FORMAT="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) FILTER_GROUP="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    *) echo "Unknown: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

REGION="${REGION:-ap-southeast-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
NAMESPACE="${NAMESPACE:-myisb}"

# Get table name
LEASES_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LeaseTable'].OutputValue" --output text)

# Query all leases
LEASES=$(aws dynamodb scan --table-name "$LEASES_TABLE" \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --output json)

# Process with Python
python3 - "$FILTER_GROUP" "$FORMAT" <<'PYTHON' "$LEASES"
import json, sys
from datetime import datetime, timezone
from collections import defaultdict

filter_group = sys.argv[1]
format_type = sys.argv[2]
data = json.loads(sys.argv[3])
items = data.get("Items", [])

# Parse DynamoDB format
def parse_val(v):
    if isinstance(v, dict):
        if "S" in v: return v["S"]
        if "N" in v: return float(v["N"])
        if "M" in v: return {k: parse_val(val) for k, val in v["M"].items()}
        if "L" in v: return [parse_val(i) for i in v["L"]]
        if "BOOL" in v: return v["BOOL"]
        if "NULL" in v: return None
    return v

leases = []
for item in items:
    lease = {k: parse_val(v) for k, v in item.items()}
    leases.append(lease)

# Group by costReportGroup
groups = defaultdict(lambda: {
    "leases": [],
    "total_cost": 0,
    "total_budget": 0,
    "active": 0,
    "expired": 0,
    "terminated": 0,
    "frozen": 0,
})

for lease in leases:
    group = lease.get("costReportGroup", "default")
    if filter_group and group != filter_group:
        continue
    
    cost = float(lease.get("totalCostAccrued", 0) or 0)
    budget = float(lease.get("maxSpend", 0) or 0)
    status = lease.get("status", "")
    
    g = groups[group]
    g["leases"].append(lease)
    g["total_cost"] += cost
    g["total_budget"] += budget
    
    if status == "Active": g["active"] += 1
    elif status == "Expired": g["expired"] += 1
    elif status == "Terminated": g["terminated"] += 1
    elif status == "Frozen": g["frozen"] += 1

now = datetime.now(timezone.utc)

if format_type == "csv":
    # CSV output
    if filter_group:
        # Detail: per-lease breakdown
        print("lease_id,user_email,account_id,status,cost_accrued,max_budget,start_date,expiration_date,group")
        for lease in groups[filter_group]["leases"]:
            print(f"{lease.get('uuid','')},{lease.get('userEmail','')},{lease.get('awsAccountId','')},{lease.get('status','')},{lease.get('totalCostAccrued',0)},{lease.get('maxSpend','')},{lease.get('startDate','')},{lease.get('expirationDate','')},{filter_group}")
    else:
        # Summary: per-group
        print("program,total_leases,active,expired,terminated,total_cost_usd,total_budget_usd,utilization_pct")
        for group, g in sorted(groups.items()):
            total = len(g["leases"])
            util = round((g["total_cost"] / g["total_budget"] * 100), 1) if g["total_budget"] > 0 else 0
            print(f"{group},{total},{g['active']},{g['expired']},{g['terminated']},{g['total_cost']:.2f},{g['total_budget']:.2f},{util}")
else:
    # Table output
    if not groups:
        print("No leases found.")
        sys.exit(0)
    
    print(f"\n{'═' * 80}")
    print(f"  ISB Per-Program Cost Report — {now.strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"{'═' * 80}\n")
    
    if filter_group:
        # Detail view for one program
        g = groups[filter_group]
        print(f"  Program: {filter_group}")
        print(f"  Total leases: {len(g['leases'])} (Active: {g['active']}, Expired: {g['expired']}, Terminated: {g['terminated']})")
        print(f"  Total spent: ${g['total_cost']:.2f} / ${g['total_budget']:.2f} budget ({g['total_cost']/g['total_budget']*100:.1f}% utilized)")
        print()
        print(f"  {'User':<40} {'Account':<14} {'Status':<12} {'Spent':<10} {'Budget':<10}")
        print(f"  {'─'*40} {'─'*14} {'─'*12} {'─'*10} {'─'*10}")
        for lease in sorted(g["leases"], key=lambda l: float(l.get("totalCostAccrued", 0) or 0), reverse=True):
            user = lease.get("userEmail", "?")[:38]
            acct = lease.get("awsAccountId", "?")
            status = lease.get("status", "?")
            cost = float(lease.get("totalCostAccrued", 0) or 0)
            budget = lease.get("maxSpend", "?")
            print(f"  {user:<40} {acct:<14} {status:<12} ${cost:<9.2f} ${budget}")
    else:
        # Summary view
        grand_total_cost = sum(g["total_cost"] for g in groups.values())
        grand_total_budget = sum(g["total_budget"] for g in groups.values())
        grand_total_leases = sum(len(g["leases"]) for g in groups.values())
        
        print(f"  {'Program':<35} {'Leases':<8} {'Active':<8} {'Spent':<12} {'Budget':<12} {'Util%':<8}")
        print(f"  {'─'*35} {'─'*8} {'─'*8} {'─'*12} {'─'*12} {'─'*8}")
        
        for group, g in sorted(groups.items(), key=lambda x: x[1]["total_cost"], reverse=True):
            total = len(g["leases"])
            util = round((g["total_cost"] / g["total_budget"] * 100), 1) if g["total_budget"] > 0 else 0
            print(f"  {group:<35} {total:<8} {g['active']:<8} ${g['total_cost']:<11.2f} ${g['total_budget']:<11.2f} {util}%")
        
        print(f"  {'─'*35} {'─'*8} {'─'*8} {'─'*12} {'─'*12} {'─'*8}")
        grand_util = round((grand_total_cost / grand_total_budget * 100), 1) if grand_total_budget > 0 else 0
        print(f"  {'TOTAL':<35} {grand_total_leases:<8} {'':<8} ${grand_total_cost:<11.2f} ${grand_total_budget:<11.2f} {grand_util}%")
    
    print(f"\n{'═' * 80}\n")
PYTHON
