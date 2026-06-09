# Bedrock RPM/TPM Rate Limiting Plan

**Status:** Draft — pending implementation
**Author:** Andrian Maulana
**Date:** 2026-06-08
**Related Incident:** [2026-05-22 Anonymous budget overrun](../incidents/2026-05-22-anonymous-budget-overrun.md) ($1,316 in one day)

---

## 1. Problem Statement

A single sandbox account ran a runaway script and spent **$1,102 on Bedrock in 24 hours** before our Cost Explorer-based monitoring could detect and freeze it. We need to **rate limit Bedrock invocations per account** so a single bad script cannot blow past the $50 lease budget.

### Scope — ISB sandbox accounts ONLY

Every control in this plan is deliberately scoped to ISB-managed sandbox accounts. The management account (`862099794180`), the ISB hub account (`147826551593`), the IDC account, and any non-ISB workload accounts are **never** touched.

| Control | How it's scoped to ISB only |
|---|---|
| CloudWatch alarms (Phase 1) | StackSet deploys to the four ISB OUs only: `Entry`, `Active`, `Frozen`, `CleanUp`. Excludes the management account and any OU outside `ParentOuId`. |
| Auto-throttle deny policy (Phase 1) | Attached as an inline policy on the `IsbUsersPS` SSO permission set. This permission set only exists in sandbox accounts via ISB. Mgmt-account admins, `IsbAdmins`, hub-account roles, and `AWSReservedSSO_AdministratorAccess_*` are unaffected. |
| AWS Budgets (Phase 2) | One budget per sandbox account. No org-level budget. |
| Budget Action policy (Phase 2) | Same `IsbUsersPS` permission set scoping as Phase 1. |
| Daily report Lambda (Phase 3) | Read-only — only queries CloudWatch metrics. Does not modify anything. |

**No new SCPs are added.** The existing org SCPs already exclude management/hub roles via `ArnNotLike` on `aws:PrincipalARN`. This plan adds zero SCP statements — all enforcement happens at the IAM permission-set level inside member accounts.

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
│  Layer 1: Preventive SCP (already deployed) — ISB OUs only       │
│  - Attached to OU: myisb_InnovationSandboxAccountPool            │
│    (ou-e21c-9df44eh0) → cascades to Entry, Available, Active,    │
│    Frozen, Quarantine, CleanUp, Exit child OUs                   │
│  - Mgmt (862099794180), ISB hub (147826551593), IDC: NOT in OU,  │
│    so SCP does not apply to them at all                          │
│  - Inside sandbox accounts, ArnNotLike exempts ISB infra roles   │
│    (IsbAdmins, InnovationSandbox-myisb*, stacksets, CT exec)     │
│  - Effective scope: IsbUsersPS sessions only (the students)      │
│  - Denies: Opus models                                           │
│  - Allows: Haiku, Sonnet, Llama, Titan, Mistral, Cohere          │
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

**Scoping (ISB accounts only):**
- StackSet deployment target = the four ISB OUs (`Entry`, `Active`, `Frozen`, `CleanUp`) under `$PARENT_OU_ID`
- StackSet auto-deployment = `Enabled` so new sandbox accounts pick it up automatically
- Management account, hub account, and any non-ISB OU are explicitly excluded from the StackSet target

**Components:**
1. **StackSet** that deploys to every active sandbox account (ISB OUs only):
   - 2 CloudWatch alarms on `AWS/Bedrock` namespace:
     - `BedrockTPM` — sum of `InputTokenCount` + `OutputTokenCount` > 100K for 1 datapoint of 1 minute
     - `BedrockRPM` — `Invocations` > 60 for 2 consecutive 1-minute datapoints
   - SNS topic `bedrock-throttle-trigger` in member account
   - IAM role allowing the central Lambda to assume in
2. **Central Lambda** in the ISB hub account (`147826551593`):
   - Subscribed to all member SNS topics (cross-account via EventBridge bus, or direct SNS subscription)
   - On alarm → assume role into the sandbox member → modify the `IsbUsersPS` SSO permission set inline policy to deny Bedrock
   - Important: it modifies **only `IsbUsersPS`**, never `IsbAdminsPS` or `IsbManagersPS`
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

