// Post-Cleanup Validation Lambda
// Checks Cost Explorer 24h after account cleanup to detect stranded resources
// that Nuke missed (e.g., ap-southeast-5, Bedrock custom models, WAF Global)
//
// Trigger: EventBridge scheduled (daily) or on-demand
// Action: Queries Cost Explorer for sandbox accounts in "Available" status
//         that still have non-baseline charges. Alerts via SNS if found.

import { DynamoDBClient, ScanCommand } from "@aws-sdk/client-dynamodb";
import {
  CostExplorerClient,
  GetCostAndUsageCommand,
} from "@aws-sdk/client-cost-explorer";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const REGION = process.env.AWS_REGION || "ap-southeast-1";
const ACCOUNT_TABLE = process.env.ACCOUNT_TABLE;
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;
const HUB_ACCOUNT_ID = process.env.HUB_ACCOUNT_ID;
const MGMT_ACCOUNT_ID = process.env.MGMT_ACCOUNT_ID;

// Baseline cost threshold per account per day (CloudWatch alarms from rate-limiter StackSet)
// Anything above this indicates stranded resources
const BASELINE_DAILY_THRESHOLD = 0.02; // $0.02/day = only CW alarm cost
const ALERT_DAILY_THRESHOLD = 0.05; // Alert if daily cost > $0.05 (clearly not just CW)

const dynamodb = new DynamoDBClient({ region: REGION });
const costExplorer = new CostExplorerClient({ region: "us-east-1" }); // CE is always us-east-1
const sns = new SNSClient({ region: REGION });

export const handler = async (event) => {
  console.log("Starting post-cleanup validation...");

  // 1. Get all accounts in "Available" status
  const availableAccounts = await getAvailableAccounts();
  console.log(`Found ${availableAccounts.length} accounts in Available status`);

  if (availableAccounts.length === 0) {
    return { statusCode: 200, body: "No available accounts to check" };
  }

  // 2. Query Cost Explorer for the last 2 days
  const today = new Date();
  const twoDaysAgo = new Date(today);
  twoDaysAgo.setDate(twoDaysAgo.getDate() - 2);
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);

  const startDate = twoDaysAgo.toISOString().split("T")[0];
  const endDate = today.toISOString().split("T")[0];

  // 3. Check costs for each available account
  const leakingAccounts = [];

  // Process in batches of 20 (CE filter limit)
  for (let i = 0; i < availableAccounts.length; i += 20) {
    const batch = availableAccounts.slice(i, i + 20);
    const accountIds = batch.map((a) => a.awsAccountId);

    const costs = await getCostsForAccounts(accountIds, startDate, endDate);

    for (const [accountId, dailyCost] of Object.entries(costs)) {
      if (dailyCost > ALERT_DAILY_THRESHOLD) {
        const account = batch.find((a) => a.awsAccountId === accountId);
        leakingAccounts.push({
          accountId,
          name: account?.name || "Unknown",
          dailyCost: dailyCost.toFixed(4),
          monthlyCost: (dailyCost * 30).toFixed(2),
        });
      }
    }
  }

  // 4. Alert if leaking accounts found
  if (leakingAccounts.length > 0) {
    console.log(
      `⚠️ Found ${leakingAccounts.length} accounts with stranded resources`
    );
    await sendAlert(leakingAccounts);
    return {
      statusCode: 200,
      body: {
        status: "ALERT",
        leakingAccounts,
        message: `${leakingAccounts.length} account(s) have resources that survived cleanup`,
      },
    };
  }

  console.log("✅ All available accounts are clean (no unexpected costs)");
  return {
    statusCode: 200,
    body: {
      status: "OK",
      accountsChecked: availableAccounts.length,
      message: "All available accounts are clean",
    },
  };
};

async function getAvailableAccounts() {
  const accounts = [];
  let lastEvaluatedKey;

  do {
    const params = {
      TableName: ACCOUNT_TABLE,
      FilterExpression: "#s = :available",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: { ":available": { S: "Available" } },
      ProjectionExpression: "awsAccountId, #s, #n",
      ExclusiveStartKey: lastEvaluatedKey,
    };
    // name is reserved word
    params.ExpressionAttributeNames["#n"] = "name";

    const result = await dynamodb.send(new ScanCommand(params));
    for (const item of result.Items || []) {
      accounts.push({
        awsAccountId: item.awsAccountId?.S,
        name: item.name?.S,
      });
    }
    lastEvaluatedKey = result.LastEvaluatedKey;
  } while (lastEvaluatedKey);

  return accounts;
}

async function getCostsForAccounts(accountIds, startDate, endDate) {
  const params = {
    TimePeriod: { Start: startDate, End: endDate },
    Granularity: "DAILY",
    Metrics: ["UnblendedCost"],
    GroupBy: [{ Type: "DIMENSION", Key: "LINKED_ACCOUNT" }],
    Filter: {
      And: [
        {
          Dimensions: {
            Key: "LINKED_ACCOUNT",
            Values: accountIds,
          },
        },
        {
          Not: {
            Dimensions: {
              Key: "RECORD_TYPE",
              Values: ["Credit", "Refund"],
            },
          },
        },
      ],
    },
  };

  const result = await costExplorer.send(
    new GetCostAndUsageCommand(params)
  );

  // Calculate average daily cost per account
  const costs = {};
  const days = result.ResultsByTime?.length || 1;

  for (const period of result.ResultsByTime || []) {
    for (const group of period.Groups || []) {
      const accountId = group.Keys[0];
      const cost = parseFloat(
        group.Metrics?.UnblendedCost?.Amount || "0"
      );
      costs[accountId] = (costs[accountId] || 0) + cost;
    }
  }

  // Average per day
  for (const accountId of Object.keys(costs)) {
    costs[accountId] = costs[accountId] / days;
  }

  return costs;
}

async function sendAlert(leakingAccounts) {
  const totalDaily = leakingAccounts.reduce(
    (sum, a) => sum + parseFloat(a.dailyCost),
    0
  );
  const totalMonthly = totalDaily * 30;

  let message = `🚨 ISB Post-Cleanup Validation Alert\n\n`;
  message += `Found ${leakingAccounts.length} account(s) in "Available" status with unexpected charges:\n\n`;

  for (const account of leakingAccounts) {
    message += `• ${account.name} (${account.accountId})\n`;
    message += `  Daily: $${account.dailyCost} | Monthly projection: $${account.monthlyCost}\n\n`;
  }

  message += `\nTotal daily leak: $${totalDaily.toFixed(2)}/day ($${totalMonthly.toFixed(2)}/mo)\n\n`;
  message += `Action required: Investigate and manually clean stranded resources.\n`;
  message += `Common causes:\n`;
  message += `  - ap-southeast-5 resources (Nuke doesn't support this region)\n`;
  message += `  - Bedrock custom model imports\n`;
  message += `  - WAF Global-scope WebACLs\n`;
  message += `  - Resources created after last Nuke run\n`;

  const params = {
    TopicArn: SNS_TOPIC_ARN,
    Subject: `[ISB] ⚠️ ${leakingAccounts.length} account(s) have stranded resources ($${totalDaily.toFixed(2)}/day)`,
    Message: message,
  };

  await sns.send(new PublishCommand(params));
  console.log("Alert sent to SNS");
}
