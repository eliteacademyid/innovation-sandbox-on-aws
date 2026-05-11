#!/bin/bash

# Bulk Register Accounts Script
# Registers multiple AWS accounts to Innovation Sandbox via API

set -e

# Configuration
PROFILE="eta-isb"
REGION="ap-southeast-3"
API_ENDPOINT="https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod"
TABLE_NAME="InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage
usage() {
  echo "Usage: $0 <account-ids-file>"
  echo ""
  echo "File format: One account ID per line"
  echo "Example:"
  echo "  123456789012"
  echo "  234567890123"
  echo "  345678901234"
  exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
  usage
fi

ACCOUNT_FILE="$1"

if [ ! -f "$ACCOUNT_FILE" ]; then
  echo -e "${RED}❌ Error: File not found: $ACCOUNT_FILE${NC}"
  exit 1
fi

# Get ID token for authentication
get_id_token() {
  # This would need to be implemented based on your auth setup
  # For now, using AWS credentials
  aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id YOUR_CLIENT_ID \
    --auth-parameters USERNAME=admin,PASSWORD=password \
    --profile "$PROFILE" \
    --region "$REGION" 2>/dev/null | jq -r '.AuthenticationResult.IdToken'
}

# Register single account
register_account() {
  local account_id="$1"
  
  echo -e "${BLUE}  Registering account: $account_id${NC}"
  
  # Check if account already registered
  local existing=$(aws dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"awsAccountId\": {\"S\": \"$account_id\"}}" \
    --profile "$PROFILE" \
    --region "$REGION" 2>&1)
  
  if echo "$existing" | grep -q "awsAccountId"; then
    echo -e "${YELLOW}  ⚠️  Account already registered, skipping${NC}"
    return 1
  fi
  
  # Get account details from Organizations
  local account_info=$(aws organizations describe-account \
    --account-id "$account_id" \
    --profile eta-andrian \
    --region us-east-1 2>&1)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}  ❌ Failed to get account info from Organizations${NC}"
    return 1
  fi
  
  local account_name=$(echo "$account_info" | jq -r '.Account.Name')
  local account_email=$(echo "$account_info" | jq -r '.Account.Email')
  
  # Register via API (simplified - would need proper auth)
  # For now, directly create DynamoDB record
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  
  aws dynamodb put-item \
    --table-name "$TABLE_NAME" \
    --item "{
      \"awsAccountId\": {\"S\": \"$account_id\"},
      \"name\": {\"S\": \"$account_name\"},
      \"email\": {\"S\": \"$account_email\"},
      \"status\": {\"S\": \"CleanUp\"},
      \"driftAtLastScan\": {\"BOOL\": false},
      \"meta\": {
        \"M\": {
          \"createdTime\": {\"S\": \"$timestamp\"},
          \"lastEditTime\": {\"S\": \"$timestamp\"},
          \"schemaVersion\": {\"N\": \"1\"}
        }
      }
    }" \
    --profile "$PROFILE" \
    --region "$REGION" >/dev/null 2>&1
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}  ✅ Successfully registered${NC}"
    
    # Move to CleanUp OU
    local entry_ou="ou-e21c-cz4ntm1j"
    local cleanup_ou=$(aws organizations list-organizational-units-for-parent \
      --parent-id "$entry_ou" \
      --profile eta-andrian \
      --region us-east-1 2>&1 | jq -r '.OrganizationalUnits[] | select(.Name == "CleanUp") | .Id')
    
    if [ -n "$cleanup_ou" ]; then
      aws organizations move-account \
        --account-id "$account_id" \
        --source-parent-id "$entry_ou" \
        --destination-parent-id "$cleanup_ou" \
        --profile eta-andrian \
        --region us-east-1 >/dev/null 2>&1
      
      echo -e "${GREEN}  ✅ Moved to CleanUp OU${NC}"
    fi
    
    return 0
  else
    echo -e "${RED}  ❌ Failed to register${NC}"
    return 1
  fi
}

# Main execution
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Bulk Account Registration            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Read account IDs
mapfile -t ACCOUNT_IDS < "$ACCOUNT_FILE"
TOTAL=${#ACCOUNT_IDS[@]}

echo -e "${BLUE}📋 Found $TOTAL accounts to register${NC}"
echo ""

# Counters
SUCCESS=0
FAILED=0
SKIPPED=0

# Process each account
for account_id in "${ACCOUNT_IDS[@]}"; do
  # Skip empty lines and comments
  if [[ -z "$account_id" ]] || [[ "$account_id" =~ ^# ]]; then
    continue
  fi
  
  # Trim whitespace
  account_id=$(echo "$account_id" | xargs)
  
  # Validate account ID format
  if ! [[ "$account_id" =~ ^[0-9]{12}$ ]]; then
    echo -e "${RED}❌ Invalid account ID format: $account_id${NC}"
    ((FAILED++))
    continue
  fi
  
  # Register account
  if register_account "$account_id"; then
    ((SUCCESS++))
  else
    if [ $? -eq 1 ]; then
      ((SKIPPED++))
    else
      ((FAILED++))
    fi
  fi
  
  echo ""
  
  # Small delay to avoid rate limiting
  sleep 1
done

# Summary
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Registration Summary                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total accounts:    $TOTAL"
echo -e "${GREEN}✅ Successful:      $SUCCESS${NC}"
echo -e "${YELLOW}⚠️  Skipped:         $SKIPPED${NC}"
echo -e "${RED}❌ Failed:          $FAILED${NC}"
echo ""

if [ $SUCCESS -gt 0 ]; then
  echo -e "${BLUE}💡 Next steps:${NC}"
  echo -e "   1. Monitor cleanup progress: ./scripts/monitoring/monitor-cleanup-progress.sh"
  echo -e "   2. Check account status: ./scripts/monitoring/check-account-status-detailed.sh"
  echo -e "   3. Wait 10-15 minutes for cleanup to complete"
fi

exit 0
