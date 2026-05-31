#!/usr/bin/env bash
# ============================================================================
# Full University Onboarding — End-to-End Automation
# ============================================================================
#
# This script does EVERYTHING in one run:
#   1. Creates IDC users for all team members
#   2. Adds all users to ISB Users group + SAML app
#   3. Assigns a lease (sandbox account) to each team leader via ISB API
#   4. Creates team groups and assigns all members to their sandbox account
#   5. Creates team-leaders group for Kiro Pro subscription
#   6. Subscribes team leaders to Kiro Pro via console (manual step noted)
#
# Usage:
#   ./scripts/user-management/full-university-onboarding.sh <university-code> <teams-csv-file> <lease-template-uuid>
#
# Examples:
#   ./scripts/user-management/full-university-onboarding.sh mmu mmu-finalist-teams.csv 80af4999-a942-43df-8662-eee32b25a029
#   ./scripts/user-management/full-university-onboarding.sh utar utar-finalist-teams.csv a5436dde-de4d-46a2-bd5f-d4a068b8d93d
#
# CSV Format (with header — NO account_id column needed):
#   team_name,email,first_name,last_name
#   dewan-ai,leader@uni.edu,Alice,Smith
#   dewan-ai,member2@uni.edu,Bob,Jones
#   virtual-lab,leader2@uni.edu,Carol,Davis
#
# Notes:
#   - First email per team = team leader (gets the lease)
#   - Account IDs are auto-assigned by ISB from the pool
#   - Requires valid JWT token (auto-generated from Secrets Manager)
#
# ============================================================================

set -e

# ── Configuration ─────────────────────────────────────────────────────────────
IDENTITY_STORE_ID="d-9667a833b5"
SSO_INSTANCE_ARN="arn:aws:sso:::instance/ssoins-821055714a3e49c5"
APPLICATION_ARN="arn:aws:sso::862099794180:application/ssoins-821055714a3e49c5/apl-66664d3a4fcad754"
PROFILE="eta-andrian"
ISB_PROFILE="eta-isb-andrian"
REGION="ap-southeast-1"
GROUP_PREFIX="isb-team"
ISB_USERS_GROUP_ID="892ac5bc-b031-70aa-f100-e8476c794662"
ISB_API="https://ob90f1sd45.execute-api.ap-southeast-1.amazonaws.com/prod"
JWT_SECRET_NAME="/InnovationSandbox/myisb/Auth/JwtSecret"

# ── Parse Arguments ───────────────────────────────────────────────────────────
UNI_CODE=$1
CSV_FILE=$2
LEASE_TEMPLATE_UUID=$3

if [ -z "$UNI_CODE" ] || [ -z "$CSV_FILE" ] || [ -z "$LEASE_TEMPLATE_UUID" ]; then
    echo "Usage: $0 <university-code> <teams-csv-file> <lease-template-uuid>"
    echo ""
    echo "Examples:"
    echo "  $0 mmu mmu-teams.csv 80af4999-a942-43df-8662-eee32b25a029"
    echo "  $0 utar utar-teams.csv a5436dde-de4d-46a2-bd5f-d4a068b8d93d"
    echo ""
    echo "CSV format (NO account_id column — accounts auto-assigned):"
    echo "  team_name,email,first_name,last_name"
    echo "  team-alpha,leader@uni.edu,Alice,Smith"
    echo "  team-alpha,member2@uni.edu,Bob,Jones"
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

generate_jwt() {
    local SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "$JWT_SECRET_NAME" \
        --profile "$ISB_PROFILE" --region "$REGION" \
        --query "SecretString" --output text 2>/dev/null)
    python3 -c "
import jwt, time
payload = {
    'user': {
        'email': 'andrian@eliteacademy.id',
        'displayName': 'Andrian Maulana',
        'userName': 'andrian@eliteacademy.id',
        'roles': ['Admin', 'Manager', 'User']
    },
    'iat': int(time.time()),
    'exp': int(time.time()) + 3600
}
print(jwt.encode(payload, '''$SECRET''', algorithm='HS256'))
"
}

