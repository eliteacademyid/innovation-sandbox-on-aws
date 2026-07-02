#!/usr/bin/env bash
# Populate DynamoDB with SSO IsbUsers role names for all sandbox accounts.
# Required because org SCP denies iam:ListRoles in sandbox accounts.
#
# Usage: ./scripts/cost-controls/populate-role-names.sh

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"
TABLE="isb-${NAMESPACE}-bedrock-throttle-events"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

SSO_INSTANCE=$(aws sso-admin list-instances --profile "$MGT_PROFILE" --region "$REGION" \
  --query 'Instances[0].InstanceArn' --output text)

# Find the IsbUsersPS permission set
PS_ARN=""
for PS in $(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE" \
  --profile "$MGT_PROFILE" --region "$REGION" --query 'PermissionSets' --output text); do
  NAME=$(aws sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE" \
    --permission-set-arn "$PS" --profile "$MGT_PROFILE" --region "$REGION" \
    --query 'PermissionSet.Name' --output text 2>/dev/null)
  if [[ "$NAME" == *"IsbUsers"* ]]; then
    PS_ARN="$PS"
    echo "Found permission set: $NAME → $PS_ARN"
    break
  fi
done

[[ -z "$PS_ARN" ]] && { echo "ERROR: IsbUsers permission set not found"; exit 1; }

# Get all account assignments for this permission set
echo "Discovering accounts with IsbUsersPS assignments..."
ACCOUNTS=$(aws sso-admin list-account-assignments --instance-arn "$SSO_INSTANCE" \
  --permission-set-arn "$PS_ARN" --account-id "*" \
  --profile "$MGT_PROFILE" --region "$REGION" \
  --query 'AccountAssignments[*].AccountId' --output text 2>/dev/null || true)

# If list-account-assignments doesn't support wildcard, iterate sandbox accounts
if [[ -z "$ACCOUNTS" ]]; then
  echo "Falling back to iterating known sandbox accounts..."
  ACCOUNTS=$(aws dynamodb scan --table-name "$TABLE" \
    --filter-expression "begins_with(account_id, :prefix)" \
    --expression-attribute-values '{":prefix":{"S":"ROLE#"}}' \
    --region "$REGION" --profile "$HUB_PROFILE" \
    --query 'Items[*].account_id.S' --output text 2>/dev/null | sed 's/ROLE#//g')
fi

# For each account, discover the role name using iam:ListRoles from a profile that has access
COUNT=0
for ACCT_PROFILE_LINE in $(grep -l "sso_account_id.*=" ~/.aws/config 2>/dev/null || true); do
  : # This approach won't scale. Use SSO admin API instead.
done

# Use SSO admin to get provisioned role names per account
# The role name format: AWSReservedSSO_{PermSetName}_{hash}
# The hash is derived from: first 16 chars of SHA256(account_id + permission_set_id)
# Actually it's opaque — we need to read it from each account.

echo ""
echo "To populate remaining accounts, run from each sandbox profile:"
echo '  for PROFILE in eta-sandbox-*; do'
echo '    ACCT=$(aws sts get-caller-identity --profile $PROFILE --query Account --output text)'
echo '    ROLE=$(aws iam list-roles --profile $PROFILE --query "Roles[?starts_with(RoleName,\`AWSReservedSSO_myisb_IsbUsers\`)].RoleName" --output text)'
echo '    aws dynamodb put-item --table-name isb-myisb-bedrock-throttle-events \'
echo '      --item "{\"account_id\":{\"S\":\"ROLE#$ACCT\"},\"throttled_at\":{\"N\":\"0\"},\"sso_role_name\":{\"S\":\"$ROLE\"}}" \'
echo '      --region ap-southeast-1 --profile eta-isb-andrian'
echo '  done'
echo ""

# Auto-populate from available profiles
for PROFILE in $(grep '\[profile eta-sandbox-' ~/.aws/config | sed 's/\[profile //;s/\]//'); do
  ACCT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null) || continue
  ROLE=$(aws iam list-roles --profile "$PROFILE" \
    --query "Roles[?starts_with(RoleName,\`AWSReservedSSO_${NAMESPACE}_IsbUsers\`)].RoleName | [0]" \
    --output text 2>/dev/null) || continue
  [[ -z "$ROLE" || "$ROLE" == "None" ]] && continue
  
  aws dynamodb put-item --table-name "$TABLE" \
    --item "{\"account_id\":{\"S\":\"ROLE#${ACCT}\"},\"throttled_at\":{\"N\":\"0\"},\"sso_role_name\":{\"S\":\"${ROLE}\"}}" \
    --region "$REGION" --profile "$HUB_PROFILE" 2>/dev/null
  echo "  ✓ $ACCT → $ROLE"
  COUNT=$((COUNT + 1))
done

echo ""
echo "✅ Populated $COUNT account role mappings in $TABLE"
