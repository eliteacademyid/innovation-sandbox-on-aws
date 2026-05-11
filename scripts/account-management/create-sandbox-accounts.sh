#!/bin/bash

# Script to create AWS accounts for the Innovation Sandbox pool
# Usage: ./scripts/account-management/create-sandbox-accounts.sh <number-of-accounts> <email-prefix>

set -e

NUM_ACCOUNTS=$1
EMAIL_PREFIX=${2:-"isb-sandbox"}
PROFILE="elite-academy"
REGION="ap-southeast-3"

if [ -z "$NUM_ACCOUNTS" ]; then
    echo "Usage: $0 <number-of-accounts> [email-prefix]"
    echo ""
    echo "Example: $0 5 isb-sandbox"
    echo "  This will create 5 accounts with emails:"
    echo "    isb-sandbox-01@eliteacademy.id"
    echo "    isb-sandbox-02@eliteacademy.id"
    echo "    ..."
    exit 1
fi

echo "=========================================="
echo "Creating $NUM_ACCOUNTS Sandbox Accounts"
echo "=========================================="
echo "Email prefix: $EMAIL_PREFIX"
echo "Profile: $PROFILE"
echo "=========================================="
echo ""

# Check AWS access
if ! aws sts get-caller-identity --profile "$PROFILE" &> /dev/null; then
    echo "❌ AWS profile '$PROFILE' has no access"
    echo "Please run: aws sso login --profile $PROFILE"
    exit 1
fi

echo "✅ AWS access verified"
echo ""

SUCCESS=0
FAILED=0

for i in $(seq 1 $NUM_ACCOUNTS); do
    # Format number with leading zero
    NUM=$(printf "%02d" $i)
    ACCOUNT_NAME="ISB-Sandbox-${NUM}"
    ACCOUNT_EMAIL="${EMAIL_PREFIX}-${NUM}@eliteacademy.id"
    
    echo "[$i/$NUM_ACCOUNTS] Creating account: $ACCOUNT_NAME"
    echo "  Email: $ACCOUNT_EMAIL"
    
    # Create account
    RESULT=$(aws organizations create-account \
        --email "$ACCOUNT_EMAIL" \
        --account-name "$ACCOUNT_NAME" \
        --profile "$PROFILE" \
        --output json 2>&1)
    
    if echo "$RESULT" | jq -e '.CreateAccountStatus.Id' > /dev/null 2>&1; then
        REQUEST_ID=$(echo "$RESULT" | jq -r '.CreateAccountStatus.Id')
        echo "  ✅ Account creation initiated"
        echo "  Request ID: $REQUEST_ID"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  ❌ Failed to create account"
        echo "  Error: $RESULT"
        FAILED=$((FAILED + 1))
    fi
    
    echo ""
    
    # Small delay to avoid rate limiting
    sleep 2
done

echo "=========================================="
echo "Account Creation Summary"
echo "=========================================="
echo "Initiated: $SUCCESS"
echo "Failed: $FAILED"
echo "=========================================="
echo ""
echo "Note: Account creation takes 5-15 minutes per account."
echo "Use the following command to check status:"
echo ""
echo "  ./scripts/monitoring/check-account-creation-status.sh"
echo ""