assign_lease() {
    local EMAIL=$1
    local COMMENT=$2
    local TOKEN=$3
    curl -s -X POST "$ISB_API/leases" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"leaseTemplateUuid\":\"$LEASE_TEMPLATE_UUID\",\"userEmail\":\"$EMAIL\",\"comments\":\"$COMMENT\"}" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────────────

TEAM_COUNT=$(tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u | wc -l | xargs)
MEMBER_COUNT=$(tail -n +2 "$CSV_FILE" | wc -l | xargs)

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Full University Onboarding                                    ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  University:      ${UNI_CODE^^}"
echo "║  Teams:           $TEAM_COUNT"
echo "║  Members:         $MEMBER_COUNT"
echo "║  Lease Template:  $LEASE_TEMPLATE_UUID"
echo "║  Leaders Group:   $LEADERS_GROUP_NAME"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Proceed with full onboarding? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    echo "Cancelled."; exit 0
fi
echo ""

# ── Phase 1: Create Users + Add to ISB Users Group ───────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Creating Users + ISB Users Group"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

USERS_CREATED=0
USERS_EXISTING=0

while IFS=',' read -r team_name email first_name last_name; do
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
            continue
        fi
    fi
    add_to_group "$ISB_USERS_GROUP_ID" "$USER_ID"
    sleep 0.3
done < <(tail -n +2 "$CSV_FILE")

echo ""
echo "  Users: Created=$USERS_CREATED | Existing=$USERS_EXISTING"
echo ""

# ── Phase 2: Generate JWT + Assign Leases to Team Leaders ────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Assigning Leases to Team Leaders"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  Generating JWT token..."
JWT_TOKEN=$(generate_jwt)
if [ -z "$JWT_TOKEN" ]; then
    echo "  ❌ Failed to generate JWT. Check ISB profile."
    exit 1
fi
echo "  ✅ Token generated"
echo ""

# Track team -> account mapping
declare -A TEAM_ACCOUNTS 2>/dev/null || true
LEASE_RESULTS_FILE="/tmp/${UNI_CODE}-lease-results.json"
echo "[]" > "$LEASE_RESULTS_FILE"

# Get unique teams and their leaders (first email per team)
while IFS=',' read -r team_name; do
    team_name=$(echo "$team_name" | xargs)
    [ -z "$team_name" ] && continue

    LEADER_EMAIL=$(tail -n +2 "$CSV_FILE" | grep "^${team_name}," | head -1 | cut -d',' -f2 | xargs)
    if [ -z "$LEADER_EMAIL" ]; then continue; fi

    COMMENT="CendekiAwan ${UNI_CODE^^} Finalist - Team ${team_name}"
    echo "  Assigning lease to $LEADER_EMAIL ($team_name)..."

    RESPONSE=$(assign_lease "$LEADER_EMAIL" "$COMMENT" "$JWT_TOKEN")
    STATUS=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status','error'))" 2>/dev/null)

    if [ "$STATUS" = "success" ]; then
        ACCOUNT_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('data',{}).get('awsAccountId',''))" 2>/dev/null)
        echo "  ✅ $team_name → Account $ACCOUNT_ID"
        # Save mapping
        echo "$team_name,$ACCOUNT_ID" >> "/tmp/${UNI_CODE}-team-accounts.csv"
    else
        ERROR=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('data',{}).get('errors',[{}])[0].get('message',d.get('Message','Unknown')))" 2>/dev/null)
        echo "  ❌ $team_name — $ERROR"
    fi
    sleep 1
done < <(tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u)

echo ""

# ── Phase 3: Create Team Leaders Group ────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: Creating Team Leaders Group (for Kiro)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LEADERS_GROUP_ID=$(get_group_id "$LEADERS_GROUP_NAME")
if [ -n "$LEADERS_GROUP_ID" ] && [ "$LEADERS_GROUP_ID" != "None" ]; then
    echo "  ℹ️  Group exists: $LEADERS_GROUP_ID"
