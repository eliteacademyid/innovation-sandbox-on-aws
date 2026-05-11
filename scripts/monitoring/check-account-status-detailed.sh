#!/bin/bash

# Check detailed account status from DynamoDB and Step Functions

TABLE_NAME="InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94"
PROFILE="eta-isb"
REGION="ap-southeast-3"
STATE_MACHINE_ARN="arn:aws:states:ap-southeast-3:147826551593:stateMachine:AccountCleanerStepFunctionStateMachineF32685E8-Fz5UGtEOpyyX"

echo "=== ACCOUNT STATUS SUMMARY ==="
echo ""

# Get all accounts from DynamoDB
ACCOUNTS=$(aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --output json 2>&1)

# Count by status
echo "Status Distribution:"
echo "$ACCOUNTS" | jq -r '.Items[].status.S' | sort | uniq -c | sort -rn

echo ""
echo "=== CLEANUP WORKFLOW STATUS ==="
echo ""

# Count Step Functions executions
RUNNING=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter RUNNING \
  --profile "$PROFILE" \
  --region "$REGION" 2>&1 | jq '.executions | length')

SUCCEEDED=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter SUCCEEDED \
  --max-results 100 \
  --profile "$PROFILE" \
  --region "$REGION" 2>&1 | jq '.executions | length')

FAILED=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --status-filter FAILED \
  --max-results 100 \
  --profile "$PROFILE" \
  --region "$REGION" 2>&1 | jq '.executions | length')

echo "Running: $RUNNING"
echo "Succeeded (recent): $SUCCEEDED"
echo "Failed (recent): $FAILED"

echo ""
echo "=== DETAILED ACCOUNT LIST ==="
echo ""

# Show each account with details
echo "$ACCOUNTS" | jq -r '.Items[] | 
  "\(.awsAccountId.S): \(.name.S) - Status: \(.status.S)"' | sort

echo ""
echo "=== CHECKING FOR AVAILABLE ACCOUNTS ==="
echo ""

AVAILABLE_COUNT=$(echo "$ACCOUNTS" | jq -r '.Items[] | select(.status.S == "Available") | .awsAccountId.S' | wc -l | tr -d ' ')
echo "Available accounts: $AVAILABLE_COUNT"

if [ "$AVAILABLE_COUNT" -gt 0 ]; then
  echo ""
  echo "Available account IDs:"
  echo "$ACCOUNTS" | jq -r '.Items[] | select(.status.S == "Available") | .awsAccountId.S'
fi
