#!/bin/bash

# Script to register AWS accounts to the Innovation Sandbox pool
# Usage: ./scripts/account-management/register-accounts-to-pool.sh [account-id-1] [account-id-2] ...
# Or: ./scripts/account-management/register-accounts-to-pool.sh --all (registers all unregistered accounts)

set -e

API_ENDPOINT="https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod"
PROFILE_ORG="elite-academy"
PROFILE_HUB="eta-isb-andrian"
REGION="ap-southeast-3"

echo "=========================================="
echo "Register Accounts to Innovation Sandbox Pool"
echo "=========================================="
echo ""

# Get JWT token
echo "To register accounts, you need a JWT token from the web application."
echo ""
echo "Steps to get your JWT token:"
echo "1. Open the web app: https://d1nu7n93cpbse4.cloudfront.net"
echo "2. Sign in with your admin account"
echo "3. Open browser DevTools (F12 or Cmd+Option+I)"
echo "4. Go to Application/Storage → Local Storage"
echo "5. Find the 'token' key and copy its value"
echo ""
read -p "Paste your JWT token here: " JWT_TOKEN

if [ -z "$JWT_TOKEN" ]; then
    echo "❌ Error: JWT token is required"
    exit 1
fi

echo ""

# Determine which accounts to register
if [ "$1" == "--all" ]; then
    echo "Finding all unregistered accounts..."
    
    # Get all accounts from Organizations
    ALL_ACCOUNTS=$(aws organizations list-accounts \
        --profile "$PROFILE_ORG" \
        --output json | jq -r '.Accounts[] | select(.Status == "ACTIVE") | .Id')
    
    # Get already registered accounts
    REGISTERED_ACCOUNTS=$(aws dynamodb scan \
        --table-name InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94 \
        --profile "$PROFILE_HUB" \
        --region "$REGION" \
        --output json | jq -r '.Items[].awsAccountId.S' 2>/dev/null || echo "")
    
    # Exclude management and hub accounts
    MANAGEMENT_ACCOUNT="862099794180"
    HUB_ACCOUNT="147826551593"
    
    ACCOUNTS_TO_REGISTER=()
    for account in $ALL_ACCOUNTS; do
        if [ "$account" == "$MANAGEMENT_ACCOUNT" ] || [ "$account" == "$HUB_ACCOUNT" ]; then
            continue
        fi
        
        if ! echo "$REGISTERED_ACCOUNTS" | grep -q "$account"; then
            ACCOUNTS_TO_REGISTER+=("$account")
        fi
    done
    
    if [ ${#ACCOUNTS_TO_REGISTER[@]} -eq 0 ]; then
        echo "No unregistered accounts found."
        exit 0
    fi
    
    echo "Found ${#ACCOUNTS_TO_REGISTER[@]} unregistered account(s):"
    for account in "${ACCOUNTS_TO_REGISTER[@]}"; do
        echo "  - $account"
    done
    echo ""
else
    # Use provided account IDs
    ACCOUNTS_TO_REGISTER=("$@")
    
    if [ ${#ACCOUNTS_TO_REGISTER[@]} -eq 0 ]; then
        echo "Usage: $0 [account-id-1] [account-id-2] ..."
        echo "   Or: $0 --all"
        exit 1
    fi
fi

# Register each account
SUCCESS=0
FAILED=0

for account_id in "${ACCOUNTS_TO_REGISTER[@]}"; do
    echo "Registering account: $account_id"
    
    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"awsAccountId\": \"$account_id\"}" \
        "$API_ENDPOINT/accounts")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" -eq 201 ]; then
        echo "  ✅ Successfully registered"
        SUCCESS=$((SUCCESS + 1))
    else
        ERROR_MSG=$(echo "$BODY" | jq -r '.data.errors[0].message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
        echo "  ❌ Failed (HTTP $HTTP_CODE): $ERROR_MSG"
        FAILED=$((FAILED + 1))
    fi
    
    echo ""
    sleep 1
done

echo "=========================================="
echo "Registration Summary"
echo "=========================================="
echo "Success: $SUCCESS"
echo "Failed: $FAILED"
echo "=========================================="
echo ""

if [ $SUCCESS -gt 0 ]; then
    echo "✅ $SUCCESS account(s) registered to the pool!"
    echo ""
    echo "Accounts will go through cleanup and become available shortly."
    echo "Check status at: https://d1nu7n93cpbse4.cloudfront.net"
fi
