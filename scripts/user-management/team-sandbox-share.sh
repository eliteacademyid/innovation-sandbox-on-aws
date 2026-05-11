#!/bin/bash
# ============================================================================
# Team Sandbox Sharing Script (Group-Based Approach)
# ============================================================================
# 
# This script enables multiple team members to share a single sandbox account
# by creating an IDC group for the team and assigning it to the sandbox account.
#
# Usage:
#   ./scripts/user-management/team-sandbox-share.sh create <team-name> <sandbox-account-id> <email1> [email2] ...
#   ./scripts/user-management/team-sandbox-share.sh add <team-name> <email1> [email2] ...
#   ./scripts/user-management/team-sandbox-share.sh remove <team-name> <email1> [email2] ...
#   ./scripts/user-management/team-sandbox-share.sh delete <team-name> <sandbox-account-id>
#   ./scripts/user-management/team-sandbox-share.sh list <team-name>
#
# Examples:
#   ./scripts/user-management/team-sandbox-share.sh create team-alpha 123456789012 alice@co.com bob@co.com
#   ./scripts/user-management/team-sandbox-share.sh add team-alpha carol@co.com
#   ./scripts/user-management/team-sandbox-share.sh remove team-alpha bob@co.com
#   ./scripts/user-management/team-sandbox-share.sh delete team-alpha 123456789012
#   ./scripts/user-management/team-sandbox-share.sh list team-alpha
#
# ============================================================================

set -e

# ── Configuration ─────────────────────────────────────────────────────────────
IDENTITY_STORE_ID="d-9667a833b5"
SSO_INSTANCE_ARN="arn:aws:sso:::instance/ssoins-821055714a3e49c5"
PROFILE="elite-academy"
REGION="ap-southeast-3"
GROUP_PREFIX="isb-team"  # Groups will be named: isb-team-<team-name>

# ── Helper Functions ──────────────────────────────────────────────────────────

get_permission_set_arn() {
    # Look up the IsbUsersPS permission set ARN dynamically
    local PS_ARN=$(aws sso-admin list-permission-sets \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json | jq -r '.PermissionSets[]' | while read ps; do
        NAME=$(aws sso-admin describe-permission-set \
            --instance-arn "$SSO_INSTANCE_ARN" \
            --permission-set-arn "$ps" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --query "PermissionSet.Name" --output text 2>/dev/null)
        if [[ "$NAME" == *"IsbUsersPS"* ]] || [[ "$NAME" == *"IsbUsers"* ]]; then
            echo "$ps"
            break
        fi
    done)

    if [ -z "$PS_ARN" ]; then
        echo "❌ Error: Could not find IsbUsersPS permission set." >&2
        echo "   Please set PERMISSION_SET_ARN manually in this script." >&2
        exit 1
    fi
    echo "$PS_ARN"
}

get_user_id() {
    local EMAIL=$1
    aws identitystore list-users \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --filters "AttributePath=UserName,AttributeValue=$EMAIL" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query "Users[0].UserId" --output text 2>/dev/null
}

