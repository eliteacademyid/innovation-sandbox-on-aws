#!/bin/bash

# Setup Monitoring Script
# Creates CloudWatch alarms and dashboard for ISB

set -e

# Configuration
PROFILE="eta-isb"
REGION="ap-southeast-3"
HUB_ACCOUNT="147826551593"
SNS_TOPIC_NAME="ISB-Alerts"
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${HUB_ACCOUNT}:stateMachine:AccountCleanerStepFunctionStateMachineF32685E8-Fz5UGtEOpyyX"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  ISB Monitoring Setup                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Create SNS Topic for Alerts
echo -e "${BLUE}[1/3] Creating SNS Topic for Alerts...${NC}"

SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'TopicArn' \
  --output text 2>/dev/null || \
  aws sns list-topics \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query "Topics[?contains(TopicArn, '$SNS_TOPIC_NAME')].TopicArn" \
    --output text)

if [ -n "$SNS_TOPIC_ARN" ]; then
  echo -e "${GREEN}✅ SNS Topic: $SNS_TOPIC_ARN${NC}"
  
  # Subscribe email (optional)
  read -p "Enter email for alerts (or press Enter to skip): " EMAIL
  if [ -n "$EMAIL" ]; then
    aws sns subscribe \
      --topic-arn "$SNS_TOPIC_ARN" \
      --protocol email \
      --notification-endpoint "$EMAIL" \
      --profile "$PROFILE" \
      --region "$REGION" >/dev/null 2>&1
    
    echo -e "${YELLOW}⚠️  Check your email to confirm subscription${NC}"
  fi
else
  echo -e "${RED}❌ Failed to create SNS topic${NC}"
  exit 1
fi
echo ""

# Step 2: Create CloudWatch Alarms
echo -e "${BLUE}[2/3] Creating CloudWatch Alarms...${NC}"

# Alarm 1: Cleanup Failure Rate
echo -e "  Creating alarm: Cleanup Failure Rate..."
aws cloudwatch put-metric-alarm \
  --alarm-name "ISB-CleanupFailureRate" \
  --alarm-description "Alert when cleanup failure rate is high" \
  --metric-name "ExecutionsFailed" \
  --namespace "AWS/States" \
  --statistic "Sum" \
  --period 900 \
  --evaluation-periods 1 \
  --threshold 3 \
  --comparison-operator "GreaterThanThreshold" \
  --dimensions "Name=StateMachineArn,Value=$STATE_MACHINE_ARN" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --profile "$PROFILE" \
  --region "$REGION" 2>/dev/null && \
  echo -e "${GREEN}  ✅ Cleanup Failure Rate alarm created${NC}" || \
  echo -e "${YELLOW}  ⚠️  Alarm may already exist${NC}"

# Alarm 2: Lambda Errors
echo -e "  Creating alarm: Lambda Errors..."
aws cloudwatch put-metric-alarm \
  --alarm-name "ISB-LambdaErrors" \
  --alarm-description "Alert when Lambda functions have errors" \
  --metric-name "Errors" \
  --namespace "AWS/Lambda" \
  --statistic "Sum" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 10 \
  --comparison-operator "GreaterThanThreshold" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --profile "$PROFILE" \
  --region "$REGION" 2>/dev/null && \
  echo -e "${GREEN}  ✅ Lambda Errors alarm created${NC}" || \
  echo -e "${YELLOW}  ⚠️  Alarm may already exist${NC}"

# Alarm 3: API Gateway 5xx Errors
echo -e "  Creating alarm: API Gateway 5xx Errors..."
aws cloudwatch put-metric-alarm \
  --alarm-name "ISB-APIGateway5xxErrors" \
  --alarm-description "Alert when API Gateway has 5xx errors" \
  --metric-name "5XXError" \
  --namespace "AWS/ApiGateway" \
  --statistic "Sum" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator "GreaterThanThreshold" \
  --dimensions "Name=ApiName,Value=InnovationSandbox" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --profile "$PROFILE" \
  --region "$REGION" 2>/dev/null && \
  echo -e "${GREEN}  ✅ API Gateway 5xx Errors alarm created${NC}" || \
  echo -e "${YELLOW}  ⚠️  Alarm may already exist${NC}"

