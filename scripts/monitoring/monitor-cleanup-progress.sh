#!/bin/bash

# Monitor the complete cleanup progress:
# 1. Region enablement
# 2. StackSet deployment
# 3. Account cleanup status

set -e

PROFILE_MGMT="eta-andrian"
PROFILE_HUB="eta-isb-andrian"
REGION="ap-southeast-3"
STACKSET_NAME="Isb-myisb-SandboxAccountResources"

echo "=========================================="
echo "Innovation Sandbox Cleanup Progress"
echo "=========================================="
echo ""
echo "Timestamp: $(date)"
echo ""

# Get all ISB-Sandbox accounts
ACCOUNTS=$(aws organizations list-accounts \
    --profile $PROFILE_MGMT \
    --region $REGION \
    --output json | jq -r '.Accounts[] | select(.Name | startswith("ISB-Sandbox")) | .Id')

TOTAL_ACCOUNTS=$(echo "$ACCOUNTS" | wc -l | tr -d ' ')

echo "Total Accounts: $TOTAL_ACCOUNTS"
echo ""

# ==========================================
# STAGE 1: Region Enablement
# ==========================================
echo "=========================================="
echo "STAGE 1: Region Enablement"
echo "=========================================="

REGION_ENABLED=0
REGION_ENABLING=0
REGION_DISABLED=0

for ACCOUNT_ID in $ACCOUNTS; do
    STATUS=$(aws account get-region-opt-status \
        --account-id $ACCOUNT_ID \
        --region-name $REGION \
        --profile $PROFILE_MGMT \
        --region us-east-1 \
        --output json 2>/dev/null | jq -r '.RegionOptStatus' || echo "UNKNOWN")
    
    if [[ "$STATUS" == "ENABLED" ]]; then
        ((REGION_ENABLED++))
    elif [[ "$STATUS" == "ENABLING" ]]; then
        ((REGION_ENABLING++))
    else
        ((REGION_DISABLED++))
    fi
done

echo "Enabled:  $REGION_ENABLED / $TOTAL_ACCOUNTS"
echo "Enabling: $REGION_ENABLING / $TOTAL_ACCOUNTS"
echo "Disabled: $REGION_DISABLED / $TOTAL_ACCOUNTS"

if [[ $REGION_ENABLED -eq $TOTAL_ACCOUNTS ]]; then
    echo "✅ Stage 1 Complete: All regions enabled"
elif [[ $REGION_ENABLING -gt 0 ]]; then
    echo "⏳ Stage 1 In Progress: $REGION_ENABLING accounts still enabling"
else
    echo "❌ Stage 1 Failed: $REGION_DISABLED accounts not enabled"
fi

echo ""

# ==========================================
# STAGE 2: StackSet Deployment
# ==========================================
echo "=========================================="
echo "STAGE 2: StackSet Deployment"
echo "=========================================="

STACKSET_CURRENT=0
STACKSET_OUTDATED=0
STACKSET_FAILED=0

STACK_INSTANCES=$(aws cloudformation list-stack-instances \
    --stack-set-name $STACKSET_NAME \
    --profile $PROFILE_MGMT \
    --region $REGION \
    --output json 2>/dev/null || echo '{"Summaries":[]}')

for ACCOUNT_ID in $ACCOUNTS; do
    STATUS=$(echo "$STACK_INSTANCES" | jq -r ".Summaries[] | select(.Account == \"$ACCOUNT_ID\") | .Status")
    
    if [[ "$STATUS" == "CURRENT" ]]; then
        ((STACKSET_CURRENT++))
    elif [[ "$STATUS" == "OUTDATED" ]]; then
        ((STACKSET_OUTDATED++))
    elif [[ "$STATUS" == "FAILED" ]]; then
        ((STACKSET_FAILED++))
    fi
done

echo "Current:  $STACKSET_CURRENT / $TOTAL_ACCOUNTS"
echo "Outdated: $STACKSET_OUTDATED / $TOTAL_ACCOUNTS"
echo "Failed:   $STACKSET_FAILED / $TOTAL_ACCOUNTS"

if [[ $STACKSET_CURRENT -eq $TOTAL_ACCOUNTS ]]; then
    echo "✅ Stage 2 Complete: All StackSets deployed"
elif [[ $STACKSET_OUTDATED -gt 0 ]]; then
    echo "⏳ Stage 2 In Progress: $STACKSET_OUTDATED accounts waiting for deployment"
else
    echo "❌ Stage 2 Failed: $STACKSET_FAILED accounts failed"
fi

echo ""

# ==========================================
# STAGE 3: Account Cleanup Status
# ==========================================
echo "=========================================="
echo "STAGE 3: Account Cleanup Status"
echo "=========================================="

ACCOUNT_AVAILABLE=0
ACCOUNT_CLEANUP=0
ACCOUNT_QUARANTINE=0
ACCOUNT_ACTIVE=0