get_group_id() {
    local GROUP_NAME=$1
    aws identitystore list-groups \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --filters "AttributePath=DisplayName,AttributeValue=$GROUP_NAME" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query "Groups[0].GroupId" --output text 2>/dev/null
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_create() {
    local TEAM_NAME=$1
    local ACCOUNT_ID=$2
    shift 2
    local EMAILS=("$@")

    if [ -z "$TEAM_NAME" ] || [ -z "$ACCOUNT_ID" ] || [ ${#EMAILS[@]} -eq 0 ]; then
        echo "Usage: $0 create <team-name> <sandbox-account-id> <email1> [email2] ..."
        exit 1
    fi

    local GROUP_NAME="${GROUP_PREFIX}-${TEAM_NAME}"

    echo "=========================================="
    echo "🏗️  Create Team Sandbox Share"
    echo "=========================================="
    echo "Team:        $TEAM_NAME"
    echo "Group:       $GROUP_NAME"
    echo "Account:     $ACCOUNT_ID"
    echo "Members:     ${#EMAILS[@]}"
    echo "=========================================="
    echo ""

    # Step 1: Create IDC group
    echo "Step 1: Creating IDC group '$GROUP_NAME'..."
    local GROUP_ID=$(aws identitystore create-group \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --display-name "$GROUP_NAME" \
        --description "Team sandbox sharing group for $TEAM_NAME (Account: $ACCOUNT_ID)" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query "GroupId" --output text 2>/dev/null || true)

    if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
        # Group might already exist
        GROUP_ID=$(get_group_id "$GROUP_NAME")
        if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
            echo "   ❌ Failed to create group"
            exit 1
        fi
        echo "   ℹ️  Group already exists: $GROUP_ID"
    else
        echo "   ✅ Group created: $GROUP_ID"
    fi
    echo ""

    # Step 2: Add members to group
    echo "Step 2: Adding team members to group..."
    local ADDED=0
    local FAILED=0

    for EMAIL in "${EMAILS[@]}"; do
        local USER_ID=$(get_user_id "$EMAIL")
        if [ -z "$USER_ID" ] || [ "$USER_ID" == "None" ]; then
            echo "   ❌ $EMAIL - User not found in Identity Store"
            FAILED=$((FAILED + 1))
            continue
        fi

        aws identitystore create-group-membership \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --group-id "$GROUP_ID" \
            --member-id "{\"UserId\":\"$USER_ID\"}" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --output json > /dev/null 2>&1 \
            && echo "   ✅ $EMAIL added" && ADDED=$((ADDED + 1)) \
            || echo "   ⚠️  $EMAIL (already in group or error)" && ADDED=$((ADDED + 1))

        sleep 0.3
    done
    echo ""
    echo "   Added: $ADDED | Failed: $FAILED"
    echo ""

    # Step 3: Assign group to sandbox account
    echo "Step 3: Assigning group to sandbox account $ACCOUNT_ID..."
    local PS_ARN=$(get_permission_set_arn)
    echo "   Permission Set: $PS_ARN"

    aws sso-admin create-account-assignment \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --permission-set-arn "$PS_ARN" \
        --principal-id "$GROUP_ID" \
        --principal-type GROUP \
        --target-id "$ACCOUNT_ID" \
        --target-type AWS_ACCOUNT \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json > /dev/null 2>&1 \
        && echo "   ✅ Group assigned to account" \
        || echo "   ⚠️  Assignment may already exist"

    echo ""
    echo "=========================================="
    echo "✅ Team sandbox share created!"
    echo ""
    echo "Team members can now access account $ACCOUNT_ID via:"
    echo "  🔗 https://d-9667a833b5.awsapps.com/start"
    echo ""
    echo "To add more members later:"
    echo "  ./scripts/user-management/team-sandbox-share.sh add $TEAM_NAME newmember@co.com"
    echo "=========================================="
}

cmd_add() {
    local TEAM_NAME=$1
    shift
    local EMAILS=("$@")

    if [ -z "$TEAM_NAME" ] || [ ${#EMAILS[@]} -eq 0 ]; then
        echo "Usage: $0 add <team-name> <email1> [email2] ..."
        exit 1
    fi

    local GROUP_NAME="${GROUP_PREFIX}-${TEAM_NAME}"
    local GROUP_ID=$(get_group_id "$GROUP_NAME")

    if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
        echo "❌ Group '$GROUP_NAME' not found. Run 'create' first."
        exit 1
    fi

    echo "Adding members to team '$TEAM_NAME' (Group: $GROUP_ID)..."
    echo ""

    for EMAIL in "${EMAILS[@]}"; do
        local USER_ID=$(get_user_id "$EMAIL")
        if [ -z "$USER_ID" ] || [ "$USER_ID" == "None" ]; then
            echo "   ❌ $EMAIL - User not found"
            continue
        fi

        aws identitystore create-group-membership \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --group-id "$GROUP_ID" \
            --member-id "{\"UserId\":\"$USER_ID\"}" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --output json > /dev/null 2>&1 \
            && echo "   ✅ $EMAIL added" \
            || echo "   ⚠️  $EMAIL (already in group or error)"

        sleep 0.3
    done

    echo ""
    echo "✅ Done. New members can access the sandbox immediately via SSO portal."
}

cmd_remove() {
    local TEAM_NAME=$1
    shift
    local EMAILS=("$@")

    if [ -z "$TEAM_NAME" ] || [ ${#EMAILS[@]} -eq 0 ]; then
        echo "Usage: $0 remove <team-name> <email1> [email2] ..."
        exit 1
    fi

    local GROUP_NAME="${GROUP_PREFIX}-${TEAM_NAME}"
    local GROUP_ID=$(get_group_id "$GROUP_NAME")

    if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
        echo "❌ Group '$GROUP_NAME' not found."
        exit 1
    fi

    echo "Removing members from team '$TEAM_NAME'..."
    echo ""

    for EMAIL in "${EMAILS[@]}"; do
        local USER_ID=$(get_user_id "$EMAIL")
        if [ -z "$USER_ID" ] || [ "$USER_ID" == "None" ]; then
            echo "   ❌ $EMAIL - User not found"
            continue
        fi

        # Find membership ID
        local MEMBERSHIP_ID=$(aws identitystore list-group-memberships \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --group-id "$GROUP_ID" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --output json 2>/dev/null | jq -r ".GroupMemberships[] | select(.MemberId.UserId == \"$USER_ID\") | .MembershipId")

        if [ -z "$MEMBERSHIP_ID" ]; then
            echo "   ⚠️  $EMAIL - Not in group"
            continue
        fi

        aws identitystore delete-group-membership \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --membership-id "$MEMBERSHIP_ID" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --output json > /dev/null 2>&1 \
            && echo "   ✅ $EMAIL removed" \
            || echo "   ❌ $EMAIL - Failed to remove"

        sleep 0.3
    done

    echo ""
    echo "✅ Done. Removed members will lose access immediately."
}

cmd_delete() {
    local TEAM_NAME=$1
    local ACCOUNT_ID=$2

    if [ -z "$TEAM_NAME" ] || [ -z "$ACCOUNT_ID" ]; then
        echo "Usage: $0 delete <team-name> <sandbox-account-id>"
        exit 1
    fi

    local GROUP_NAME="${GROUP_PREFIX}-${TEAM_NAME}"
    local GROUP_ID=$(get_group_id "$GROUP_NAME")

    if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
        echo "❌ Group '$GROUP_NAME' not found."
        exit 1
    fi

    echo "🗑️  Deleting team sandbox share for '$TEAM_NAME'..."
    echo ""

    # Step 1: Remove account assignment
    echo "Step 1: Removing group from account $ACCOUNT_ID..."
    local PS_ARN=$(get_permission_set_arn)

    aws sso-admin delete-account-assignment \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --permission-set-arn "$PS_ARN" \
        --principal-id "$GROUP_ID" \
        --principal-type GROUP \
        --target-id "$ACCOUNT_ID" \
        --target-type AWS_ACCOUNT \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json > /dev/null 2>&1 \
        && echo "   ✅ Account assignment removed" \
        || echo "   ⚠️  Assignment may not exist"

    # Step 2: Delete group (removes all memberships)
    echo "Step 2: Deleting group '$GROUP_NAME'..."
    aws identitystore delete-group \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$GROUP_ID" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json > /dev/null 2>&1 \
        && echo "   ✅ Group deleted" \
        || echo "   ❌ Failed to delete group"

    echo ""
    echo "✅ Team sandbox share fully cleaned up."
}

cmd_list() {
    local TEAM_NAME=$1

    if [ -z "$TEAM_NAME" ]; then
        echo "Usage: $0 list <team-name>"
        exit 1
    fi

    local GROUP_NAME="${GROUP_PREFIX}-${TEAM_NAME}"
    local GROUP_ID=$(get_group_id "$GROUP_NAME")

    if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" == "None" ]; then
        echo "❌ Group '$GROUP_NAME' not found."
        exit 1
    fi

    echo "👥 Team '$TEAM_NAME' members (Group: $GROUP_ID):"
    echo ""

    aws identitystore list-group-memberships \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$GROUP_ID" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json 2>/dev/null | jq -r '.GroupMemberships[].MemberId.UserId' | while read USER_ID; do
        
        local USER_INFO=$(aws identitystore describe-user \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --user-id "$USER_ID" \
            --profile "$PROFILE" \
            --region "$REGION" \
            --query "[UserName, DisplayName]" --output text 2>/dev/null)
        
        echo "   • $USER_INFO"
    done

    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

COMMAND=$1
shift || true

case "$COMMAND" in
    create)  cmd_create "$@" ;;
    add)     cmd_add "$@" ;;
    remove)  cmd_remove "$@" ;;
    delete)  cmd_delete "$@" ;;
    list)    cmd_list "$@" ;;
    *)
        echo "Team Sandbox Sharing Script (Group-Based)"
        echo ""
        echo "Usage:"
        echo "  $0 create <team-name> <account-id> <email1> [email2] ...  Create team + assign to account"
        echo "  $0 add    <team-name> <email1> [email2] ...              Add members to existing team"
        echo "  $0 remove <team-name> <email1> [email2] ...              Remove members from team"
        echo "  $0 delete <team-name> <account-id>                       Delete team + revoke access"
        echo "  $0 list   <team-name>                                    List team members"
        echo ""
        echo "Examples:"
        echo "  $0 create alpha 123456789012 alice@co.com bob@co.com carol@co.com"
        echo "  $0 add alpha dave@co.com"
        echo "  $0 remove alpha bob@co.com"
        echo "  $0 list alpha"
        echo "  $0 delete alpha 123456789012"
        ;;
esac
