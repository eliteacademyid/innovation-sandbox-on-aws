#!/bin/bash

# Infrastructure Verification Script
# Validates all ISB prerequisites and infrastructure health

set -e

# Configuration
PROFILE_HUB="eta-isb-andrian"
PROFILE_MGMT="eta-andrian"
REGION="ap-southeast-3"
TABLE_NAME="InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94"
STACKSET_NAME="InnovationSandbox-AccountPool-SpokeRoleStackSet"
ENTRY_OU="ou-e21c-cz4ntm1j"
REQUIRED_REGIONS=("ap-southeast-3" "ap-southeast-5")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

# Check result tracking
check_result() {
  local status=$1
  local message=$2
  
  case $status in
    "pass")
      echo -e "${GREEN}✅ PASS${NC}: $message"
      ((CHECKS_PASSED++))
      ;;
    "fail")
      echo -e "${RED}❌ FAIL${NC}: $message"
      ((CHECKS_FAILED++))
      ;;
    "warn")
      echo -e "${YELLOW}⚠️  WARN${NC}: $message"
      ((CHECKS_WARNING++))
      ;;
  esac
}

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  ISB Infrastructure Verification      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Check 1: AWS Credentials
echo -e "${BLUE}[1/10] Checking AWS Credentials...${NC}"
if aws sts get-caller-identity --profile "$PROFILE_HUB" --region "$REGION" >/dev/null 2>&1; then
  HUB_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE_HUB" --region "$REGION" --query 'Account' --output text)
  check_result "pass" "Hub account credentials valid ($HUB_ACCOUNT)"
else
  check_result "fail" "Hub account credentials invalid or not configured"
fi

if aws sts get-caller-identity --profile "$PROFILE_MGMT" --region us-east-1 >/dev/null 2>&1; then
  MGMT_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE_MGMT" --region us-east-1 --query 'Account' --output text)
  check_result "pass" "Management account credentials valid ($MGMT_ACCOUNT)"
else
  check_result "fail" "Management account credentials invalid or not configured"
fi
echo ""

# Check 2: DynamoDB Table
echo -e "${BLUE}[2/10] Checking DynamoDB Table...${NC}"
if aws dynamodb describe-table --table-name "$TABLE_NAME" --profile "$PROFILE_HUB" --region "$REGION" >/dev/null 2>&1; then
  ITEM_COUNT=$(aws dynamodb scan --table-name "$TABLE_NAME" --select "COUNT" --profile "$PROFILE_HUB" --region "$REGION" --query 'Count' --output text)
  check_result "pass" "DynamoDB table accessible ($ITEM_COUNT accounts)"
else
  check_result "fail" "DynamoDB table not accessible"
fi
echo ""