DYNAMODB_ITEMS=$(aws dynamodb scan \
    --table-name InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94 \
    --profile $PROFILE_HUB \
    --region $REGION \
    --output json 2>/dev/null || echo '{"Items":[]}')

for ACCOUNT_ID in $ACCOUNTS; do
    STATUS=$(echo "$DYNAMODB_ITEMS" | jq -r ".Items[] | select(.awsAccountId.S == \"$ACCOUNT_ID\") | .status.S")
    
    if [[ "$STATUS" == "Available" ]]; then
        ((ACCOUNT_AVAILABLE++))
    elif [[ "$STATUS" == "CleanUp" ]]; then
        ((ACCOUNT_CLEANUP++))
    elif [[ "$STATUS" == "Quarantine" ]]; then
        ((ACCOUNT_QUARANTINE++))
    elif [[ "$STATUS" == "Active" ]]; then
        ((ACCOUNT_ACTIVE++))
    fi
done

echo "Available:  $ACCOUNT_AVAILABLE / $TOTAL_ACCOUNTS"
echo "CleanUp:    $ACCOUNT_CLEANUP / $TOTAL_ACCOUNTS"
echo "Quarantine: $ACCOUNT_QUARANTINE / $TOTAL_ACCOUNTS"
echo "Active:     $ACCOUNT_ACTIVE / $TOTAL_ACCOUNTS"

if [[ $ACCOUNT_AVAILABLE -eq $TOTAL_ACCOUNTS ]]; then
    echo "✅ Stage 3 Complete: All accounts available"
elif [[ $ACCOUNT_CLEANUP -gt 0 ]]; then
    echo "⏳ Stage 3 In Progress: $ACCOUNT_CLEANUP accounts cleaning up"
elif [[ $ACCOUNT_QUARANTINE -gt 0 ]]; then
    echo "❌ Stage 3 Failed: $ACCOUNT_QUARANTINE accounts in quarantine"
fi

echo ""

# ==========================================
# Overall Progress
# ==========================================
echo "=========================================="
echo "Overall Progress"
echo "=========================================="

STAGE1_COMPLETE=false
STAGE2_COMPLETE=false
STAGE3_COMPLETE=false

if [[ $REGION_ENABLED -eq $TOTAL_ACCOUNTS ]]; then
    STAGE1_COMPLETE=true
fi

if [[ $STACKSET_CURRENT -eq $TOTAL_ACCOUNTS ]]; then
    STAGE2_COMPLETE=true
fi

if [[ $ACCOUNT_AVAILABLE -eq $TOTAL_ACCOUNTS ]]; then
    STAGE3_COMPLETE=true
fi

if [[ "$STAGE1_COMPLETE" == "true" ]]; then
    echo "✅ Stage 1: Region Enablement"
else
    echo "⏳ Stage 1: Region Enablement (in progress)"
fi

if [[ "$STAGE2_COMPLETE" == "true" ]]; then
    echo "✅ Stage 2: StackSet Deployment"
elif [[ "$STAGE1_COMPLETE" == "true" ]]; then
    echo "⏳ Stage 2: StackSet Deployment (waiting)"
else
    echo "⏸️  Stage 2: StackSet Deployment (blocked by Stage 1)"
fi

if [[ "$STAGE3_COMPLETE" == "true" ]]; then
    echo "✅ Stage 3: Account Cleanup"
elif [[ "$STAGE2_COMPLETE" == "true" ]]; then
    echo "⏳ Stage 3: Account Cleanup (in progress)"
else
    echo "⏸️  Stage 3: Account Cleanup (blocked by Stage 2)"
fi

echo ""

if [[ "$STAGE3_COMPLETE" == "true" ]]; then
    echo "🎉 ALL STAGES COMPLETE!"
    echo ""
    echo "Next steps:"
    echo "1. Attach blueprint to lease template"
    echo "2. Bulk assign leases to 23 participants"
    echo "3. Verify assignments"
elif [[ "$STAGE2_COMPLETE" == "true" ]]; then
    echo "⏳ Waiting for cleanup to complete (10-15 minutes)"
    echo ""
    echo "You can retry cleanup manually:"
    echo "1. Go to: https://d1nu7n93cpbse4.cloudfront.net"
    echo "2. Administration → Accounts"
    echo "3. Select all CleanUp accounts"
    echo "4. Actions → Retry cleanup"
elif [[ "$STAGE1_COMPLETE" == "true" ]]; then
    echo "⏳ Waiting for StackSet deployment (5-10 minutes)"
    echo ""
    echo "StackSets will auto-deploy now that regions are enabled"
else
    echo "⏳ Waiting for region enablement (5-10 minutes)"
    echo ""
    echo "Check again in a few minutes"
fi

echo ""
echo "Run this script again to check progress:"
echo "./scripts/monitoring/monitor-cleanup-progress.sh"
echo ""
