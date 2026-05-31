#!/usr/bin/env bash
# ============================================================================
# Universal University Team Sandbox Setup
# ============================================================================
#
# Works for any university (APU, MMU, etc.) with the same scheme:
#   1. Creates IDC users for all team members
#   2. Adds all users to ISB Users group + SAML app
#   3. Creates team group per team, assigns to sandbox account
#   4. Creates team-leaders group for Kiro subscriptions
#
# Usage:
#   ./scripts/user-management/setup-university-teams.sh <university-code> <teams-csv-file>
#
# Examples:
#   ./scripts/user-management/setup-university-teams.sh apu scripts/user-management/apu-finalist-teams.csv
#   ./scripts/user-management/setup-university-teams.sh mmu scripts/user-management/mmu-finalist-teams.csv
#   ./scripts/user-management/setup-university-teams.sh utar scripts/user-management/utar-finalist-teams.csv
#   ./scripts/user-management/setup-university-teams.sh sunway scripts/user-management/sunway-finalist-teams.csv
#
# CSV Format (with header):
#   team_name,sandbox_account_id,email,first_name,last_name
#   team-alpha,123456789012,leader@uni.edu,Alice,Smith
#   team-alpha,123456789012,member2@uni.edu,Bob,Jones
#
# Notes:
#   - First email per team is treated as team leader
#   - Team leader group is named: isb-team-leaders-<university>-finalist
#   - Team groups are named: isb-team-<team-name>
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
ISB_USERS_GROUP_ID="892ac5bc-b031-70aa-f100-e8476c794662"

# ── Parse Arguments ───────────────────────────────────────────────────────────
UNI_CODE=$1
CSV_FILE=$2

if [ -z "$UNI_CODE" ] || [ -z "$CSV_FILE" ]; then
    echo "Usage: $0 <university-code> <teams-csv-file>"
    echo ""
    echo "Examples:"
    echo "  $0 apu scripts/user-management/apu-finalist-teams.csv"
    echo "  $0 mmu scripts/user-management/mmu-finalist-teams.csv"
    echo "  $0 utar scripts/user-management/utar-finalist-teams.csv"
    echo "  $0 sunway scripts/user-management/sunway-finalist-teams.csv"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo "❌ Error: CSV file not found: $CSV_FILE"
    exit 1
fi

LEADERS_GROUP_NAME="isb-team-leaders-${UNI_CODE}-finalist"

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

