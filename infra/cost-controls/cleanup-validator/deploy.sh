#!/bin/bash
# Deploy post-cleanup validation Lambda
# Detects stranded resources that Nuke missed by checking Cost Explorer
#
# Usage: ./deploy-cleanup-validator.sh
# Prerequisites: AWS CLI configured with hub account profile (eta-isb-andrian)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load env
if [ -f "$ROOT_DIR/.env" ]; then
  source "$ROOT_DIR/.env"
fi

STACK_NAME="isb-${NAMESPACE:-myisb}-cleanup-validator"
REGION="${AWS_REGION:-ap-southeast-1}"
FUNCTION_NAME="${STACK_NAME}-function"
ACCOUNT_TABLE="${ACCOUNT_TABLE:-InnovationSandbox-Data-SandboxAccountTableEFB9C069-16YC6RUKNE15K}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:ap-southeast-1:147826551593:isb-myisb-cleanup-failure-alarm}"
HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:-147826551593}"
MGMT_ACCOUNT_ID="${ORG_MGT_ACCOUNT_ID:-862099794180}"

echo "=== Deploying Post-Cleanup Validator ==="
echo "  Stack: $STACK_NAME"
echo "  Region: $REGION"
echo "  Function: $FUNCTION_NAME"
echo ""

# Package Lambda
LAMBDA_DIR="$SCRIPT_DIR"
ZIP_FILE="/tmp/${STACK_NAME}.zip"
cd "$LAMBDA_DIR"
zip -j "$ZIP_FILE" index.mjs
echo "✅ Lambda packaged"

# Upload to S3
BUCKET="isb-${NAMESPACE:-myisb}-artifacts-${HUB_ACCOUNT_ID}"
aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || true
aws s3 cp "$ZIP_FILE" "s3://$BUCKET/cleanup-validator/lambda.zip" --region "$REGION"
echo "✅ Lambda uploaded to S3"

# Deploy CloudFormation
cat > /tmp/cleanup-validator-template.yaml << 'TEMPLATE'
AWSTemplateFormatVersion: '2010-09-09'
Description: ISB Post-Cleanup Validation Lambda - detects stranded resources after Nuke

Parameters:
  FunctionName:
    Type: String
  AccountTable:
    Type: String
  SnsTopicArn:
    Type: String
  HubAccountId:
    Type: String
  MgmtAccountId:
    Type: String
  S3Bucket:
    Type: String
  S3Key:
    Type: String

Resources:
  LambdaRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${FunctionName}-role"
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: CleanupValidatorPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:Scan
                  - dynamodb:Query
                Resource: !Sub "arn:aws:dynamodb:*:${HubAccountId}:table/${AccountTable}"
              - Effect: Allow
                Action:
                  - ce:GetCostAndUsage
                Resource: "*"
              - Effect: Allow
                Action:
                  - sns:Publish
                Resource: !Ref SnsTopicArn
              - Effect: Allow
                Action:
                  - kms:Decrypt
                  - kms:GenerateDataKey
                Resource: "*"
                Condition:
                  StringEquals:
                    kms:ViaService: !Sub "dynamodb.${AWS::Region}.amazonaws.com"

  ValidatorFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Ref FunctionName
      Runtime: nodejs22.x
      Handler: index.handler
      Role: !GetAtt LambdaRole.Arn
      Timeout: 300
      MemorySize: 256
      Code:
        S3Bucket: !Ref S3Bucket
        S3Key: !Ref S3Key
      Environment:
        Variables:
          ACCOUNT_TABLE: !Ref AccountTable
          SNS_TOPIC_ARN: !Ref SnsTopicArn
          HUB_ACCOUNT_ID: !Ref HubAccountId
          MGMT_ACCOUNT_ID: !Ref MgmtAccountId

  DailySchedule:
    Type: AWS::Events::Rule
    Properties:
      Name: !Sub "${FunctionName}-daily"
      Description: "Run cleanup validator daily at 09:00 WIB (02:00 UTC)"
      ScheduleExpression: "cron(0 2 * * ? *)"
      State: ENABLED
      Targets:
        - Id: CleanupValidatorTarget
          Arn: !GetAtt ValidatorFunction.Arn

  SchedulePermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !GetAtt ValidatorFunction.Arn
      Action: lambda:InvokeFunction
      Principal: events.amazonaws.com
      SourceArn: !GetAtt DailySchedule.Arn

Outputs:
  FunctionArn:
    Value: !GetAtt ValidatorFunction.Arn
  FunctionName:
    Value: !Ref ValidatorFunction
  ScheduleRule:
    Value: !Ref DailySchedule
TEMPLATE

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file /tmp/cleanup-validator-template.yaml \
  --parameter-overrides \
    FunctionName="$FUNCTION_NAME" \
    AccountTable="$ACCOUNT_TABLE" \
    SnsTopicArn="$SNS_TOPIC_ARN" \
    HubAccountId="$HUB_ACCOUNT_ID" \
    MgmtAccountId="$MGMT_ACCOUNT_ID" \
    S3Bucket="$BUCKET" \
    S3Key="cleanup-validator/lambda.zip" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo ""
echo "✅ Post-Cleanup Validator deployed!"
echo ""
echo "  Function: $FUNCTION_NAME"
echo "  Schedule: Daily at 09:00 WIB (02:00 UTC)"
echo "  Alerts: $SNS_TOPIC_ARN"
echo ""
echo "To test manually:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --payload '{}' /tmp/validator-output.json --region $REGION --profile eta-isb-andrian && cat /tmp/validator-output.json"
