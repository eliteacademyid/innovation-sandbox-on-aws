#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy ISB Pool Auto-Scaler.
#
# Deployed DISABLED by default (DRY_RUN=true, threshold=0).
# To enable:
#   MIN_AVAILABLE_THRESHOLD=10 DRY_RUN=false ./scripts/cost-controls/deploy-pool-autoscaler.sh
#
# Usage:
#   ./scripts/cost-controls/deploy-pool-autoscaler.sh

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
STACK_NAME="isb-${NAMESPACE}-pool-autoscaler"
INFRA_DIR="$ROOT/infra/cost-controls/pool-autoscaler"

# Configurable
MIN_AVAILABLE_THRESHOLD="${MIN_AVAILABLE_THRESHOLD:-0}"  # 0 = disabled
MAX_PER_EXECUTION="${MAX_PER_EXECUTION:-5}"
MAX_POOL_SIZE="${MAX_POOL_SIZE:-150}"
DRY_RUN="${DRY_RUN:-true}"
ORG_ROLE_ARN="${ORG_ROLE_ARN:-arn:aws:iam::862099794180:role/isb-myisb-bedrock-org-scp-manager}"
ADMIN_TOPIC="arn:aws:sns:${REGION}:${HUB_ACCOUNT_ID}:isb-${NAMESPACE}-bedrock-admin-notifications"

# Get accounts table name
ACCOUNTS_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SandboxAccountTable'].OutputValue" --output text)

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

log "Stack:     $STACK_NAME"
log "Threshold: $MIN_AVAILABLE_THRESHOLD (0 = disabled)"
log "Max/exec:  $MAX_PER_EXECUTION"
log "Max pool:  $MAX_POOL_SIZE"
log "Dry run:   $DRY_RUN"
echo

# Package
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
ZIP="$TMPDIR/handler.zip"
(cd "$INFRA_DIR/autoscaler_handler" && zip -qj "$ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
S3_KEY="pool-autoscaler/${VERSION}/handler.zip"

aws s3 cp "$ZIP" "s3://${ARTIFACTS_BUCKET}/${S3_KEY}" --profile "$HUB_PROFILE"
log "Uploaded handler $VERSION"

# Deploy
log "Deploying CloudFormation stack"
aws cloudformation deploy \
  --template-file "$INFRA_DIR/stack.yaml" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --profile "$HUB_PROFILE" \
  --parameter-overrides \
    Namespace="$NAMESPACE" \
    AccountsTableName="$ACCOUNTS_TABLE" \
    MinAvailableThreshold="$MIN_AVAILABLE_THRESHOLD" \
    MaxPerExecution="$MAX_PER_EXECUTION" \
    MaxPoolSize="$MAX_POOL_SIZE" \
    OrgRoleArn="$ORG_ROLE_ARN" \
    NotificationTopicArn="$ADMIN_TOPIC" \
    AccountEmailDomain="${ACCOUNT_EMAIL_DOMAIN:-eliteacademy.id}" \
    AccountNamePrefix="${ACCOUNT_NAME_PREFIX:-isb-sandbox-}" \
    DryRun="$DRY_RUN" \
    AutoscalerHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    AutoscalerHandlerS3Key="$S3_KEY"

# Update code
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-pool-autoscaler" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$S3_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

log "Done. Lambda: isb-${NAMESPACE}-pool-autoscaler"
log ""
if [[ "$MIN_AVAILABLE_THRESHOLD" == "0" ]]; then
  log "⚠️  DISABLED — threshold is 0. To enable:"
  log "   MIN_AVAILABLE_THRESHOLD=10 DRY_RUN=false $0"
else
  log "✅ ENABLED — will create accounts when Available < $MIN_AVAILABLE_THRESHOLD"
  [[ "$DRY_RUN" == "true" ]] && log "⚠️  DRY RUN mode — won't actually create accounts"
fi
