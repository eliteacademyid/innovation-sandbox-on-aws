#!/usr/bin/env bash
# ============================================================================
# Update Cost Report Groups in AWS AppConfig
# ============================================================================
# Updates the reporting configuration in AppConfig with the new cost report
# groups without requiring a full CDK redeployment.
#
# Usage: ./scripts/update-cost-report-groups.sh
# ============================================================================

set -euo pipefail

# Configuration
PROFILE="eta-isb-andrian"
REGION="ap-southeast-3"
NAMESPACE="myisb"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Update Cost Report Groups - AppConfig                          ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Profile: $PROFILE | Region: $REGION | Namespace: $NAMESPACE"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Find the AppConfig Application ID
echo "🔍 Finding AppConfig Application..."
APP_ID=$(aws appconfig list-applications \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Items[?contains(Description, '${NAMESPACE}')].Id" \
  --output text)

if [ -z "$APP_ID" ]; then
  echo "❌ Could not find AppConfig application for namespace: $NAMESPACE"
  exit 1
fi
echo "   Application ID: $APP_ID"

# Step 2: Find the Environment ID
echo "🔍 Finding AppConfig Environment..."
ENV_ID=$(aws appconfig list-environments \
  --application-id "$APP_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Items[0].Id" \
  --output text)

if [ -z "$ENV_ID" ]; then
  echo "❌ Could not find AppConfig environment"
  exit 1
fi
echo "   Environment ID: $ENV_ID"

# Step 3: Find the Reporting Config Profile ID
echo "🔍 Finding Reporting Config Profile..."
PROFILE_ID=$(aws appconfig list-configuration-profiles \
  --application-id "$APP_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Items[?contains(Name, 'ReportingConfig')].Id" \
  --output text)

if [ -z "$PROFILE_ID" ]; then
  echo "❌ Could not find ReportingConfig configuration profile"
  exit 1
fi
echo "   Profile ID: $PROFILE_ID"

# Step 4: Get the latest version number
echo "🔍 Getting latest configuration version..."
LATEST_VERSION=$(aws appconfig list-hosted-configuration-versions \
  --application-id "$APP_ID" \
  --configuration-profile-id "$PROFILE_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Items[-1].VersionNumber" \
  --output text)

echo "   Latest Version: $LATEST_VERSION"

# Step 5: Get the Deployment Strategy ID
echo "🔍 Finding Deployment Strategy..."
STRATEGY_ID=$(aws appconfig list-deployment-strategies \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Items[?contains(Description, '${NAMESPACE}')].Id" \
  --output text)

if [ -z "$STRATEGY_ID" ]; then
  echo "⚠️  Could not find custom deployment strategy, using AppConfig.AllAtOnce"
  STRATEGY_ID="AppConfig.AllAtOnce"
fi
echo "   Strategy ID: $STRATEGY_ID"

# Step 6: Create new configuration version with updated cost report groups
echo ""
echo "📝 New Cost Report Groups Configuration:"
echo "   - cendekiawan"
echo "   - cendekiawan-apu"
echo "   - cendekiawan-apu-tot"
echo "   - cendekiawan-apu-finalist"
echo "   - cendekiawan-mmu"
echo "   - cendekiawan-mmu-coaches"
echo "   - cendekiawan-mmu-finalist"
echo ""

# Create the YAML content
CONFIG_CONTENT=$(cat <<'YAML'
costReportGroups:
  - cendekiawan
  - cendekiawan-apu
  - cendekiawan-apu-tot
  - cendekiawan-apu-finalist
  - cendekiawan-mmu
  - cendekiawan-mmu-coaches
  - cendekiawan-mmu-finalist
requireCostReportGroup: false
YAML
)

echo "📤 Creating new hosted configuration version..."
# Write config to temp file for proper blob upload
TEMP_CONFIG=$(mktemp)
echo "$CONFIG_CONTENT" > "$TEMP_CONFIG"

NEW_VERSION=$(aws appconfig create-hosted-configuration-version \
  --application-id "$APP_ID" \
  --configuration-profile-id "$PROFILE_ID" \
  --content-type "application/x-yaml" \
  --content "fileb://$TEMP_CONFIG" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "VersionNumber" \
  --output text \
  /dev/null)

rm -f "$TEMP_CONFIG"

echo "   ✅ Created version: $NEW_VERSION"

# Step 7: Deploy the new configuration
echo "🚀 Deploying new configuration..."
aws appconfig start-deployment \
  --application-id "$APP_ID" \
  --environment-id "$ENV_ID" \
  --configuration-profile-id "$PROFILE_ID" \
  --configuration-version "$NEW_VERSION" \
  --deployment-strategy-id "$STRATEGY_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --output table

echo ""
echo "✅ Cost report groups updated successfully!"
echo ""
echo "The new groups are now available in the Innovation Sandbox UI."
echo "Users can select these groups when creating lease templates."
