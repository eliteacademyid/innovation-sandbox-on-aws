#!/usr/bin/env bash
# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy the ISB Bedrock Rate Limiter (B-prime).
#
# - Packages and uploads the throttle/recovery Lambdas to S3 in the hub account
# - Deploys the hub-stack.yaml to the hub account
# - Creates/updates the StackSet that deploys member-stack.yaml to ISB OUs
# - Subscribes the throttle Lambda to each member SNS topic
#
# Usage:
#   ./scripts/cost-controls/deploy-bedrock-rate-limit.sh [--region ap-southeast-1]
#
# Requires:
#   - eta-andrian profile (org management account)
#   - eta-isb-andrian profile (ISB hub account)
#   - .env loaded (NAMESPACE, HUB_ACCOUNT_ID, ORG_MGT_ACCOUNT_ID, PARENT_OU_ID)

set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-myisb}"
HUB_PROFILE="${HUB_PROFILE:-eta-isb-andrian}"
MGT_PROFILE="${MGT_PROFILE:-eta-andrian}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$ROOT/infra/cost-controls/bedrock-rate-limit"

# Load .env if present
if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:?HUB_ACCOUNT_ID must be set}"
ORG_MGT_ACCOUNT_ID="${ORG_MGT_ACCOUNT_ID:?ORG_MGT_ACCOUNT_ID must be set}"

# IMPORTANT: ISB_ACCOUNT_POOL_OU_ID is the OU named '<namespace>_InnovationSandboxAccountPool',
# NOT the org root. .env's PARENT_OU_ID may be set to the root for the AccountPool stack;
# we must NOT use that here or the StackSet will hit every OU in the org.
if [[ -z "${ISB_ACCOUNT_POOL_OU_ID:-}" ]]; then
  ISB_ACCOUNT_POOL_OU_ID=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$(aws organizations list-roots --profile "$MGT_PROFILE" --query 'Roots[0].Id' --output text)" \
    --profile "$MGT_PROFILE" \
    --query "OrganizationalUnits[?Name=='${NAMESPACE}_InnovationSandboxAccountPool'].Id | [0]" \
    --output text)
  if [[ -z "$ISB_ACCOUNT_POOL_OU_ID" || "$ISB_ACCOUNT_POOL_OU_ID" == "None" ]]; then
    echo "ERROR: could not resolve ${NAMESPACE}_InnovationSandboxAccountPool OU. Set ISB_ACCOUNT_POOL_OU_ID explicitly." >&2
    exit 1
  fi
fi

STACKSET_NAME="isb-${NAMESPACE}-bedrock-rate-limit-member"
HUB_STACK_NAME="isb-${NAMESPACE}-bedrock-rate-limit-hub"
ARTIFACTS_BUCKET="isb-${NAMESPACE}-bedrock-rl-artifacts-${HUB_ACCOUNT_ID}"

