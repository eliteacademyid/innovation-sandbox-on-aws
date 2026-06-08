# Bedrock RPM/TPM Rate Limiting Plan

**Status:** Draft — pending implementation
**Author:** Andrian Maulana
**Date:** 2026-06-08
**Related Incident:** [2026-05-22 Anonymous budget overrun](../incidents/2026-05-22-anonymous-budget-overrun.md) ($1,316 in one day)

---

## 1. Problem Statement

A single sandbox account ran a runaway script and spent **$1,102 on Bedrock in 24 hours** before our Cost Explorer-based monitoring could detect and freeze it. We need to **rate limit Bedrock invocations per account** so a single bad script cannot blow past the $50 lease budget.

Specifically we want to enforce, per sandbox account:

| Metric | Target |
|---|---|
| **RPM** (requests per minute) | ~30–60 req/min |
| **TPM** (tokens per minute, in + out) | ~50K–100K tokens/min |
| **Daily token budget** | ~5M tokens/day (≈ $1.50 Haiku, $15 Sonnet) |
| **Daily cost cap (real-time)** | ~$10 hard ceiling |

---

## 2. What Won't Work

| Approach | Why not |
|---|---|
| AWS Service Quotas (decrease RPM/TPM) | Quotas can only be **increased**, not decreased below default. |
| Bedrock Guardrails | Content/topic filtering only — no RPM/TPM enforcement. |
| API Gateway proxy with usage plans | Forces teams to rewrite SDK code to call our proxy. Not viable mid-competition. |
| Application Inference Profiles alone | Adds tagging/grouping, but doesn't enforce rate limits by itself. |

---

## 3. Recommended Architecture — Layered Defense

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Preventive SCP (already deployed)                      │
│  - Deny Opus models                                              │
│  - Allow Haiku, Sonnet, Llama, Titan, Mistral, Cohere            │
└──────────────────────────────────────────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: CloudWatch Alarm per sandbox account                   │
│  - InputTokenCount + OutputTokenCount, 1-min sum                 │
│  - Threshold: > 100,000 tokens/min for 2 datapoints              │
│  - Threshold: > 60 invocations/min for 2 datapoints              │
└──────────────────────────────────────────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: SNS → Lambda auto-throttle                             │
│  - Lambda assumes role into member account                       │
│  - Attaches DenyBedrock inline policy to IsbUsersPS              │
│  - Sends notification email + Slack to admin                     │
└──────────────────────────────────────────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: AWS Budget Action — daily $10 hard cap                 │
│  - Per-account budget on Bedrock service                         │
│  - At 100% → applies DenyBedrock managed policy                  │
│  - At 80% → SNS warning to team leader                           │
└──────────────────────────────────────────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: Daily token-usage report                               │
│  - EventBridge schedule (daily 00:05 UTC)                        │
│  - Lambda queries CloudWatch metrics across all accounts         │
│  - Emails admin a CSV of yesterday's Bedrock usage by account    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 4. Implementation Phases

### Phase 1 — Quick win (deploy this week)

**Goal:** Real-time per-account rate limiter using CloudWatch + Lambda.

**Components:**
1. **StackSet** that deploys to every active sandbox account:
   - 2 CloudWatch alarms on `AWS/Bedrock` namespace:
     - `BedrockTPM` — sum of `InputTokenCount` + `OutputTokenCount` > 100K for 1 datapoint of 1 minute
     - `BedrockRPM` — `Invocations` > 60 for 2 consecutive 1-minute datapoints
   - SNS topic `bedrock-throttle-trigger` in member account
   - IAM role allowing the central Lambda to assume in
2. **Central Lambda** in management or hub account:
   - Subscribed to all member SNS topics (or via EventBridge cross-account bus)
   - On alarm → assume role → `iam:PutUserPolicy` on `IsbUsersPS` permission set with deny-bedrock inline policy
   - Logs to DynamoDB `BedrockThrottleEvents` table for audit
   - Sends email via SES to `helpdesk@eliteacademy.id` and team leader
3. **Manual unfreeze script** for admin to remove the deny policy after investigating.

**Cost:** ~$0.50/account/month (alarms + Lambda invocations).

**Deliverables:**
- `lib/cost-controls/bedrock-rate-limit-stackset.ts` — CDK stack for the StackSet
- `lib/cost-controls/throttle-handler/index.ts` — Lambda handler
- `scripts/cost-controls/deploy-bedrock-rate-limit.sh` — deployment script
- `scripts/cost-controls/unfreeze-bedrock.sh` — manual recovery
- `scripts/cost-controls/test-bedrock-throttle.sh` — verification

### Phase 2 — Budget-action backstop (week 2)

**Goal:** Daily hard cost cap as second line of defense.

**Components:**
1. Per-account AWS Budget for Bedrock service ($10/day)
2. Budget Action at 100% threshold → attach `DenyBedrock` IAM managed policy to `IsbUsersPS` permission set
3. Budget Action at 80% threshold → SNS warning
4. Auto-create budget when ISB provisions a new lease (hook into ISB lease lifecycle)

