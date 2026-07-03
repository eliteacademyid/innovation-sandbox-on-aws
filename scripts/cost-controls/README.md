# Cost Controls — ISB Custom Extensions

Layered defense system for ISB sandbox accounts. Prevents cost overruns, provides visibility, and optimizes Bedrock model usage.

## Full Architecture

```
┌─────────────────────── Cost Protection Stack ───────────────────────────┐
│                                                                          │
│  Layer 1: ISB Budget Controls ($10/lease, freeze $45)    ← built-in     │
│  Layer 2: Rate Limiter (burst: >100K TPM / >60 RPM)     ← SCP-based    │
│  Layer 3: Cost Anomaly Detection (slow-burn: >$5)        ← AWS native   │
│  Layer 4: Model Router (Nova Pro for simple tasks)       ← cost optim.  │
│  Layer 5: Per-team Inference Profiles                    ← attribution  │
│  Layer 6: Kill-switch (emergency freeze all)             ← manual       │
│                                                                          │
├─────────────────────── Observability ───────────────────────────────────┤
│                                                                          │
│  • CloudWatch Dashboard (ISB-Operations-myisb)                          │
│  • Daily Usage Report (08:00 WIB, CSV email)                            │
│  • Weekly Health Report (Monday 09:00 WIB, HTML email)                  │
│  • Cleanup Failure Alarm (≥3 fails/hour)                                │
│  • Cleanup Duration Alarm (>30 min stuck)                               │
│  • Cross-Account Observability (OAM, 100 accounts)                      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Stacks

| Stack | Type | Schedule |
|-------|------|----------|
| `isb-myisb-bedrock-rate-limit` | Hub CFN + StackSet (100 accounts) | Event-driven |
| `isb-myisb-bedrock-model-router` | Hub CFN + API Gateway | On-demand |
| `isb-myisb-bedrock-usage-report` | Hub CFN + EventBridge | Daily 08:00 WIB |
| `isb-myisb-weekly-health-report` | Hub CFN + EventBridge | Monday 09:00 WIB |
| `isb-myisb-observability-link` | StackSet (100 accounts) | Always-on |

## Deploy All

```bash
./scripts/cost-controls/deploy-all.sh
```

Or individually:

```bash
./scripts/cost-controls/deploy-bedrock-rate-limit.sh
./scripts/cost-controls/deploy-bedrock-model-router.sh
./scripts/cost-controls/deploy-bedrock-usage-report.sh
# Weekly report deployed within deploy-all.sh
```

## Model Router API (for students)

See [`docs/guides/MODEL-ROUTER-API-GUIDE.md`](../../docs/guides/MODEL-ROUTER-API-GUIDE.md).

```bash
curl -X POST "https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke" \
  -H "x-api-key: <key>" \
  -d '{"prompt": "What is ML?"}'
```

## Architecture (B-prime)

```
                      Sandbox account (StackSet target)
┌─────────────────────────────────────────────────────────────────┐
│  CloudWatch alarms          SNS topic                IAM role   │
│  ├─ TPM > 100K/min   ──→    bedrock-throttle-trigger ←── Hub    │
│  └─ RPM > 60/min                                                │
└────────────────────────────────────┬────────────────────────────┘
                                     │ SNS subscription
                                     ▼
                      Hub account (147826551593)
┌─────────────────────────────────────────────────────────────────┐
│  Throttle Lambda         DynamoDB                Recovery Lambda│
│   • assumes member role  isb-myisb-...           • runs every 5m│
│   • attaches deny policy ←──── tracks state ────→• lifts expired│
│   • SES email admin                              • SES email    │
└─────────────────────────────────────────────────────────────────┘
```

The throttle inline policy is attached to the `AWSReservedSSO_myisb_IsbUsers_*` role in just the offending account — never the SSO permission set itself, so other sandbox accounts are unaffected.

## Scope

- **Targets:** ISB sandbox accounts only (under OU `myisb_InnovationSandboxAccountPool`).
- **Excluded:** management account (`862099794180`), hub account (`147826551593`), IDC account, all non-ISB workload accounts.
- **Inside sandbox accounts:** only `IsbUsersPS` SSO sessions are denied. Admins, infra roles, and `IsbAdmins` are unaffected.

## First-time setup

```bash
# 1. Make sure .env has HUB_ACCOUNT_ID, ORG_MGT_ACCOUNT_ID, PARENT_OU_ID, NAMESPACE
# 2. AWS profiles: eta-andrian (mgmt), eta-isb-andrian (hub)
# 3. SES sender helpdesk@eliteacademy.id verified in SES_REGION (ap-southeast-3)

