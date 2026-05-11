#!/bin/bash

# ISB Health Check Script
# Provides a quick dashboard-style health overview

set -e

# Configuration
PROFILE_HUB="eta-isb-andrian"
PROFILE_MGMT="eta-andrian"
REGION="ap-southeast-3"
TABLE_NAME="InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94"
STATE_MACHINE_ARN="arn:aws:states:ap-southeast-3:147826551593:stateMachine:AccountCleanerStepFunctionStateMachineF32685E8-Fz5UGtEOpyyX"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get current timestamp
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Header
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                              ║${NC}"
echo -e "${CYAN}║          Innovation Sandbox - Health Dashboard              ║${NC}"
echo -e "${CYAN}║                                                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}  $TIMESTAMP${NC}"
echo ""

# Section 1: Account Status
echo -e "${BLUE}┌─ ACCOUNT STATUS ────────────────────────────────────────────┐${NC}"

ACCOUNTS=$(aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" 2>/dev/null || echo "")

if [ -n "$ACCOUNTS" ]; then
  TOTAL=$(echo "$ACCOUNTS" | jq '.Items | length')
  AVAILABLE=$(echo "$ACCOUNTS" | jq '[.Items[] | select(.status.S == "Available")] | length')
  ACTIVE=$(echo "$ACCOUNTS" | jq '[.Items[] | select(.status.S == "Active")] | length')
  CLEANUP=$(echo "$ACCOUNTS" | jq '[.Items[] | select(.status.S == "CleanUp")] | length')
  QUARANTINE=$(echo "$ACCOUNTS" | jq '[.Items[] | select(.status.S == "Quarantine")] | length')
  FROZEN=$(echo "$ACCOUNTS" | jq '[.Items[] | select(.status.S == "Frozen")] | length')
  
  echo -e "  Total Accounts:    ${CYAN}$TOTAL${NC}"
  echo -e "  ${GREEN}Available:         $AVAILABLE${NC}"
  echo -e "  ${BLUE}Active (leased):   $ACTIVE${NC}"
  echo -e "  ${YELLOW}CleanUp:           $CLEANUP${NC}"
  echo -e "  ${RED}Quarantine:        $QUARANTINE${NC}"
  echo -e "  ${RED}Frozen:            $FROZEN${NC}"
  
  # Visual bar chart
  echo ""
  echo -e "  Status Distribution:"
  if [ $AVAILABLE -gt 0 ]; then
    BAR=$(printf '█%.0s' $(seq 1 $((AVAILABLE * 50 / TOTAL))))
    echo -e "  ${GREEN}Available   $BAR $AVAILABLE${NC}"
  fi
  if [ $ACTIVE -gt 0 ]; then
    BAR=$(printf '█%.0s' $(seq 1 $((ACTIVE * 50 / TOTAL))))
    echo -e "  ${BLUE}Active      $BAR $ACTIVE${NC}"
  fi
  if [ $CLEANUP -gt 0 ]; then
    BAR=$(printf '█%.0s' $(seq 1 $((CLEANUP * 50 / TOTAL))))
    echo -e "  ${YELLOW}CleanUp     $BAR $CLEANUP${NC}"
  fi
  if [ $QUARANTINE -gt 0 ]; then
    BAR=$(printf '█%.0s' $(seq 1 $((QUARANTINE * 50 / TOTAL))))
    echo -e "  ${RED}Quarantine  $BAR $QUARANTINE${NC}"
  fi
else
  echo -e "  ${RED}❌ Unable to fetch account data${NC}"
fi

echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Section 2: Cleanup Operations
echo -e "${BLUE}┌─ CLEANUP OPERATIONS ────────────────────────────────────────┐${NC}"

RUNNING=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter RUNNING \
  --profile "$PROFILE_HUB" \
  --region "$REGION" \
  --query 'length(executions)' \
  --output text 2>/dev/null || echo "0")

# Get recent succeeded/failed (last hour)
ONE_HOUR_AGO=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%S')

SUCCEEDED_RECENT=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter SUCCEEDED \
  --max-results 100 \
  --profile "$PROFILE_HUB" \
  --region "$REGION" 2>/dev/null | \
  jq "[.executions[] | select(.stopDate > \"$ONE_HOUR_AGO\")] | length" || echo "0")

FAILED_RECENT=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter FAILED \
  --max-results 100 \
  --profile "$PROFILE_HUB" \
  --region "$REGION" 2>/dev/null | \
  jq "[.executions[] | select(.stopDate > \"$ONE_HOUR_AGO\")] | length" || echo "0")

echo -e "  ${YELLOW}Running:           $RUNNING${NC}"
echo -e "  ${GREEN}Succeeded (1h):    $SUCCEEDED_RECENT${NC}"
echo -e "  ${RED}Failed (1h):       $FAILED_RECENT${NC}"

