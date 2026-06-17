#!/bin/bash
# ISB Bedrock Rate Limiter Smoke Test
# Sends >60 requests/min to trigger RPM alarm
# Usage: ./smoke-test-bedrock.sh <sandbox-profile>
# Example: ./smoke-test-bedrock.sh eta-sandbox-30

PROFILE="${1:-eta-sandbox-30}"
REGION="ap-southeast-1"
MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"

echo "=== ISB Bedrock Rate Limiter Smoke Test ==="
echo "Profile: $PROFILE"
echo "Region: $REGION"
echo "Model: $MODEL_ID (cheapest, ~$0.01 total for test)"
echo "Target: >60 requests in 1 minute to trigger RPM alarm"
echo ""
read -p "Press Enter to start (Ctrl+C to cancel)..."

START=$(date +%s)
COUNT=0

for i in $(seq 1 70); do
  aws bedrock-runtime invoke-model \
    --model-id $MODEL_ID \
    --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' \
    --content-type application/json \
    --accept application/json \
    --profile $PROFILE \
    --region $REGION \
    /dev/null 2>/dev/null &
  
  COUNT=$((COUNT + 1))
  
  # Print progress every 10
  if [ $((COUNT % 10)) -eq 0 ]; then
    ELAPSED=$(($(date +%s) - START))
    echo "  Sent $COUNT requests in ${ELAPSED}s ($(echo "scale=1; $COUNT * 60 / ($ELAPSED + 1)" | bc) RPM)"
  fi
done

# Wait for all background requests
wait

ELAPSED=$(($(date +%s) - START))
echo ""
echo "=== Done: $COUNT requests in ${ELAPSED}s ==="
echo "RPM: $(echo "scale=1; $COUNT * 60 / $ELAPSED" | bc)"
echo ""
echo "Now wait ~2 minutes for the alarm to fire..."
echo "Check with: ./scripts/cost-controls/list-throttled-accounts.sh"
echo "Or check DynamoDB: aws dynamodb scan --table-name isb-myisb-bedrock-throttle-events --profile eta-isb-andrian --region ap-southeast-1"
