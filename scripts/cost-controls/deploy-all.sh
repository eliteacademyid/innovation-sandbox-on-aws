#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Master deploy script for ALL ISB cost-controls custom extensions.
#
# Deploys (in order):
#   1. Bedrock Rate Limiter (hub stack + StackSet)
#   2. Bedrock Model Router (+ API Gateway)
#   3. Daily Bedrock Usage Report
#   4. Weekly Pool Health Report
#   5. Subscribe member SNS topics
#
# Usage:
#   ./scripts/cost-controls/deploy-all.sh [--skip-stackset]
#
# Prerequisites:
#   - AWS profiles: eta-isb-andrian (hub), eta-andrian (mgmt)
#   - .env loaded
#   - SES sender verified in hub account
#   - Org SCP manager role exists in management account

set -euo pipefail

SKIP_STACKSET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-stackset) SKIP_STACKSET=true; shift;;
    *) echo "Unknown: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; source "$ROOT/.env"; set +a; }

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"

log() { printf "\n\033[1;35m━━━ %s ━━━\033[0m\n\n" "$*"; }

echo "╔══════════════════════════════════════════════════════╗"
echo "║   ISB Cost Controls — Full Deployment               ║"
echo "║   Region: $REGION                           ║"
echo "║   Namespace: $NAMESPACE                              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo

# ─── 1. Bedrock Rate Limiter ──────────────────────────────────────────────────
log "1/5 — Bedrock Rate Limiter (Hub Stack)"
"$ROOT/scripts/cost-controls/deploy-bedrock-rate-limit.sh"

# ─── 2. Bedrock Model Router ─────────────────────────────────────────────────
log "2/5 — Bedrock Model Router"
"$ROOT/scripts/cost-controls/deploy-bedrock-model-router.sh"

# ─── 3. Daily Usage Report ────────────────────────────────────────────────────
log "3/5 — Daily Bedrock Usage Report"
"$ROOT/scripts/cost-controls/deploy-bedrock-usage-report.sh"

# ─── 4. Weekly Health Report ──────────────────────────────────────────────────
log "4/5 — Weekly Pool Health Report"

ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
INFRA_DIR="$ROOT/infra/cost-controls/weekly-health-report"

# Get table names
ACCOUNTS_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SandboxAccountTable'].OutputValue" --output text)
LEASES_TABLE=$(aws cloudformation describe-stacks --stack-name InnovationSandbox-Data \
  --profile "$HUB_PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LeaseTable'].OutputValue" --output text)

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
ZIP="$TMPDIR/report_handler.zip"
(cd "$INFRA_DIR/report_handler" && zip -qj "$ZIP" handler.py)
VERSION="$(date -u +%Y%m%d-%H%M%S)"
S3_KEY="weekly-health-report/${VERSION}/report_handler.zip"

aws s3 cp "$ZIP" "s3://${ARTIFACTS_BUCKET}/${S3_KEY}" --profile "$HUB_PROFILE"

aws cloudformation deploy \
  --template-file "$INFRA_DIR/stack.yaml" \
  --stack-name "isb-${NAMESPACE}-weekly-health-report" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" --profile "$HUB_PROFILE" \
  --parameter-overrides \
    Namespace="$NAMESPACE" \
    AccountsTableName="$ACCOUNTS_TABLE" \
    LeasesTableName="$LEASES_TABLE" \
    ThrottleTableName="isb-${NAMESPACE}-bedrock-throttle-events" \
    CodeBuildProject="AccountCleanerCodeBuildClea-FJkuoq69GCNf" \
    AdminEmail="${ADMIN_EMAIL:-andrian@eliteacademy.id}" \
    SesSourceEmail="${SES_SOURCE_EMAIL:-andrian@eliteacademy.id}" \
    SesRegion="${SES_REGION:-ap-southeast-1}" \
    ReportHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    ReportHandlerS3Key="$S3_KEY"

aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-weekly-health-report" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$S3_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

# ─── 5. Subscribe Member Topics ──────────────────────────────────────────────
log "5/5 — Subscribe Member SNS Topics"
"$ROOT/scripts/cost-controls/subscribe-member-topics.sh"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ All cost-controls stacks deployed              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
echo "Stacks deployed:"
echo "  • isb-${NAMESPACE}-bedrock-rate-limit        (hub)"
echo "  • isb-${NAMESPACE}-bedrock-model-router      (hub + API GW)"
echo "  • isb-${NAMESPACE}-bedrock-usage-report      (daily 08:00 WIB)"
echo "  • isb-${NAMESPACE}-weekly-health-report      (Monday 09:00 WIB)"
echo "  • SNS subscriptions                          (100 accounts)"
echo
echo "CloudWatch Dashboard:"
echo "  https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards/dashboard/ISB-Operations-myisb"