**Scoping (ISB accounts only):**
- Budgets are **per-account**, created inside each sandbox member account by the same StackSet from Phase 1
- No org-level / management-level budgets are added
- Budget action targets only the `IsbUsersPS` permission set in that one account

**Components:**
1. Per-account AWS Budget for Bedrock service ($10/day) — created in each sandbox member, not in management
2. Budget Action at 100% threshold → attach `DenyBedrock` IAM managed policy to that account's `IsbUsersPS`
3. Budget Action at 80% threshold → SNS warning to `helpdesk@eliteacademy.id`
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

- [x] ~~Should the throttle apply to the SSO permission set, or to specific IAM users?~~ **Per-account IAM role inline policy** — directly attached to `AWSReservedSSO_myisb_IsbUsers_<hash>` in just the offending account. Modifying the permission set itself would re-provision and affect all 100+ sandboxes.
- [x] ~~Where to deploy the central Lambda?~~ ISB hub account (`147826551593`) — already has cross-account roles into all sandbox members. Management account stays untouched.
- [ ] Slack integration — is there an existing webhook? (Currently only email.)
- [ ] Should we expose tier upgrade as a self-service request via the ISB portal, or admin-only?

---

## 10. Decision — Shipping Option B-prime

After reviewing the original A/B/C options, several real gaps were identified:

| Gap | Original A/B/C had it? | B-prime fix |
|---|---|---|
| Modifying `IsbUsersPS` affects ALL sandbox accounts | Yes — major footgun | Attach inline policy to per-account SSO IAM role instead |
| No auto-recovery — admin manually unfreezes | Yes — bad for off-hours incidents | EventBridge schedule expires throttles after 1h (configurable) |
| Streaming TPM under-counted | Yes | Add CompositeAlarm OR `RPM` (count) to catch parallel bursts even if TPM lags |
| No emergency kill switch | Yes | One-click admin script throttles all sandbox accounts at once |
| Per-team attribution missing | Yes | Deferred to v2 with Application Inference Profiles |

### B-prime — what we ship now (~1 week)

- **Layer 1** (already deployed): SCP denies Opus
- **Layer 3**: CloudWatch alarms per sandbox account (TPM > 100K/min, RPM > 60/min)
- **Layer 4**: Throttle Lambda in hub account → assumes role into the one offending account → attaches inline deny policy to its `AWSReservedSSO_myisb_IsbUsers_*` role
- **Layer 5**: Auto-recovery — DynamoDB tracks throttle expiry; EventBridge runs every 5 min to lift expired throttles
- **Layer 7**: Emergency kill switch — admin script that throttles all sandbox accounts at once

### Deferred to v2 (Option D full)

- **Layer 2**: Per-team Application Inference Profiles (cleaner per-team metrics)
- **Layer 6**: AWS Cost Anomaly Detection (replaces Budget Actions for slow burns)
- **Layer 8**: Daily usage report email

### Honest limitations of B-prime

| Limitation | Impact | Damage estimate |
|---|---|---|
| ~2 min metric publication delay | Bursty parallel scripts can spend before alarm fires | $5–30 per incident on Sonnet, $1–3 on Haiku |
| No streaming-aware TPM | Long streamed responses publish tokens at end | Up to 60s of unmonitored streaming |
| Account-level (not user-level) throttle | All students on one account share the limit | If 3 students hammer Bedrock concurrently, all 3 throttled together |
| Manual lease termination | Throttle pauses Bedrock, doesn't terminate lease | Admin must explicitly terminate if needed |

vs. May 22 incident damage of $1,316: B-prime should reduce per-incident loss to under $50 in the worst case, and catch most incidents within 2–5 min.

---

## 11. B-prime Deliverables

### Code
- `infra/cost-controls/bedrock-rate-limit/member-stack.yaml` — CloudFormation template for per-sandbox-account resources (alarms + SNS topic + cross-account role)
- `infra/cost-controls/bedrock-rate-limit/hub-stack.yaml` — CloudFormation template for hub-side resources (Lambdas + DynamoDB + EventBridge)
- `infra/cost-controls/bedrock-rate-limit/throttle_handler/handler.py` — throttle Lambda (Python)
- `infra/cost-controls/bedrock-rate-limit/recovery_handler/handler.py` — auto-recovery Lambda (Python)