log()  { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

log "Region:           $REGION"
log "Namespace:        $NAMESPACE"
log "Hub account:      $HUB_ACCOUNT_ID"
log "Mgmt account:     $ORG_MGT_ACCOUNT_ID"
log "ISB pool OU:      $ISB_ACCOUNT_POOL_OU_ID"
log "Artifacts bucket: $ARTIFACTS_BUCKET"
echo
read -rp "Proceed? (yes/no): " ans
[[ "$ans" == "yes" ]] || { log "aborted"; exit 0; }

# -----------------------------------------------------------------------------
# 1. Ensure artifacts bucket exists in hub account
# -----------------------------------------------------------------------------
log "Step 1/5: Ensuring artifacts bucket"
if ! aws s3api head-bucket --bucket "$ARTIFACTS_BUCKET" --profile "$HUB_PROFILE" --region "$REGION" 2>/dev/null; then
  log "Creating bucket $ARTIFACTS_BUCKET in $REGION"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$ARTIFACTS_BUCKET" --profile "$HUB_PROFILE"
  else
    aws s3api create-bucket --bucket "$ARTIFACTS_BUCKET" --profile "$HUB_PROFILE" \
      --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$ARTIFACTS_BUCKET" \
    --versioning-configuration Status=Enabled --profile "$HUB_PROFILE"
fi

# -----------------------------------------------------------------------------
# 2. Package Lambdas and upload to S3
# -----------------------------------------------------------------------------
log "Step 2/5: Packaging Lambdas"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

THROTTLE_ZIP="$TMPDIR/throttle_handler.zip"
RECOVERY_ZIP="$TMPDIR/recovery_handler.zip"

(cd "$INFRA_DIR/throttle_handler" && zip -qj "$THROTTLE_ZIP" handler.py)
(cd "$INFRA_DIR/recovery_handler" && zip -qj "$RECOVERY_ZIP" handler.py)

VERSION="$(date -u +%Y%m%d-%H%M%S)"
THROTTLE_KEY="bedrock-rate-limit/${VERSION}/throttle_handler.zip"
RECOVERY_KEY="bedrock-rate-limit/${VERSION}/recovery_handler.zip"

aws s3 cp "$THROTTLE_ZIP" "s3://${ARTIFACTS_BUCKET}/${THROTTLE_KEY}" --profile "$HUB_PROFILE"
aws s3 cp "$RECOVERY_ZIP" "s3://${ARTIFACTS_BUCKET}/${RECOVERY_KEY}" --profile "$HUB_PROFILE"
log "Uploaded artifacts version $VERSION"

# -----------------------------------------------------------------------------
# 3. Deploy hub-stack
# -----------------------------------------------------------------------------
log "Step 3/5: Deploying hub stack ($HUB_STACK_NAME)"
aws cloudformation deploy \
  --template-file "$INFRA_DIR/hub-stack.yaml" \
  --stack-name "$HUB_STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --profile "$HUB_PROFILE" \
  --parameter-overrides \
    Namespace="$NAMESPACE" \
    AdminEmail="${ADMIN_EMAIL:-andrian@eliteacademy.id}" \
    ThrottleHandlerS3Bucket="$ARTIFACTS_BUCKET" \
    ThrottleHandlerS3Key="$THROTTLE_KEY" \
    RecoveryHandlerS3Key="$RECOVERY_KEY" \
    ThrottleDurationSeconds="${THROTTLE_DURATION_SECONDS:-3600}"

# Force update of Lambda code (CFN won't redeploy if only S3Key version changes via env)
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-bedrock-throttle-handler" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$THROTTLE_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null
aws lambda update-function-code \
  --function-name "isb-${NAMESPACE}-bedrock-recovery-handler" \
  --s3-bucket "$ARTIFACTS_BUCKET" --s3-key "$RECOVERY_KEY" \
  --region "$REGION" --profile "$HUB_PROFILE" >/dev/null

# -----------------------------------------------------------------------------
# 4. Create/update StackSet (in management account, deploys to ISB OUs)
# -----------------------------------------------------------------------------
log "Step 4/5: Deploying member StackSet ($STACKSET_NAME)"

if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" \
     --call-as DELEGATED_ADMIN --region "$REGION" --profile "$MGT_PROFILE" >/dev/null 2>&1 \
   || aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" \
     --region "$REGION" --profile "$MGT_PROFILE" >/dev/null 2>&1; then
  log "StackSet exists — updating template"
  aws cloudformation update-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$INFRA_DIR/member-stack.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --parameters \
        ParameterKey=HubAccountId,ParameterValue="$HUB_ACCOUNT_ID" \
        ParameterKey=Namespace,ParameterValue="$NAMESPACE" \
        ParameterKey=TpmThreshold,ParameterValue="${TPM_THRESHOLD:-100000}" \
        ParameterKey=RpmThreshold,ParameterValue="${RPM_THRESHOLD:-60}" \
        ParameterKey=RpmEvaluationPeriods,ParameterValue="${RPM_EVAL_PERIODS:-2}" \
    --operation-preferences RegionConcurrencyType=PARALLEL,FailureToleranceCount=5,MaxConcurrentCount=10 \
    --region "$REGION" --profile "$MGT_PROFILE" >/dev/null
else
  log "Creating StackSet"
  aws cloudformation create-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --description "ISB Bedrock rate limiter — per-account alarms + SNS + cross-account role" \
    --template-body "file://$INFRA_DIR/member-stack.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --parameters \
        ParameterKey=HubAccountId,ParameterValue="$HUB_ACCOUNT_ID" \
        ParameterKey=Namespace,ParameterValue="$NAMESPACE" \
        ParameterKey=TpmThreshold,ParameterValue="${TPM_THRESHOLD:-100000}" \
        ParameterKey=RpmThreshold,ParameterValue="${RPM_THRESHOLD:-60}" \
        ParameterKey=RpmEvaluationPeriods,ParameterValue="${RPM_EVAL_PERIODS:-2}" \
    --region "$REGION" --profile "$MGT_PROFILE" >/dev/null
fi

# Get list of ISB OUs to target (children of ISB_ACCOUNT_POOL_OU_ID)
log "Resolving ISB child OUs under $ISB_ACCOUNT_POOL_OU_ID"
TARGET_OUS=$(aws organizations list-children \
  --parent-id "$ISB_ACCOUNT_POOL_OU_ID" \
  --child-type ORGANIZATIONAL_UNIT \
  --profile "$MGT_PROFILE" \
  --query 'Children[].Id' --output text)
log "Target OUs: $TARGET_OUS"

# Create/update stack instances for these OUs
log "Creating/updating stack instances in target OUs ($REGION)"
TARGETS_JSON="{\"OrganizationalUnitIds\":[$(echo "$TARGET_OUS" | awk '{for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i==NF?"":",")}')]}"

aws cloudformation create-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --deployment-targets "$TARGETS_JSON" \
  --regions "$REGION" \
  --operation-preferences RegionConcurrencyType=PARALLEL,FailureToleranceCount=5,MaxConcurrentCount=10 \
  --region "$REGION" --profile "$MGT_PROFILE" >/dev/null 2>&1 \
  || log "(stack instances may already exist — fine)"

# -----------------------------------------------------------------------------
# 5. Subscribe throttle Lambda to each member SNS topic
# -----------------------------------------------------------------------------
log "Step 5/5: Subscribing throttle Lambda to member SNS topics"
"$ROOT/scripts/cost-controls/subscribe-member-topics.sh" \
  --region "$REGION" --namespace "$NAMESPACE"

log "Done. Run './scripts/cost-controls/list-throttled-accounts.sh' to verify hub state."