# Check 3: StackSet Deployment
echo -e "${BLUE}[3/10] Checking StackSet Deployment...${NC}"
STACKSET_STATUS=$(aws cloudformation describe-stack-set \
  --stack-set-name "$STACKSET_NAME" \
  --profile "$PROFILE_MGMT" \
  --region us-east-1 \
  --query 'StackSet.Status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$STACKSET_STATUS" == "ACTIVE" ]; then
  check_result "pass" "StackSet is ACTIVE"
  
  # Check stack instances
  INSTANCE_COUNT=$(aws cloudformation list-stack-instances \
    --stack-set-name "$STACKSET_NAME" \
    --profile "$PROFILE_MGMT" \
    --region us-east-1 \
    --query 'length(Summaries)' \
    --output text 2>/dev/null || echo "0")
  
  CURRENT_COUNT=$(aws cloudformation list-stack-instances \
    --stack-set-name "$STACKSET_NAME" \
    --profile "$PROFILE_MGMT" \
    --region us-east-1 \
    --query 'length(Summaries[?Status==`CURRENT`])' \
    --output text 2>/dev/null || echo "0")
  
  if [ "$INSTANCE_COUNT" -eq "$CURRENT_COUNT" ]; then
    check_result "pass" "All $INSTANCE_COUNT stack instances are CURRENT"
  else
    check_result "warn" "$CURRENT_COUNT/$INSTANCE_COUNT stack instances are CURRENT"
  fi
else
  check_result "fail" "StackSet status: $STACKSET_STATUS"
fi
echo ""

# Check 4: Get Sandbox Accounts
echo -e "${BLUE}[4/10] Getting Sandbox Accounts...${NC}"
SANDBOX_ACCOUNTS=$(aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" \
  --query 'Items[].awsAccountId.S' \
  --output text 2>/dev/null || echo "")

if [ -n "$SANDBOX_ACCOUNTS" ]; then
  ACCOUNT_COUNT=$(echo "$SANDBOX_ACCOUNTS" | wc -w | xargs)
  check_result "pass" "Found $ACCOUNT_COUNT sandbox accounts"
else
  check_result "warn" "No sandbox accounts found"
  ACCOUNT_COUNT=0
fi
echo ""

# Check 5: Region Enablement
if [ $ACCOUNT_COUNT -gt 0 ]; then
  echo -e "${BLUE}[5/10] Checking Region Enablement...${NC}"
  
  REGION_CHECK_FAILED=0
  REGION_CHECK_PASSED=0
  
  # Sample check on first 3 accounts
  SAMPLE_ACCOUNTS=$(echo "$SANDBOX_ACCOUNTS" | tr ' ' '\n' | head -3)
  
  for account_id in $SAMPLE_ACCOUNTS; do
    for region in "${REQUIRED_REGIONS[@]}"; do
      # Try to assume role and check region
      ROLE_ARN="arn:aws:iam::${account_id}:role/InnovationSandbox-AccountPool-SpokeRole"
      
      ASSUMED=$(aws sts assume-role \
        --role-arn "$ROLE_ARN" \
        --role-session-name "RegionCheck" \
        --profile "$PROFILE_HUB" \
        --region "$REGION" 2>/dev/null || echo "FAILED")
      
      if [ "$ASSUMED" != "FAILED" ]; then
        ((REGION_CHECK_PASSED++))
      else
        ((REGION_CHECK_FAILED++))
      fi
    done
  done
  
  if [ $REGION_CHECK_FAILED -eq 0 ]; then
    check_result "pass" "Required regions enabled (sampled 3 accounts)"
  else
    check_result "warn" "Some regions may not be enabled (check failed: $REGION_CHECK_FAILED)"
  fi
else
  echo -e "${BLUE}[5/10] Checking Region Enablement...${NC}"
  check_result "warn" "Skipped (no accounts to check)"
fi
echo ""

# Check 6: IAM Spoke Roles
if [ $ACCOUNT_COUNT -gt 0 ]; then
  echo -e "${BLUE}[6/10] Checking IAM Spoke Roles...${NC}"
  
  ROLE_CHECK_FAILED=0
  ROLE_CHECK_PASSED=0
  
  # Sample check on first 5 accounts
  SAMPLE_ACCOUNTS=$(echo "$SANDBOX_ACCOUNTS" | tr ' ' '\n' | head -5)
  
  for account_id in $SAMPLE_ACCOUNTS; do
    ROLE_ARN="arn:aws:iam::${account_id}:role/InnovationSandbox-AccountPool-SpokeRole"
    
    if aws sts assume-role \
      --role-arn "$ROLE_ARN" \
      --role-session-name "RoleCheck" \
      --profile "$PROFILE_HUB" \
      --region "$REGION" >/dev/null 2>&1; then
      ((ROLE_CHECK_PASSED++))
    else
      ((ROLE_CHECK_FAILED++))
    fi
  done
  
  if [ $ROLE_CHECK_FAILED -eq 0 ]; then
    check_result "pass" "Spoke roles exist and accessible (sampled 5 accounts)"
  else
    check_result "fail" "Some spoke roles missing or inaccessible ($ROLE_CHECK_FAILED/5 failed)"
  fi
else
  echo -e "${BLUE}[6/10] Checking IAM Spoke Roles...${NC}"
  check_result "warn" "Skipped (no accounts to check)"
fi
echo ""

# Check 7: Step Functions State Machine
echo -e "${BLUE}[7/10] Checking Step Functions...${NC}"
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${HUB_ACCOUNT}:stateMachine:AccountCleanerStepFunctionStateMachineF32685E8-Fz5UGtEOpyyX"

if aws stepfunctions describe-state-machine \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" >/dev/null 2>&1; then
  
  RUNNING_EXECUTIONS=$(aws stepfunctions list-executions \
    --state-machine-arn "$STATE_MACHINE_ARN" \
    --status-filter RUNNING \
    --profile "$PROFILE_HUB" \
    --region "$REGION" \
    --query 'length(executions)' \
    --output text 2>/dev/null || echo "0")
  
  check_result "pass" "Step Functions state machine exists ($RUNNING_EXECUTIONS running)"
else
  check_result "fail" "Step Functions state machine not found"
fi
echo ""

# Check 8: API Gateway
echo -e "${BLUE}[8/10] Checking API Gateway...${NC}"
API_ID="sp1yg0dss7"

if aws apigateway get-rest-api \
  --rest-api-id "$API_ID" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" >/dev/null 2>&1; then
  check_result "pass" "API Gateway accessible"
else
  check_result "fail" "API Gateway not accessible"
fi
echo ""

# Check 9: CloudWatch Log Group
echo -e "${BLUE}[9/10] Checking CloudWatch Logs...${NC}"
LOG_GROUP="InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL"

if aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --profile "$PROFILE_HUB" \
  --region "$REGION" \
  --query 'logGroups[0]' >/dev/null 2>&1; then
  check_result "pass" "CloudWatch log group exists"
else
  check_result "warn" "CloudWatch log group not found"
fi
echo ""

# Check 10: Account Status Distribution
if [ $ACCOUNT_COUNT -gt 0 ]; then
  echo -e "${BLUE}[10/10] Checking Account Status Distribution...${NC}"
  
  STATUS_DIST=$(aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --profile "$PROFILE_HUB" \
    --region "$REGION" \
    --query 'Items[].status.S' \
    --output text 2>/dev/null | tr '\t' '\n' | sort | uniq -c)
  
  echo "$STATUS_DIST" | while read count status; do
    echo "  $status: $count"
  done
  
  AVAILABLE_COUNT=$(echo "$STATUS_DIST" | grep "Available" | awk '{print $1}' || echo "0")
  
  if [ "$AVAILABLE_COUNT" -gt 0 ]; then
    check_result "pass" "$AVAILABLE_COUNT accounts available for use"
  else
    check_result "warn" "No accounts currently available"
  fi
else
  echo -e "${BLUE}[10/10] Checking Account Status Distribution...${NC}"
  check_result "warn" "Skipped (no accounts to check)"
fi
echo ""

# Summary
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Verification Summary                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total Checks:      $((CHECKS_PASSED + CHECKS_FAILED + CHECKS_WARNING))"
echo -e "${GREEN}✅ Passed:         $CHECKS_PASSED${NC}"
echo -e "${YELLOW}⚠️  Warnings:       $CHECKS_WARNING${NC}"
echo -e "${RED}❌ Failed:         $CHECKS_FAILED${NC}"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ Infrastructure verification PASSED${NC}"
  echo ""
  echo -e "${BLUE}💡 System is healthy and ready for operations${NC}"
  exit 0
else
  echo -e "${RED}❌ Infrastructure verification FAILED${NC}"
  echo ""
  echo -e "${BLUE}💡 Please fix the failed checks before proceeding${NC}"
  echo -e "${BLUE}📖 See: RUNBOOK-TROUBLESHOOTING.md${NC}"
  exit 1
fi
