#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy the ISB Bedrock Daily Usage Report.
#
# Usage:
#   ./scripts/cost-controls/deploy-bedrock-usage-report.sh
#
# Requires:
#   - eta-isb-andrian profile (ISB hub account)
#   - .env loaded

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$ROOT/infra/cost-controls/bedrock-usage-report"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
STACK_NAME="isb-${NAMESPACE}-bedrock-usage-report"

# Get actual DynamoDB table names from Data stack outputs
ACCOUNTS_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SandboxAccountTable'].OutputValue" --output text)
LEASES_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LeaseTable'].OutputValue" --output text)
THROTTLE_TABLE="isb-${NAMESPACE}-bedrock-throttle-events"

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

log "Region:    $REGION"
log "Namespace: $NAMESPACE"
log "Stack:     $STACK_NAME"
log "Accounts:  $ACCOUNTS_TABLE"
log "Leases:    $LEASES_TABLE"
echo

# Package Lambda
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

REPORT_ZIP="$TMPDIR/report_handler.zip"
(cd "$INFRA_DIR/report_handler" && zip -qj "$REPORT_ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
REPORT_KEY="bedrock-usage-report/${VERSION}/report_handler.zip"

aws s3 cp "$REPORT_ZIP" "s3://${ARTIFACTS_BUCKET}/${REPORT_KEY}" --profile "$HUB_PROFILE"
log "Uploaded report handler $VERSION"

# Deploy stack
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
    LeasesTableName="$LEASES_TABLE" \
    ThrottleTableName="$THROTTLE_TABLE" \
    AdminEmail="${ADMIN_EMAIL:-andrian@eliteacademy.id}" \
    SesSourceEmail="${SES_SOURCE_EMAIL:-helpdesk@eliteacademy.id}" \
    SesRegion="${SES_REGION:-ap-southeast-1}" \
    MetricsRegions="${METRICS_REGIONS:-us-east-1,us-west-2,ap-southeast-1,ap-southeast-3}" \
    ReportHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    ReportHandlerS3Key="$REPORT_KEY"

# Update Lambda code (in case stack already existed)
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-bedrock-usage-report" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$REPORT_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

log "Done. Report Lambda: isb-${NAMESPACE}-bedrock-usage-report"
log "Schedule: daily at 08:00 WIB (01:00 UTC)"
log ""
log "To test manually:"
log "  aws lambda invoke --function-name isb-${NAMESPACE}-bedrock-usage-report \\"
log "    --profile $HUB_PROFILE --region $REGION /tmp/report-test.json"