else
    LEADERS_GROUP_ID=$(create_group "$LEADERS_GROUP_NAME" "CendekiAwan ${UNI_CODE^^} Finalist - Team Leaders (Kiro Pro)")
    echo "  ✅ Group created: $LEADERS_GROUP_ID"
fi

while IFS=',' read -r team_name; do
    team_name=$(echo "$team_name" | xargs)
    [ -z "$team_name" ] && continue
    LEADER_EMAIL=$(tail -n +2 "$CSV_FILE" | grep "^${team_name}," | head -1 | cut -d',' -f2 | xargs)
    USER_ID=$(get_user_id "$LEADER_EMAIL")
    if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
        add_to_group "$LEADERS_GROUP_ID" "$USER_ID"
        echo "  ✅ $LEADER_EMAIL"
    fi
    sleep 0.2
done < <(tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u)

echo ""

# ── Phase 4: Create Team Groups + Assign to Accounts ─────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 4: Creating Team Groups & Assigning to Accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PS_ARN=$(get_permission_set_arn)
if [ -z "$PS_ARN" ]; then
    echo "  ❌ Could not find IsbUsersPS. Aborting Phase 4."
    exit 1
fi

TEAMS_CREATED=0

if [ -f "/tmp/${UNI_CODE}-team-accounts.csv" ]; then
    while IFS=',' read -r team_name account_id; do
        team_name=$(echo "$team_name" | xargs)
        account_id=$(echo "$account_id" | xargs)
        [ -z "$team_name" ] || [ -z "$account_id" ] && continue

        GROUP_NAME="${GROUP_PREFIX}-${team_name}"
        echo "┌── $team_name → $account_id"

        GROUP_ID=$(get_group_id "$GROUP_NAME")
        if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ]; then
            echo "│  ℹ️  Group exists: $GROUP_ID"
        else
            GROUP_ID=$(create_group "$GROUP_NAME" "${UNI_CODE^^} Finalist: $team_name (Account: $account_id)")
            if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ]; then
                echo "│  ✅ Group created: $GROUP_ID"
            else
                echo "│  ❌ Failed"
                echo "└──"
                continue
            fi
        fi

        # Add all team members
        while IFS=',' read -r _tn member_email _fn _ln; do
            member_email=$(echo "$member_email" | xargs)
            [ -z "$member_email" ] && continue
            USER_ID=$(get_user_id "$member_email")
            if [ -n "$USER_ID" ] && [ "$USER_ID" != "None" ]; then
                add_to_group "$GROUP_ID" "$USER_ID"
                echo "│  ✅ $member_email"
            fi
            sleep 0.2
        done < <(tail -n +2 "$CSV_FILE" | grep "^${team_name},")

        # Assign group to account
        assign_group_to_account "$GROUP_ID" "$account_id" "$PS_ARN" \
            && echo "│  ✅ Group → Account" \
            || echo "│  ⚠️  Assignment may exist"
        TEAMS_CREATED=$((TEAMS_CREATED + 1))
        echo "└──"
        echo ""
        sleep 0.5
    done < "/tmp/${UNI_CODE}-team-accounts.csv"
else
    echo "  ⚠️  No team-account mappings found. Leases may have failed."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ ONBOARDING COMPLETE — ${UNI_CODE^^}"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Users created:    $USERS_CREATED"
echo "║  Users existing:   $USERS_EXISTING"
echo "║  Teams setup:      $TEAMS_CREATED"
echo "║  Leaders group:    $LEADERS_GROUP_NAME"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  MANUAL STEPS REMAINING:                                       ║"
echo "║  1. Send password resets via IDC console                       ║"
echo "║  2. Add '$LEADERS_GROUP_NAME' to Kiro Pro in console           ║"
echo "║     → Kiro console → Users & Groups → Add group → Kiro Pro    ║"
echo "║  3. Share SSO Portal: https://eliteacademy.awsapps.com/start   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

# Save results
if [ -f "/tmp/${UNI_CODE}-team-accounts.csv" ]; then
    echo ""
    echo "Team → Account mapping saved to: /tmp/${UNI_CODE}-team-accounts.csv"
    cat "/tmp/${UNI_CODE}-team-accounts.csv"
fi
