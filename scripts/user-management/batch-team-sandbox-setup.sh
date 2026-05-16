#!/usr/bin/env bash
# ============================================================================
# Batch Team Sandbox Setup for Cendekiawan APU Finalist Teams
# ============================================================================
#
# Usage:
#   ./scripts/user-management/batch-team-sandbox-setup.sh <teams-csv-file>
#
# CSV Format (with header):
#   team_name,sandbox_account_id,email,first_name,last_name
#
# ============================================================================

set -e

# ── Configuration ─────────────────────────────────────────────────────────────
IDENTITY_STORE_ID="d-9667a833b5"
SSO_INSTANCE_ARN="arn:aws:sso:::instance/ssoins-821055714a3e49c5"
APPLICATION_ARN="arn:aws:sso::862099794180:application/ssoins-821055714a3e49c5/apl-66664d3a4fcad754"
PROFILE="eta-andrian"
REGION="ap-southeast-1"
GROUP_PREFIX="isb-team"
USER_GROUP_ID="81098d36-e041-703d-e15b-90337bb290a1"

CSV_FILE=$1

if [ -z "$CSV_FILE" ] || [ ! -f "$CSV_FILE" ]; then
    echo "Usage: $0 <teams-csv-file>"
    exit 1
fi

# ── Helper Functions ──────────────────────────────────────────────────────────

get_user_id() {
    aws identitystore get-user-id \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"emails.value\",\"AttributeValue\":\"$1\"}}" \
        --profile "$PROFILE" --region "$REGION" \
        --query "UserId" --output text 2>/dev/null || echo ""
}

create_user() {
    aws identitystore create-user \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --user-name "$1" \
        --display-name "$2 $3" \
        --name "{\"GivenName\":\"$2\",\"FamilyName\":\"$3\"}" \
        --emails "[{\"Value\":\"$1\",\"Type\":\"work\",\"Primary\":true}]" \
        --profile "$PROFILE" --region "$REGION" \
        --query "UserId" --output text 2>/dev/null || echo ""
}