# Calculate success rate
if [ $((SUCCEEDED_RECENT + FAILED_RECENT)) -gt 0 ]; then
  SUCCESS_RATE=$((SUCCEEDED_RECENT * 100 / (SUCCEEDED_RECENT + FAILED_RECENT)))
  echo -e "  Success Rate:      ${SUCCESS_RATE}%"
fi

echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Section 3: Recent Errors
echo -e "${BLUE}┌─ RECENT ERRORS (Last 15 minutes) ───────────────────────────┐${NC}"

LOG_GROUP="InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL"
FIFTEEN_MIN_AGO=$(($(date +%s) - 900))000

ERRORS=$(aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --start-time "$FIFTEEN_MIN_AGO" \
  --filter-pattern "ERROR" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" \
  --max-items 5 2>/dev/null || echo "")

if [ -n "$ERRORS" ] && [ "$(echo "$ERRORS" | jq '.events | length')" -gt 0 ]; then
  ERROR_COUNT=$(echo "$ERRORS" | jq '.events | length')
  echo -e "  ${RED}⚠️  Found $ERROR_COUNT recent errors${NC}"
  echo ""
  echo "$ERRORS" | jq -r '.events[] | "  [\(.timestamp | tonumber / 1000 | strftime("%H:%M:%S"))] \(.message | split("\n")[0])"' | head -3
else
  echo -e "  ${GREEN}✅ No errors in the last 15 minutes${NC}"
fi

echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Section 4: System Health Indicators
echo -e "${BLUE}┌─ SYSTEM HEALTH ─────────────────────────────────────────────┐${NC}"

# Overall health score
HEALTH_SCORE=100

# Deduct points for issues
if [ $QUARANTINE -gt 0 ]; then
  HEALTH_SCORE=$((HEALTH_SCORE - QUARANTINE * 5))
fi

if [ $FAILED_RECENT -gt 0 ]; then
  HEALTH_SCORE=$((HEALTH_SCORE - FAILED_RECENT * 3))
fi

if [ $CLEANUP -gt 5 ]; then
  HEALTH_SCORE=$((HEALTH_SCORE - 10))
fi

# Cap at 0
if [ $HEALTH_SCORE -lt 0 ]; then
  HEALTH_SCORE=0
fi

# Display health score with color
if [ $HEALTH_SCORE -ge 90 ]; then
  HEALTH_COLOR=$GREEN
  HEALTH_STATUS="Excellent"
elif [ $HEALTH_SCORE -ge 70 ]; then
  HEALTH_COLOR=$BLUE
  HEALTH_STATUS="Good"
elif [ $HEALTH_SCORE -ge 50 ]; then
  HEALTH_COLOR=$YELLOW
  HEALTH_STATUS="Fair"
else
  HEALTH_COLOR=$RED
  HEALTH_STATUS="Poor"
fi

echo -e "  Overall Health:    ${HEALTH_COLOR}${HEALTH_SCORE}/100 ($HEALTH_STATUS)${NC}"
echo ""

# Health indicators
if [ $AVAILABLE -gt 0 ]; then
  echo -e "  ${GREEN}✅ Accounts available for use${NC}"
else
  echo -e "  ${YELLOW}⚠️  No accounts currently available${NC}"
fi

if [ $RUNNING -eq 0 ] && [ $CLEANUP -eq 0 ]; then
  echo -e "  ${GREEN}✅ No cleanup operations in progress${NC}"
elif [ $RUNNING -gt 0 ]; then
  echo -e "  ${BLUE}ℹ️  Cleanup operations in progress${NC}"
fi

if [ $QUARANTINE -eq 0 ]; then
  echo -e "  ${GREEN}✅ No accounts in quarantine${NC}"
else
  echo -e "  ${RED}⚠️  $QUARANTINE accounts in quarantine${NC}"
fi

if [ $FAILED_RECENT -eq 0 ]; then
  echo -e "  ${GREEN}✅ No recent cleanup failures${NC}"
else
  echo -e "  ${RED}⚠️  $FAILED_RECENT cleanup failures in last hour${NC}"
fi

echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Section 5: Quick Actions
echo -e "${BLUE}┌─ QUICK ACTIONS ─────────────────────────────────────────────┐${NC}"
echo -e "  ${CYAN}1.${NC} Check detailed status:    ./scripts/monitoring/check-account-status-detailed.sh"
echo -e "  ${CYAN}2.${NC} Monitor cleanup:          ./scripts/monitoring/monitor-cleanup-progress.sh"
echo -e "  ${CYAN}3.${NC} Verify infrastructure:    ./scripts/deployment/verify-infrastructure.sh"
echo -e "  ${CYAN}4.${NC} Fix stuck accounts:       ./scripts/fixes/fix-stuck-accounts.sh"
echo -e "  ${CYAN}5.${NC} View logs:                aws logs tail $LOG_GROUP --follow --profile $PROFILE_HUB"
echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Footer
echo -e "${CYAN}  Refresh: $0${NC}"
echo -e "${CYAN}  Auto-refresh: watch -n 30 $0${NC}"
echo ""

exit 0
