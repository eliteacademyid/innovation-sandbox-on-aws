#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy ISB Discord Notifier — forwards admin SNS alerts to Discord webhook.
#
# Usage:
#   DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/1234.../abcXYZ" \
#     ./scripts/cost-controls/deploy-discord-notifier.sh
#
# Or set DISCORD_WEBHOOK_URL in .env

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
DISCORD_CHANNEL="${DISCORD_CHANNEL:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
# SLACK_WEBHOOK_URL kept as a legacy fallback for anyone still setting it from
# before the Slack→Discord refactor (commit f4432a4).
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-${SLACK_WEBHOOK_URL:-}}"
if [[ -z "$WEBHOOK_URL" ]]; then
  echo "Error: DISCORD_WEBHOOK_URL must be set (Discord webhook URL)" >&2
  echo "Get it from: Server Settings → Integrations → Webhooks → Copy URL" >&2
  exit 1
fi

ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
STACK_NAME="isb-${NAMESPACE}-discord-notifier"
ADMIN_TOPIC_ARN="arn:aws:sns:${REGION}:${HUB_ACCOUNT_ID}:isb-${NAMESPACE}-bedrock-admin-notifications"
INFRA_DIR="$ROOT/infra/cost-controls/discord-notifier"

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

log "Region:    $REGION"
log "Stack:     $STACK_NAME"
log "Topic:     $ADMIN_TOPIC_ARN"
log "Channel:   ${DISCORD_CHANNEL:-<webhook default>}"
echo

# Package
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
ZIP="$TMPDIR/notifier_handler.zip"
(cd "$INFRA_DIR/notifier_handler" && zip -qj "$ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
S3_KEY="discord-notifier/${VERSION}/notifier_handler.zip"

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
    WebhookUrl="$WEBHOOK_URL" \
    Channel="$DISCORD_CHANNEL" \
    AdminTopicArn="$ADMIN_TOPIC_ARN" \
    NotifierHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    NotifierHandlerS3Key="$S3_KEY"

# Update code
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-discord-notifier" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$S3_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

log "Done. Discord notifier: isb-${NAMESPACE}-discord-notifier"
log "Subscribed to: $ADMIN_TOPIC_ARN"
log ""
log "Test with:"
log "  aws sns publish --topic-arn '$ADMIN_TOPIC_ARN' \\"
log "    --subject '[ISB] Test Alert' --message 'This is a test notification.' \\"
log "    --profile $HUB_PROFILE --region $REGION"
