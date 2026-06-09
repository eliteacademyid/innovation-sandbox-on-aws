# Cost Controls — Bedrock Rate Limiter (B-prime)

Layered defense that catches runaway Bedrock usage in ISB sandbox accounts within ~2 minutes, so a single bad script can't blow past the lease budget like the May 22 Anonymous incident.

See the full plan: [`docs/guides/BEDROCK-RATE-LIMITING-PLAN.md`](../../docs/guides/BEDROCK-RATE-LIMITING-PLAN.md).

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