add_user_to_isb_group() {
    aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$USER_GROUP_ID" \
        --member-id "{\"UserId\":\"$1\"}" \
        --profile "$PROFILE" --region "$REGION" \
        --output json > /dev/null 2>&1 || true
}

assign_user_to_saml_app() {
    aws sso-admin create-application-assignment \
        --application-arn "$APPLICATION_ARN" \
        --principal-id "$1" --principal-type USER \
        --profile "$PROFILE" --region "$REGION" \
        --output json > /dev/null 2>&1 || true
}

get_group_id() {
    aws identitystore get-group-id \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"DisplayName\",\"AttributeValue\":\"$1\"}}" \
        --profile "$PROFILE" --region "$REGION" \
        --query "GroupId" --output text 2>/dev/null || echo ""
}

create_group() {
    aws identitystore create-group \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --display-name "$1" --description "$2" \
        --profile "$PROFILE" --region "$REGION" \
        --query "GroupId" --output text 2>/dev/null || echo ""
}

add_user_to_team_group() {
    aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$1" --member-id "{\"UserId\":\"$2\"}" \
        --profile "$PROFILE" --region "$REGION" \
        --output json > /dev/null 2>&1 || true
}

get_permission_set_arn() {
    aws sso-admin list-permission-sets \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --profile "$PROFILE" --region "$REGION" \
        --output json | jq -r '.PermissionSets[]' | while read ps; do
        NAME=$(aws sso-admin describe-permission-set \
            --instance-arn "$SSO_INSTANCE_ARN" \
            --permission-set-arn "$ps" \
            --profile "$PROFILE" --region "$REGION" \
            --query "PermissionSet.Name" --output text 2>/dev/null)
        if [[ "$NAME" == *"IsbUsersPS"* ]] || [[ "$NAME" == *"IsbUsers"* ]]; then
            echo "$ps"
            return
        fi
    done
}

assign_group_to_account() {
    aws sso-admin create-account-assignment \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --permission-set-arn "$3" \
        --principal-id "$1" --principal-type GROUP \
        --target-id "$2" --target-type AWS_ACCOUNT \
        --profile "$PROFILE" --region "$REGION" \
        --output json > /dev/null 2>&1
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Batch Team Sandbox Setup - Cendekiawan APU Finalist           ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  CSV: $(basename "$CSV_FILE") | Profile: $PROFILE | Region: $REGION"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

TEAM_COUNT=$(tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u | wc -l | xargs)
MEMBER_COUNT=$(tail -n +2 "$CSV_FILE" | wc -l | xargs)
echo "📊 $TEAM_COUNT teams, $MEMBER_COUNT members"
echo ""

read -p "Proceed? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    echo "Cancelled."; exit 0
fi
echo ""

# ── Phase 1: Create/Verify Users ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Creating/Verifying Users"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

USERS_CREATED=0
USERS_EXISTING=0
USERS_FAILED=0

while IFS=',' read -r team_name account_id email first_name last_name; do
    email=$(echo "$email" | xargs)
    first_name=$(echo "$first_name" | xargs)
    last_name=$(echo "$last_name" | xargs)
    [ -z "$email" ] && continue

    USER_ID=$(get_user_id "$email")

    if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
        echo "  ℹ️  $email — exists"
        USERS_EXISTING=$((USERS_EXISTING + 1))
    else
        USER_ID=$(create_user "$email" "$first_name" "$last_name")
        if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
            echo "  ✅ $email — created"
            USERS_CREATED=$((USERS_CREATED + 1))
            add_user_to_isb_group "$USER_ID"
            assign_user_to_saml_app "$USER_ID"
        else
            echo "  ❌ $email — FAILED"
            USERS_FAILED=$((USERS_FAILED + 1))
        fi
    fi
    sleep 0.3
done < <(tail -n +2 "$CSV_FILE")

echo ""
echo "  Summary: Created=$USERS_CREATED | Existing=$USERS_EXISTING | Failed=$USERS_FAILED"
echo ""

# ── Phase 2: Permission Set ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Looking up Permission Set"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PS_ARN=$(get_permission_set_arn)
if [ -z "$PS_ARN" ]; then
    echo "  ❌ Could not find IsbUsersPS. Aborting."
    exit 1
fi
echo "  ✅ $PS_ARN"
echo ""

# ── Phase 3: Create Groups & Assign ──────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: Creating Groups & Assigning to Accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TEAMS_CREATED=0
TEAMS_FAILED=0

while IFS=',' read -r team_name account_id; do
    team_name=$(echo "$team_name" | xargs)
    account_id=$(echo "$account_id" | xargs)
    [ -z "$team_name" ] || [ -z "$account_id" ] && continue

    GROUP_NAME="${GROUP_PREFIX}-${team_name}"
    echo "┌── $team_name → $account_id (group: $GROUP_NAME)"

    # Create or get group
    GROUP_ID=$(get_group_id "$GROUP_NAME")
    if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ]; then
        echo "│  ℹ️  Group exists: $GROUP_ID"
    else
        GROUP_ID=$(create_group "$GROUP_NAME" "APU Finalist: $team_name (Account: $account_id)")
        if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ]; then
            echo "│  ✅ Group created: $GROUP_ID"
        else
            echo "│  ❌ Failed to create group"
            TEAMS_FAILED=$((TEAMS_FAILED + 1))
            echo "└──"
            continue
        fi
    fi

    # Add members
    while IFS=',' read -r _tn _aid member_email _fn _ln; do
        member_email=$(echo "$member_email" | xargs)
        [ -z "$member_email" ] && continue
        USER_ID=$(get_user_id "$member_email")
        if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
            add_user_to_team_group "$GROUP_ID" "$USER_ID"
            echo "│  ✅ $member_email"
        else
            echo "│  ⚠️  $member_email (not found)"
        fi
        sleep 0.2
    done < <(tail -n +2 "$CSV_FILE" | grep "^${team_name},")

    # Assign group to account
    if assign_group_to_account "$GROUP_ID" "$account_id" "$PS_ARN"; then
        echo "│  ✅ Group → Account assigned"
        TEAMS_CREATED=$((TEAMS_CREATED + 1))
    else
        echo "│  ⚠️  Assignment may already exist"
        TEAMS_CREATED=$((TEAMS_CREATED + 1))
    fi
    echo "└──"
    echo ""
    sleep 0.5
done < <(tail -n +2 "$CSV_FILE" | cut -d',' -f1,2 | sort -u)

# ── Done ──────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  COMPLETE                                                      ║"
echo "║  Users: Created=$USERS_CREATED Existing=$USERS_EXISTING Failed=$USERS_FAILED"
echo "║  Teams: Setup=$TEAMS_CREATED Failed=$TEAMS_FAILED"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  NEXT: Send password resets for new users, then share:         ║"
echo "║  🔗 https://d-9667a833b5.awsapps.com/start                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
