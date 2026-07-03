#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy ISB Slack Notifier — forwards admin SNS alerts to Slack webhook.
#
# Usage:
#   SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T.../B.../xxx" \
#     ./scripts/cost-controls/deploy-slack-notifier.sh
#
# Or set SLACK_WEBHOOK_URL in .env

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL must be set (Slack incoming webhook URL)}"

ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
STACK_NAME="isb-${NAMESPACE}-slack-notifier"
ADMIN_TOPIC_ARN="arn:aws:sns:${REGION}:${HUB_ACCOUNT_ID}:isb-${NAMESPACE}-bedrock-admin-notifications"
INFRA_DIR="$ROOT/infra/cost-controls/slack-notifier"

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

log "Region:    $REGION"
log "Stack:     $STACK_NAME"
log "Topic:     $ADMIN_TOPIC_ARN"
log "Channel:   ${SLACK_CHANNEL:-<webhook default>}"
echo

# Package
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
ZIP="$TMPDIR/notifier_handler.zip"
(cd "$INFRA_DIR/notifier_handler" && zip -qj "$ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
S3_KEY="slack-notifier/${VERSION}/notifier_handler.zip"

aws s3 cp "$ZIP" "s3://${ARTIFACTS_BUCKET}/${S3_KEY}" --profile "$HUB_PROFILE"
log "Uploaded notifier handler $VERSION"

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
    WebhookUrl="$SLACK_WEBHOOK_URL" \
    Channel="$SLACK_CHANNEL" \
    AdminTopicArn="$ADMIN_TOPIC_ARN" \
    NotifierHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    NotifierHandlerS3Key="$S3_KEY"

# Update code
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-slack-notifier" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$S3_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

log "Done. Slack notifier: isb-${NAMESPACE}-slack-notifier"
log "Subscribed to: $ADMIN_TOPIC_ARN"
log ""
log "Test with:"
log "  aws sns publish --topic-arn '$ADMIN_TOPIC_ARN' \\"
log "    --subject '[ISB] Test Alert' --message 'This is a test notification.' \\"
log "    --profile $HUB_PROFILE --region $REGION"