add_to_group() {
    aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$1" --member-id "{\"UserId\":\"$2\"}" \
        --profile "$PROFILE" --region "$REGION" \
        --output json > /dev/null 2>&1 || true
}

assign_to_saml_app() {
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

TEAM_COUNT=$(tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u | wc -l | xargs)
MEMBER_COUNT=$(tail -n +2 "$CSV_FILE" | wc -l | xargs)

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  University Team Sandbox Setup                                 ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  University: ${UNI_CODE^^}"
echo "║  CSV: $(basename "$CSV_FILE")"
echo "║  Teams: $TEAM_COUNT | Members: $MEMBER_COUNT"
echo "║  Leaders group: $LEADERS_GROUP_NAME"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Proceed? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    echo "Cancelled."; exit 0
fi
echo ""

# ── Phase 1: Create/Verify Users + Add to ISB Users Group ────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Creating Users + Adding to ISB Users Group"
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
            assign_to_saml_app "$USER_ID"
        else
            echo "  ❌ $email — FAILED"
            USERS_FAILED=$((USERS_FAILED + 1))
            continue
        fi
    fi

    # Add to ISB Users group
    add_to_group "$ISB_USERS_GROUP_ID" "$USER_ID"
    sleep 0.3
done < <(tail -n +2 "$CSV_FILE")

echo ""
echo "  Summary: Created=$USERS_CREATED | Existing=$USERS_EXISTING | Failed=$USERS_FAILED"
echo ""

# ── Phase 2: Create Team Leaders Group ────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Creating Team Leaders Group ($LEADERS_GROUP_NAME)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LEADERS_GROUP_ID=$(get_group_id "$LEADERS_GROUP_NAME")
if [ -n "$LEADERS_GROUP_ID" ] && [ "$LEADERS_GROUP_ID" != "None" ]; then
    echo "  ℹ️  Group exists: $LEADERS_GROUP_ID"
else
    LEADERS_GROUP_ID=$(create_group "$LEADERS_GROUP_NAME" "CendekiAwan ${UNI_CODE^^} Finalist - Team Leaders (Kiro)")
    echo "  ✅ Group created: $LEADERS_GROUP_ID"
fi

# Add first member of each team (leader) to leaders group
LEADERS_ADDED=0
while IFS=',' read -r team_name account_id; do
    team_name=$(echo "$team_name" | xargs)
    [ -z "$team_name" ] && continue

    # Get first email for this team (leader)
    LEADER_EMAIL=$(tail -n +2 "$CSV_FILE" | grep "^${team_name}," | head -1 | cut -d',' -f3 | xargs)
    if [ -z "$LEADER_EMAIL" ]; then continue; fi

    USER_ID=$(get_user_id "$LEADER_EMAIL")
    if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
        add_to_group "$LEADERS_GROUP_ID" "$USER_ID"
        echo "  ✅ $LEADER_EMAIL (${team_name})"
        LEADERS_ADDED=$((LEADERS_ADDED + 1))
    fi
    sleep 0.2
done < <(tail -n +2 "$CSV_FILE" | cut -d',' -f1,2 | sort -u)

echo "  Leaders added: $LEADERS_ADDED"
echo ""

# ── Phase 3: Permission Set ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: Looking up Permission Set"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PS_ARN=$(get_permission_set_arn)
if [ -z "$PS_ARN" ]; then
    echo "  ❌ Could not find IsbUsersPS. Aborting."
    exit 1
fi
echo "  ✅ $PS_ARN"
echo ""

# ── Phase 4: Create Team Groups & Assign to Accounts ─────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 4: Creating Team Groups & Assigning to Accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TEAMS_CREATED=0
TEAMS_FAILED=0

while IFS=',' read -r team_name account_id; do
    team_name=$(echo "$team_name" | xargs)
    account_id=$(echo "$account_id" | xargs)
    [ -z "$team_name" ] || [ -z "$account_id" ] && continue

    if [ "$account_id" = "PENDING" ]; then
        echo "┌── $team_name → SKIPPED (account PENDING)"
        echo "└──"
        echo ""
        continue
    fi

    GROUP_NAME="${GROUP_PREFIX}-${team_name}"
    echo "┌── $team_name → $account_id (group: $GROUP_NAME)"

    # Create or get group
    GROUP_ID=$(get_group_id "$GROUP_NAME")
    if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ]; then
        echo "│  ℹ️  Group exists: $GROUP_ID"
    else
        GROUP_ID=$(create_group "$GROUP_NAME" "${UNI_CODE^^} Finalist: $team_name (Account: $account_id)")
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
            add_to_group "$GROUP_ID" "$USER_ID"
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
echo "║  COMPLETE — ${UNI_CODE^^} Teams Setup"
echo "║  Users: Created=$USERS_CREATED Existing=$USERS_EXISTING Failed=$USERS_FAILED"
echo "║  Teams: Setup=$TEAMS_CREATED Failed=$TEAMS_FAILED"
echo "║  Leaders Group: $LEADERS_GROUP_NAME ($LEADERS_ADDED leaders)"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  NEXT STEPS:                                                   ║"
echo "║  1. Send password resets for new users via IDC console         ║"
echo "║  2. Add leaders group to Kiro Pro subscription                 ║"
echo "║  3. Share SSO Portal: https://eliteacademy.awsapps.com/start   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
