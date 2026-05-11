#!/bin/bash

# Quick script to check account pool status
# Shows how many accounts are available for lease assignment

set -e

API_ENDPOINT="https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod"

echo "=========================================="
echo "Account Pool Status Check"
echo "=========================================="
echo ""

# Check if JWT token is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <jwt-token>"
    echo ""
    echo "Or get token interactively:"
    read -p "Paste your JWT token: " JWT_TOKEN
else
    JWT_TOKEN="$1"
fi

if [ -z "$JWT_TOKEN" ]; then
    echo "❌ Error: JWT token is required"
    exit 1
fi

echo "Fetching account pool status..."
echo ""

# Get accounts
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X GET \
    -H "Authorization: Bearer $JWT_TOKEN" \
    "$API_ENDPOINT/accounts")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
    # Parse account statuses (updated for correct API response format)
    TOTAL=$(echo "$BODY" | jq -r '.data.result | length')
    
    if [ "$TOTAL" -eq 0 ]; then
        echo "❌ Account pool is empty!"
        echo ""
        echo "You need to create and register sandbox accounts first."
        echo ""
        echo "To create 23 accounts for Cendekiawan ToT:"
        echo "  ./scripts/account-management/create-sandbox-accounts.sh 23 isb-sandbox"
        echo ""
        echo "Wait 2-6 hours for account creation, then register:"
        echo "  ./scripts/monitoring/check-account-creation-status.sh"
        echo "  ./scripts/account-management/register-accounts-to-pool.sh --all"
        exit 1
    fi
    
    AVAILABLE=$(echo "$BODY" | jq -r '[.data.result[] | select(.status == "Available")] | length')
    LEASED=$(echo "$BODY" | jq -r '[.data.result[] | select(.status == "Leased")] | length')
    CLEANING=$(echo "$BODY" | jq -r '[.data.result[] | select(.status == "Cleaning")] | length')
    QUARANTINED=$(echo "$BODY" | jq -r '[.data.result[] | select(.status == "Quarantined")] | length')
    
    echo "📊 Account Pool Status:"
    echo "  Total Accounts:      $TOTAL"
    echo "  Available:           $AVAILABLE ✅"
    echo "  Leased:              $LEASED"
    echo "  Cleaning:            $CLEANING"
    echo "  Quarantined:         $QUARANTINED"
    echo ""
    
    if [ "$AVAILABLE" -ge 23 ]; then
        echo "✅ You have enough accounts ($AVAILABLE) for 23 participants!"
        echo ""
        echo "Ready to proceed with bulk lease assignment."
    elif [ "$AVAILABLE" -gt 0 ]; then
        NEEDED=$((23 - AVAILABLE))
        echo "⚠️  You have $AVAILABLE available accounts."
        echo "    You need $NEEDED more accounts for 23 participants."
        echo ""
        echo "To add more accounts:"
        echo "  ./scripts/account-management/create-sandbox-accounts.sh $NEEDED isb-sandbox"
    else
        echo "❌ No available accounts in the pool!"
        echo ""
        echo "All accounts are currently leased or being cleaned."
        echo "Wait for accounts to become available or create more:"
        echo "  ./scripts/account-management/create-sandbox-accounts.sh 23 isb-sandbox"
    fi
    
    echo ""
    echo "Account Details:"
    echo "$BODY" | jq -r '.data.result[] | "  - \(.accountId) (\(.status))"'
    
else
    ERROR_MSG=$(echo "$BODY" | jq -r '.message // "Unknown error"')
    echo "❌ Failed to fetch accounts (HTTP $HTTP_CODE)"
    echo "Error: $ERROR_MSG"
    exit 1
fi
