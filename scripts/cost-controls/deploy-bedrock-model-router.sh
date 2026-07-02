#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy the ISB Bedrock Model Router (cost optimization layer).
#
# - Packages the router Lambda to S3 in the hub account
# - Deploys the stack.yaml to the hub account
#
# Usage:
#   ./scripts/cost-controls/deploy-bedrock-model-router.sh [--region ap-southeast-1]
#
# Requires:
#   - eta-isb-andrian profile (ISB hub account)
#   - .env loaded (NAMESPACE, HUB_ACCOUNT_ID)

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$ROOT/infra/cost-controls/bedrock-model-router"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"
STACK_NAME="isb-${NAMESPACE}-bedrock-model-router"

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

log "Region:    $REGION"
log "Namespace: $NAMESPACE"
log "Stack:     $STACK_NAME"
echo

# Package Lambda
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ROUTER_ZIP="$TMPDIR/router_handler.zip"
(cd "$INFRA_DIR/router_handler" && zip -qj "$ROUTER_ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
ROUTER_KEY="bedrock-model-router/${VERSION}/router_handler.zip"

aws s3 cp "$ROUTER_ZIP" "s3://${ARTIFACTS_BUCKET}/${ROUTER_KEY}" --profile "$HUB_PROFILE"
log "Uploaded router handler $VERSION"

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
    ClaudeRegions="${CLAUDE_REGIONS:-us-east-1,us-west-2,eu-west-1}" \
    NovaRegion="${NOVA_REGION:-us-east-1}" \
    CacheTtlHours="${CACHE_TTL_HOURS:-24}" \
    ComplexityThreshold="${COMPLEXITY_THRESHOLD:-500}" \
    RouterHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    RouterHandlerS3Key="$ROUTER_KEY"

# Update Lambda code
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-bedrock-model-router" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$ROUTER_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

log "Done. Router deployed at: isb-${NAMESPACE}-bedrock-model-router"