**Why two layers?** AWS Budgets has 8–12 hour update latency. CloudWatch metrics are real-time. Budgets catches slow burns; CloudWatch catches bursts.

**Deliverables:**
- `lib/cost-controls/bedrock-budget.ts` — CDK construct
- `scripts/cost-controls/apply-bedrock-budgets.sh` — backfill existing accounts

### Phase 3 — Visibility (week 3)

**Goal:** Daily usage reports, anomaly detection.

**Components:**
1. EventBridge schedule (daily 00:05 UTC) → Lambda
2. Lambda queries CloudWatch metrics across all member accounts (input tokens, output tokens, invocations by model)
3. Calculates estimated daily cost per account using model pricing table
4. Emails admin a CSV with: account, team, tokens used, est. cost, % of budget consumed
5. Optional: post to Slack via webhook

**Deliverables:**
- `lib/cost-controls/daily-usage-report.ts`
- `scripts/cost-controls/manual-usage-report.sh` — on-demand version

---

## 5. Throttle Policy Templates

### Soft throttle — deny expensive models only

Use when the account hit the warning threshold. Allows continued work with Haiku.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ThrottleBedrockExpensive",
    "Effect": "Deny",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"],
    "Resource": [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet*",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus*",
      "arn:aws:bedrock:*:*:inference-profile/*sonnet*",
      "arn:aws:bedrock:*:*:inference-profile/*opus*"
    ]
  }]
}
```

### Hard throttle — deny all Bedrock

Use when account hit the daily cost cap.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ThrottleBedrockAll",
    "Effect": "Deny",
    "Action": "bedrock:*",
    "Resource": "*"
  }]
}
```

---

## 6. Threshold Calibration

Based on actual usage patterns observed during APU + MMU competitions:

| Model | Pricing (in/out per 1M) | 100K tokens cost | Tokens for $10 |
|---|---|---|---|
| Haiku 4.5 | $0.25 / $1.25 | $0.075 | ~13M tokens |
| Sonnet 4.5 | $3.00 / $15.00 | $0.90 | ~1M tokens |
| Sonnet 4.6 | $3.00 / $15.00 | $0.90 | ~1M tokens |
| Opus 4.6 (blocked) | $15.00 / $75.00 | $4.50 | ~220K tokens |

**Anonymous incident analysis:** $1,102 in 24h = ~46 req/min sustained at avg model mix. Our threshold of **60 RPM + 100K TPM** would have triggered within minutes.

**Proposed default thresholds per account:**

| Tier | RPM | TPM | Daily token cap | Est. daily cost |
|---|---|---|---|---|
| Conservative (default) | 30 | 50K | 2M | $3–5 |
| Standard | 60 | 100K | 5M | $7–10 |
| GenAI workshop | 120 | 200K | 10M | $15–20 |

Tier is set via account tag `BedrockTier=standard`. The throttle Lambda reads the tag to choose thresholds.

---

## 7. Rollback / Recovery Flow

When a team is throttled:

1. Admin gets email: "Account 123456789012 (team-name) auto-throttled at 14:32 UTC — TPM 134,000 over threshold 100,000"
2. Admin runs `./scripts/cost-controls/check-bedrock-incident.sh 123456789012`
   - Shows: tokens consumed, model breakdown, recent CloudTrail events
3. If legitimate: `./scripts/cost-controls/unfreeze-bedrock.sh 123456789012 --tier=standard`
4. If suspicious: leave throttled, contact team leader, terminate lease if needed

---

## 8. Testing Plan

1. Deploy to a single test account (`Sandbox01` in dirty pool)
2. Run a Python loop that calls Haiku rapidly until threshold trips
3. Verify:
   - CloudWatch alarm fires
   - SNS message published
   - Lambda assumes role and applies deny policy
   - User cannot invoke Bedrock (gets `AccessDenied`)
   - Email arrives at admin
4. Run `unfreeze-bedrock.sh`, verify access restored
5. Run for 24h to ensure no false positives during normal usage

---

## 9. Open Questions

- [ ] Should the throttle apply to the SSO permission set, or to specific IAM users? Permission set is cleaner since ISB users assume `IsbUsersPS`.
- [ ] Where to deploy the central Lambda — management account (`862099794180`) or ISB hub (`147826551593`)? Hub is simpler since it already has cross-account roles.
- [ ] Slack integration — is there an existing webhook? (Currently only email.)
- [ ] Should we expose tier upgrade as a self-service request via the ISB portal, or admin-only?

---

## 10. Decision Required

Pick a starting scope before I implement:

**Option A — Minimum viable (Phase 1 only):**
CloudWatch alarms + reactive Lambda. ~2 days to ship. Catches bursts.

**Option B — Defense in depth (Phase 1 + 2):**
Adds AWS Budget actions as a second layer. ~4 days to ship. Catches bursts AND slow burns.

**Option C — Full plan (Phase 1 + 2 + 3):**
Adds daily reporting and dashboards. ~1 week to ship. Full visibility.

**My recommendation: Option B.** Phase 3 is nice-to-have but not urgent. Phase 1+2 directly addresses the May 22 incident root cause: bursts (CloudWatch) and slow accumulation (Budgets).