# Alarm 4: Step Functions Execution Time
echo -e "  Creating alarm: Long Running Cleanups..."
aws cloudwatch put-metric-alarm \
  --alarm-name "ISB-LongRunningCleanups" \
  --alarm-description "Alert when cleanups take too long" \
  --metric-name "ExecutionTime" \
  --namespace "AWS/States" \
  --statistic "Average" \
  --period 900 \
  --evaluation-periods 1 \
  --threshold 1800000 \
  --comparison-operator "GreaterThanThreshold" \
  --dimensions "Name=StateMachineArn,Value=$STATE_MACHINE_ARN" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --profile "$PROFILE" \
  --region "$REGION" 2>/dev/null && \
  echo -e "${GREEN}  ✅ Long Running Cleanups alarm created${NC}" || \
  echo -e "${YELLOW}  ⚠️  Alarm may already exist${NC}"

echo ""

# Step 3: Create CloudWatch Dashboard
echo -e "${BLUE}[3/3] Creating CloudWatch Dashboard...${NC}"

DASHBOARD_BODY=$(cat <<EOF
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "AWS/States", "ExecutionsSucceeded", { "stat": "Sum", "label": "Succeeded" } ],
          [ ".", "ExecutionsFailed", { "stat": "Sum", "label": "Failed" } ],
          [ ".", "ExecutionsStarted", { "stat": "Sum", "label": "Started" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "$REGION",
        "title": "Cleanup Executions",
        "period": 300,
        "yAxis": {
          "left": {
            "min": 0
          }
        }
      }
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "AWS/States", "ExecutionTime", { "stat": "Average" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "$REGION",
        "title": "Average Cleanup Duration",
        "period": 300,
        "yAxis": {
          "left": {
            "label": "Milliseconds",
            "min": 0
          }
        }
      }
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "AWS/Lambda", "Errors", { "stat": "Sum" } ],
          [ ".", "Throttles", { "stat": "Sum" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "$REGION",
        "title": "Lambda Errors & Throttles",
        "period": 300
      }
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "AWS/ApiGateway", "5XXError", { "stat": "Sum" } ],
          [ ".", "4XXError", { "stat": "Sum" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "$REGION",
        "title": "API Gateway Errors",
        "period": 300
      }
    },
    {
      "type": "log",
      "properties": {
        "query": "SOURCE 'InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL'\n| fields @timestamp, @message\n| filter @message like /ERROR/\n| sort @timestamp desc\n| limit 20",
        "region": "$REGION",
        "stacked": false,
        "title": "Recent Errors",
        "view": "table"
      }
    }
  ]
}
EOF
)

aws cloudwatch put-dashboard \
  --dashboard-name "ISB-Operations" \
  --dashboard-body "$DASHBOARD_BODY" \
  --profile "$PROFILE" \
  --region "$REGION" >/dev/null 2>&1 && \
  echo -e "${GREEN}✅ Dashboard created: ISB-Operations${NC}" || \
  echo -e "${YELLOW}⚠️  Dashboard may already exist${NC}"

echo ""

# Summary
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Monitoring Setup Complete            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✅ SNS Topic:${NC} $SNS_TOPIC_ARN"
echo -e "${GREEN}✅ Alarms Created:${NC}"
echo -e "   - ISB-CleanupFailureRate"
echo -e "   - ISB-LambdaErrors"
echo -e "   - ISB-APIGateway5xxErrors"
echo -e "   - ISB-LongRunningCleanups"
echo -e "${GREEN}✅ Dashboard:${NC} ISB-Operations"
echo ""
echo -e "${BLUE}📊 View Dashboard:${NC}"
echo -e "   https://console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=ISB-Operations"
echo ""
echo -e "${BLUE}🔔 View Alarms:${NC}"
echo -e "   https://console.aws.amazon.com/cloudwatch/home?region=$REGION#alarmsV2:"
echo ""
echo -e "${BLUE}💡 Next Steps:${NC}"
echo -e "   1. Confirm email subscription (check inbox)"
echo -e "   2. Review dashboard and alarms"
echo -e "   3. Test alerts (optional)"
echo ""

exit 0