### Operations scripts
- `scripts/cost-controls/deploy-bedrock-rate-limit.sh` — bootstraps the StackSet + hub stack
- `scripts/cost-controls/unfreeze-bedrock.sh <account-id>` — manual unfreeze
- `scripts/cost-controls/kill-switch-bedrock.sh` — emergency throttle-all
- `scripts/cost-controls/check-bedrock-incident.sh <account-id>` — investigation helper
- `scripts/cost-controls/list-throttled-accounts.sh` — show currently throttled accounts
- `scripts/cost-controls/README.md` — runbook

### Architecture details

**Per-sandbox account (CloudFormation StackSet target = ISB OUs only):**
- 2 CloudWatch alarms on `AWS/Bedrock` namespace
  - `BedrockRateLimit-TPM`: `InputTokenCount + OutputTokenCount` sum > 100K for 1 datapoint of 60s
  - `BedrockRateLimit-RPM`: `Invocations` sum > 60 for 2 consecutive 60s datapoints
- SNS topic `bedrock-throttle-trigger` (subscribed to both alarms)
- IAM role `BedrockThrottleRole` allowing the hub Lambda to: `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:ListRoles` on `AWSReservedSSO_myisb_IsbUsers_*`

**Hub account (`147826551593`):**
- DynamoDB table `BedrockThrottleEvents` (account_id pk, expires_at, throttled_at, reason, alarm_arn)
- Lambda `bedrock-throttle-handler` — subscribed to all member SNS topics via cross-account subscription
  - On invoke: read account_id from SNS message → assume `BedrockThrottleRole` → find SSO IsbUsers role → attach `BedrockThrottleDeny` inline policy → write DynamoDB record with 1h expiry → SES email admin + team leader
- Lambda `bedrock-recovery-handler` — runs every 5 min via EventBridge schedule
  - Scan DynamoDB for expired records → assume role → delete inline policy → mark record cleared → SES email "throttle lifted"

**StackSet target:**
- Deployed FROM: ISB hub account (`147826551593`)
- Deployed TO: OUs `Entry`, `Available`, `Active`, `Frozen`, `Quarantine`, `CleanUp`, `Exit` under `myisb_InnovationSandboxAccountPool` (`ou-e21c-9df44eh0`)
- Auto-deployment: `Enabled` so newly-registered sandbox accounts inherit it
- Excluded: management (`862099794180`), hub (`147826551593`), IDC, any non-ISB OU

---

## 12. Testing Plan (B-prime)

1. **Deploy to one test account first** (a Sandbox in `Available` OU)
2. **Burst test (RPM)**: Python script firing 100 Haiku calls in 30s → expect alarm + throttle within 2 min
3. **Burst test (TPM)**: One large Sonnet call (50K input tokens) → expect TPM alarm if over threshold
4. **Verify deny applies**: User in throttled account gets `AccessDenied` on `bedrock:InvokeModel`
5. **Auto-recovery**: Wait 1h, verify EventBridge fires, deny policy removed, Bedrock works again
6. **Kill switch**: Run `kill-switch-bedrock.sh`, verify all sandboxes denied within 30s
7. **Manual unfreeze**: Run `unfreeze-bedrock.sh <account>`, verify single-account recovery
8. **24h soak test** in two production-like accounts to check for false positives

---

## 13. Rollout Plan

| Step | Owner | Timing |
|---|---|---|
| 1. Deploy hub-stack to `147826551593` | Andrian | Day 1 |
| 2. Deploy member-stack StackSet to one test sandbox | Andrian | Day 1 |
| 3. Run testing plan (steps 1–7) | Andrian | Day 2 |
| 4. Roll out StackSet to all `Available` OU accounts | Andrian | Day 3 |
| 5. Monitor for 24h | — | Day 3–4 |
| 6. Roll out to `Active` OU (live student accounts) | Andrian | Day 4 |
| 7. Add to ISB onboarding runbook | Andrian | Day 5 |
