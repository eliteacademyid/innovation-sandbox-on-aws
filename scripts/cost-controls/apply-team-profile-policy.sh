#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Apply IAM policy to a sandbox account that restricts Bedrock usage
# to only the team's Application Inference Profiles.
#
# This creates an SCP (account-level) that:
#   - Denies bedrock:InvokeModel* on foundation model ARNs
#   - Allows bedrock:InvokeModel* only via the team's inference profile ARNs
#
# Usage:
#   ./scripts/cost-controls/apply-team-profile-policy.sh <team-name> <account-id>
#
# Example:
#   ./scripts/cost-controls/apply-team-profile-policy.sh smartwaste 100731996679
#
# Prerequisites:
#   - Team inference profiles already created (run create-team-inference-profiles.sh first)
#   - Management account profile with organizations:* permissions

set -euo pipefail

TEAM_NAME="${1:?Usage: $0 <team-name> <account-id>}"
ACCOUNT_ID="${2:?Usage: $0 <team-name> <account-id>}"

NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-us-east-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"

log() { printf "\033[1;36m[profile-policy]\033[0m %s\n" "$*"; }

# Construct profile ARNs (they live in hub account)
CLAUDE_PROFILE_ARN="arn:aws:bedrock:${REGION}:${HUB_ACCOUNT_ID}:inference-profile/isb-${NAMESPACE}-${TEAM_NAME}-claude"
NOVA_PROFILE_ARN="arn:aws:bedrock:${REGION}:${HUB_ACCOUNT_ID}:inference-profile/isb-${NAMESPACE}-${TEAM_NAME}-nova"

SCP_NAME="isb-${NAMESPACE}-profile-only-${TEAM_NAME}"

log "Team:     $TEAM_NAME"
log "Account:  $ACCOUNT_ID"
log "Claude:   $CLAUDE_PROFILE_ARN"
log "Nova:     $NOVA_PROFILE_ARN"
log "SCP:      $SCP_NAME"
echo

# Build SCP policy
POLICY_CONTENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDirectModelInvocation",
      "Effect": "Deny",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*"
      ],
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalARN": [
            "arn:aws:iam::*:role/isb-*",
            "arn:aws:iam::*:role/AWSReservedSSO_*_IsbAdmins*"
          ]
        }
      }
    },
    {
      "Sid": "AllowTeamInferenceProfiles",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": [
        "${CLAUDE_PROFILE_ARN}",
        "${NOVA_PROFILE_ARN}",
        "arn:aws:bedrock:*::inference-profile/us.anthropic.claude-sonnet-4-6"
      ]
    }
  ]
}
EOF
)

# Check if SCP already exists
log "Checking for existing SCP..."
EXISTING_ID=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
  --profile "$MGT_PROFILE" --query "Policies[?Name=='${SCP_NAME}'].Id | [0]" --output text 2>/dev/null)

if [[ "$EXISTING_ID" != "None" && -n "$EXISTING_ID" ]]; then
  log "SCP exists ($EXISTING_ID), updating content..."
  aws organizations update-policy \
    --policy-id "$EXISTING_ID" \
    --content "$POLICY_CONTENT" \
    --profile "$MGT_PROFILE" >/dev/null
  POLICY_ID="$EXISTING_ID"
else
  log "Creating SCP..."
  POLICY_ID=$(aws organizations create-policy \
    --name "$SCP_NAME" \
    --description "Force team ${TEAM_NAME} to use inference profiles for Bedrock attribution" \
    --type SERVICE_CONTROL_POLICY \
    --content "$POLICY_CONTENT" \
    --profile "$MGT_PROFILE" \
    --query "Policy.PolicySummary.Id" --output text)
  log "Created SCP: $POLICY_ID"
fi

# Attach to account
log "Attaching SCP to account $ACCOUNT_ID..."
aws organizations attach-policy \
  --policy-id "$POLICY_ID" \
  --target-id "$ACCOUNT_ID" \
  --profile "$MGT_PROFILE" 2>&1 | grep -v "DuplicatePolicyAttachmentException" || true

log "✓ Done. Team '$TEAM_NAME' in account $ACCOUNT_ID is now restricted to inference profiles only."
log ""
log "Students should use these model IDs in their code:"
log "  Claude: $CLAUDE_PROFILE_ARN"
log "  Nova:   $NOVA_PROFILE_ARN"
log ""
log "To remove this restriction:"
log "  aws organizations detach-policy --policy-id $POLICY_ID --target-id $ACCOUNT_ID --profile $MGT_PROFILE"
log "  aws organizations delete-policy --policy-id $POLICY_ID --profile $MGT_PROFILE"
