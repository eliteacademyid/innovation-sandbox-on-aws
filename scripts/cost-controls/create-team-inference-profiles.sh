#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provision Bedrock Application Inference Profiles for a team.
# Creates per-team profiles for Claude Sonnet and Nova Pro, enabling
# per-team cost attribution via CloudWatch metrics.
#
# Usage:
#   ./scripts/cost-controls/create-team-inference-profiles.sh <team-name> <account-id>
#
# Example:
#   ./scripts/cost-controls/create-team-inference-profiles.sh smartwaste 100731996679
#
# What it creates in the sandbox account:
#   - Application inference profile: isb-myisb-<team>-claude
#   - Application inference profile: isb-myisb-<team>-nova
#   - IAM inline policy on IsbUsers role: restrict to profiles only
#
# Prerequisites:
#   - Hub profile with bedrock:CreateInferenceProfile permission
#   - Target sandbox account accessible via management SSO

set -euo pipefail

TEAM_NAME="${1:?Usage: $0 <team-name> <account-id>}"
ACCOUNT_ID="${2:?Usage: $0 <team-name> <account-id>}"

NAMESPACE="${NAMESPACE:-myisb}"
REGION="${REGION:-us-east-1}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

# Source model (system-defined inference profile for cross-region)
CLAUDE_SOURCE="arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-sonnet-4-6"
NOVA_SOURCE="arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0"

CLAUDE_PROFILE_NAME="isb-${NAMESPACE}-${TEAM_NAME}-claude"
NOVA_PROFILE_NAME="isb-${NAMESPACE}-${TEAM_NAME}-nova"

log() { printf "\033[1;36m[profiles]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }

log "Team:       $TEAM_NAME"
log "Account:    $ACCOUNT_ID"
log "Region:     $REGION"
log "Profiles:   $CLAUDE_PROFILE_NAME, $NOVA_PROFILE_NAME"
echo

# ─── Create Claude Profile ─────────────────────────────────────────────────────

log "Creating Claude inference profile: $CLAUDE_PROFILE_NAME"
CLAUDE_PROFILE_ARN=$(aws bedrock create-inference-profile \
  --inference-profile-name "$CLAUDE_PROFILE_NAME" \
  --description "ISB team ${TEAM_NAME} Claude Sonnet" \
  --model-source "{\"copyFrom\": \"$CLAUDE_SOURCE\"}" \
  --tags "key=Team,value=${TEAM_NAME}" "key=Namespace,value=${NAMESPACE}" "key=ManagedBy,value=ISB" \
  --region "$REGION" \
  --profile "$HUB_PROFILE" \
  --query "inferenceProfileArn" --output text 2>&1) || {
    # Check if already exists
    if echo "$CLAUDE_PROFILE_ARN" | grep -q "already exists"; then
      log "Claude profile already exists, fetching ARN..."
      CLAUDE_PROFILE_ARN=$(aws bedrock get-inference-profile \
        --inference-profile-identifier "$CLAUDE_PROFILE_NAME" \
        --region "$REGION" --profile "$HUB_PROFILE" \
        --query "inferenceProfileArn" --output text)
    else
      err "Failed to create Claude profile: $CLAUDE_PROFILE_ARN"
      exit 1
    fi
}
log "  ✓ Claude: $CLAUDE_PROFILE_ARN"

# ─── Create Nova Profile ───────────────────────────────────────────────────────

log "Creating Nova inference profile: $NOVA_PROFILE_NAME"
NOVA_PROFILE_ARN=$(aws bedrock create-inference-profile \
  --inference-profile-name "$NOVA_PROFILE_NAME" \
  --description "ISB team ${TEAM_NAME} Nova Pro" \
  --model-source "{\"copyFrom\": \"$NOVA_SOURCE\"}" \
  --tags "key=Team,value=${TEAM_NAME}" "key=Namespace,value=${NAMESPACE}" "key=ManagedBy,value=ISB" \
  --region "$REGION" \
  --profile "$HUB_PROFILE" \
  --query "inferenceProfileArn" --output text 2>&1) || {
    if echo "$NOVA_PROFILE_ARN" | grep -q "already exists"; then
      log "Nova profile already exists, fetching ARN..."
      NOVA_PROFILE_ARN=$(aws bedrock get-inference-profile \
        --inference-profile-identifier "$NOVA_PROFILE_NAME" \
        --region "$REGION" --profile "$HUB_PROFILE" \
        --query "inferenceProfileArn" --output text)
    else
      err "Failed to create Nova profile: $NOVA_PROFILE_ARN"
      exit 1
    fi
}
log "  ✓ Nova: $NOVA_PROFILE_ARN"

echo
log "Profiles created successfully."
log ""
log "Team '$TEAM_NAME' should use these model IDs:"
log "  Claude: $CLAUDE_PROFILE_ARN"
log "  Nova:   $NOVA_PROFILE_ARN"
log ""
log "To restrict this team's sandbox to only these profiles, run:"
log "  ./scripts/cost-controls/apply-team-profile-policy.sh $TEAM_NAME $ACCOUNT_ID"