./scripts/cost-controls/deploy-bedrock-rate-limit.sh
```

The script:
1. Creates an artifacts S3 bucket in the hub account
2. Packages and uploads both Lambda zips
3. Deploys `hub-stack.yaml` to the hub account (Lambdas, DynamoDB, EventBridge)
4. Creates/updates a service-managed StackSet in the management account that deploys `member-stack.yaml` to all ISB child OUs
5. Subscribes the throttle Lambda to each member SNS topic

After new sandbox accounts join the pool, re-run:

```bash
./scripts/cost-controls/subscribe-member-topics.sh
```

(StackSet auto-deployment handles the member resources; only the SNS subscription has to be created from the hub side.)

## Day-to-day operations

### See who's currently throttled

```bash
./scripts/cost-controls/list-throttled-accounts.sh
```

### Investigate an incident

```bash
./scripts/cost-controls/check-bedrock-incident.sh 732304102832
```

Shows recent throttle history. With `MEMBER_PROFILE` exported, it also dumps the last hour of Bedrock metrics for that account.

### Manually unfreeze before the 1h auto-recovery

```bash
./scripts/cost-controls/unfreeze-bedrock.sh 732304102832
```

Forces the throttle record to expire and invokes the recovery Lambda synchronously.

### Emergency: throttle every sandbox account at once

```bash
./scripts/cost-controls/kill-switch-bedrock.sh
# optional: --duration 7200 to extend the auto-recovery window to 2 hours
```

Asks for `EMERGENCY` confirmation. Does not affect mgmt/hub/IDC accounts.

## Tuning

Override defaults at deploy time via env vars:

| Var | Default | Effect |
|---|---|---|
| `TPM_THRESHOLD` | 100000 | Tokens/min before TPM alarm fires |
| `RPM_THRESHOLD` | 60 | Requests/min before RPM alarm fires |
| `RPM_EVAL_PERIODS` | 2 | Consecutive minutes over RPM to alarm |
| `THROTTLE_DURATION_SECONDS` | 3600 | How long a throttle lasts |
| `ADMIN_EMAIL` | `andrian@eliteacademy.id` | Notification recipient |
| `SES_SOURCE_EMAIL` | `helpdesk@eliteacademy.id` | Verified SES sender |
| `SES_REGION` | `ap-southeast-3` | SES region |

After changing thresholds, re-run `deploy-bedrock-rate-limit.sh` to push the StackSet update.

## Known limitations

- **~2 min metric publication delay.** Worst case: $5–30 burn before throttle fires on Sonnet, $1–3 on Haiku.
- **Streamed responses publish tokens at end.** Long streams can underreport TPM until completion.
- **Account-level throttle.** All students sharing one sandbox share the limit.
- **No per-team attribution.** Add Application Inference Profiles in v2 (Layer 2 of Option D in the plan).

## Files

```
infra/cost-controls/bedrock-rate-limit/
├── member-stack.yaml          # CFN deployed via StackSet to each sandbox account
├── hub-stack.yaml             # CFN deployed once to the hub account
├── throttle_handler/handler.py
└── recovery_handler/handler.py

scripts/cost-controls/
├── deploy-bedrock-rate-limit.sh
├── subscribe-member-topics.sh
├── unfreeze-bedrock.sh
├── kill-switch-bedrock.sh
├── list-throttled-accounts.sh
├── check-bedrock-incident.sh
└── README.md
```
