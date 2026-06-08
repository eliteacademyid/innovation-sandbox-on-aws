#!/usr/bin/env bash
# Create kiro-lease group and 4 users
set -e

IDENTITY_STORE_ID="d-9667a833b5"
PROFILE="eta-andrian"
REGION="ap-southeast-1"
APPLICATION_ARN="arn:aws:sso::862099794180:application/ssoins-821055714a3e49c5/apl-66664d3a4fcad754"
ISB_ADMINS_GROUP="593a45cc-d001-70d9-8c1f-d79934ec213b"

echo "=== Creating kiro-lease group ==="
GROUP_ID=$(aws identitystore create-group \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --display-name "kiro-lease" \
    --description "Kiro lease demo users" \
    --profile "$PROFILE" --region "$REGION" \
    --query "GroupId" --output text 2>/dev/null || \
    aws identitystore get-group-id \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --alternate-identifier '{"UniqueAttribute":{"AttributePath":"DisplayName","AttributeValue":"kiro-lease"}}' \
    --profile "$PROFILE" --region "$REGION" \
    --query "GroupId" --output text 2>/dev/null)

echo "  Group ID: $GROUP_ID"
echo ""

echo "=== Creating kiro-lease users ==="
for i in 1 2 3 4; do
    USERNAME="kiro-lease-${i}"
    EMAIL="kiro-lease-${i}@bsi-h8.com"
    
    USER_ID=$(aws identitystore create-user \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --user-name "$USERNAME" \
        --display-name "Kiro Lease ${i}" \
        --name "{\"GivenName\":\"Kiro\",\"FamilyName\":\"Lease${i}\"}" \
        --emails "[{\"Value\":\"$EMAIL\",\"Type\":\"work\",\"Primary\":true}]" \
        --profile "$PROFILE" --region "$REGION" \
        --query "UserId" --output text 2>/dev/null)
    
    if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
        echo "  ✅ $USERNAME ($USER_ID)"
        
        aws identitystore create-group-membership \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --group-id "$GROUP_ID" \
            --member-id "{\"UserId\":\"$USER_ID\"}" \
            --profile "$PROFILE" --region "$REGION" --output json > /dev/null 2>&1 || true
        
        aws identitystore create-group-membership \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --group-id "$ISB_ADMINS_GROUP" \
            --member-id "{\"UserId\":\"$USER_ID\"}" \
            --profile "$PROFILE" --region "$REGION" --output json > /dev/null 2>&1 || true
        
        aws sso-admin create-application-assignment \
            --application-arn "$APPLICATION_ARN" \
            --principal-id "$USER_ID" --principal-type USER \
            --profile "$PROFILE" --region "$REGION" --output json > /dev/null 2>&1 || true
    else
        echo "  ⚠️  $USERNAME — may already exist"
    fi
    sleep 0.3
done

echo ""
echo "=== Done ==="
echo "Set passwords: IDC console → Users → select user → Reset password"
echo "SSO Portal: https://eliteacademy.awsapps.com/start"
