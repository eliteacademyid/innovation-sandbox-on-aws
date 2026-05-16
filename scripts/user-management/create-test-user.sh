#!/bin/bash

# Script to create a new ISB test user
# Usage: ./scripts/user-management/create-test-user.sh <email> <first-name> <last-name> <role>
# Role options: admin, manager, user

set -e

# Configuration from deployment
IDENTITY_STORE_ID="d-9667a833b5"
SSO_INSTANCE_ARN="arn:aws:sso:::instance/ssoins-821055714a3e49c5"
APPLICATION_ARN="arn:aws:sso::862099794180:application/ssoins-821055714a3e49c5/apl-82102dfcd1639f5f"
PROFILE="eta-andrian"
REGION="ap-southeast-1"

# Group IDs
ADMIN_GROUP_ID="593a45cc-d001-70d9-8c1f-d79934ec213b"
MANAGER_GROUP_ID="291a956c-40b1-70a9-2f9a-49a8867644e2"
USER_GROUP_ID="892ac5bc-b031-70aa-f100-e8476c794662"

# Parse arguments
EMAIL=$1
FIRST_NAME=$2
LAST_NAME=$3
ROLE=${4:-user}

if [ -z "$EMAIL" ] || [ -z "$FIRST_NAME" ] || [ -z "$LAST_NAME" ]; then
    echo "Usage: $0 <email> <first-name> <last-name> [role]"
    echo "Role options: admin, manager, user (default: user)"
    echo ""
    echo "Example: $0 testuser@example.com John Doe user"
    exit 1
fi

# Determine group ID based on role
case $ROLE in
    admin)
        GROUP_ID=$ADMIN_GROUP_ID
        GROUP_NAME="myisb_IsbAdminsGroup"
        ;;
    manager)
        GROUP_ID=$MANAGER_GROUP_ID
        GROUP_NAME="myisb_IsbManagersGroup"
        ;;
    user)
        GROUP_ID=$USER_GROUP_ID
        GROUP_NAME="myisb_IsbUsersGroup"
        ;;
    *)
        echo "Invalid role: $ROLE. Must be admin, manager, or user."
        exit 1
        ;;
esac

echo "=========================================="
echo "Creating ISB Test User"
echo "=========================================="
echo "Email: $EMAIL"
echo "Name: $FIRST_NAME $LAST_NAME"
echo "Role: $ROLE ($GROUP_NAME)"
echo "=========================================="
echo ""

# Step 1: Create the user
echo "Step 1: Creating user in IAM Identity Center..."
USER_OUTPUT=$(aws identitystore create-user \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --user-name "$EMAIL" \
    --display-name "$FIRST_NAME $LAST_NAME" \
    --name "{\"GivenName\":\"$FIRST_NAME\",\"FamilyName\":\"$LAST_NAME\"}" \
    --emails "[{\"Value\":\"$EMAIL\",\"Type\":\"work\",\"Primary\":true}]" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --output json)

USER_ID=$(echo "$USER_OUTPUT" | jq -r '.UserId')

if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
    echo "❌ Failed to create user"
    exit 1
fi

echo "✅ User created successfully"
echo "   User ID: $USER_ID"
echo ""

# Step 2: Add user to group
echo "Step 2: Adding user to group ($GROUP_NAME)..."
aws identitystore create-group-membership \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$GROUP_ID" \
    --member-id "{\"UserId\":\"$USER_ID\"}" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --output json > /dev/null

echo "✅ User added to group successfully"
echo ""

# Step 3: Assign user to SAML application
echo "Step 3: Assigning user to SAML application..."
aws sso-admin create-application-assignment \
    --application-arn "$APPLICATION_ARN" \
    --principal-id "$USER_ID" \
    --principal-type USER \
    --profile "$PROFILE" \
    --region "$REGION" \
    --output json > /dev/null

echo "✅ User assigned to application successfully"
echo ""

echo "=========================================="
echo "✅ Test User Created Successfully!"
echo "=========================================="
echo ""
echo "User Details:"
echo "  Email: $EMAIL"
echo "  Name: $FIRST_NAME $LAST_NAME"
echo "  User ID: $USER_ID"
echo "  Role: $ROLE"
echo "  Group: $GROUP_NAME"
echo ""
echo "Next Steps:"
echo "1. Send password reset email from IAM Identity Center console:"
echo "   IAM Identity Center → Users → $EMAIL → Reset password → Send email"
echo ""
echo "2. User can sign in at:"
echo "   https://d1nu7n93cpbse4.cloudfront.net"
echo ""
echo "3. SAML Sign-In URL (if needed):"
echo "   https://portal.sso.ap-southeast-3.amazonaws.com/saml/assertion/ODYyMDk5Nzk0MTgwX2lucy02NjY2NGQzYTRmY2FkNzU0"
echo "=========================================="
