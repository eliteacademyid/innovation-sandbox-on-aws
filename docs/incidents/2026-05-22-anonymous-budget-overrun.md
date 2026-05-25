# Incident Report: Team Anonymous — Budget Overrun

## Summary

| Field | Value |
|-------|-------|
| **Date** | May 22, 2026 |
| **Team** | Anonymous (Team #16) |
| **Team Leader** | TP076099@mail.apu.edu.my (Tan Ee Xin) |
| **Account** | 732304102832 |
| **Lease UUID** | 885ff58a-7ac7-4644-9f7b-9ddac85da0a9 |
| **Budget** | $50 |
| **Actual Cost** | $1,316.41 |
| **Overage** | $1,266.41 (2,533% over budget) |
| **Status** | BudgetExceeded (frozen) |
| **Lease Template** | CendekiAwan APU Finalist (a5436dde-de4d-46a2-bd5f-d4a068b8d93d) |

---

## Timeline

| Date | Daily Cost | Cumulative | Event |
|------|-----------|------------|-------|
| May 8 | $35.14 | $35.14 | Lease started, initial setup |
| May 9-18 | ~$1/day | ~$43 | Normal development usage |
| May 19 | $54.86 | ~$98 | First spike — should have triggered freeze |
| May 20 | $0.39 | ~$98 | Quiet day |
| May 21 | $89.15 | ~$187 | Second spike |
| **May 22** | **$1,102.23** | **~$1,289** | 🚨 Massive spike — single day |
| May 23 | $27.01 | $1,316 | ISB detected, account frozen |

---

## Cost Breakdown by Service

| Service | Cost | % of Total |
|---------|------|-----------|
| Claude Sonnet 4.6 (Bedrock) | $494.89 | 37.6% |
| Claude Sonnet 4.5 (Bedrock) | $318.47 | 24.2% |
| Claude Opus 4.6 (Bedrock) | $216.77 | 16.5% |
| Tax | $130.15 | 9.9% |
| Claude Haiku 4.5 (Bedrock) | $89.94 | 6.8% |
| Claude Opus 4.5 (Bedrock) | $63.63 | 4.8% |
| AWS WAF | $2.49 | 0.2% |
| AWS Service Catalog | $0.06 | 0.0% |
| **TOTAL** | **$1,316.41** | **100%** |

---

## Root Cause Analysis

### Primary Cause: Uncontrolled Bedrock API Usage

The team made an extremely high volume of Bedrock API calls, primarily to expensive models (Sonnet 4.6, Opus 4.6). The $1,102 spike on May 22 suggests:

1. **Runaway automation** — A script or application calling Bedrock in a loop without rate limiting or cost controls
2. **Use of expensive models** — Opus 4.6 ($15/1M input, $75/1M output) and Sonnet 4.6 ($3/1M input, $15/1M output) were used heavily instead of cheaper alternatives (Haiku at $0.25/1M input)
3. **No application-level cost controls** — No token limits, request throttling, or cost caps in their application code

### Contributing Factors

1. **Cost Explorer 24-48h delay** — ISB's cost monitoring relies on AWS Cost Explorer which has inherent reporting lag. The team's spending on May 22 wasn't visible to ISB until May 23.
2. **ISB cost check interval** — The lease monitoring Lambda runs periodically (~every 2 hours). A burst of spending between checks can exceed the budget before detection.
3. **No per-model restrictions** — The SCP grants full Bedrock access without model-level restrictions. The team used the most expensive models available.
4. **Budget threshold configuration** — Freeze threshold was set at $45 (FREEZE_ACCOUNT action), but the cost data lag meant the actual spend was far beyond $45 by the time it was detected.

---

## Impact

| Impact Area | Details |
|-------------|---------|
| **Financial** | $1,266.41 unbudgeted cost to the organization |
| **Team** | Team Anonymous lost sandbox access (competition impact) |
| **Other teams** | No impact — accounts are isolated |
| **ISB Platform** | No impact — system worked as designed (detected and froze) |

---

## ISB Response

1. ✅ ISB detected the budget overrun on May 22 at 17:39 UTC
2. ✅ Lease status changed to `BudgetExceeded`
3. ✅ Account access revoked (SSO permissions removed)
4. ✅ Account moved to frozen OU
5. ⏳ Account cleanup (AWS Nuke) will run on lease termination

---

## Lessons Learned

### What Worked
- ISB budget monitoring detected the overrun and froze the account
- Account isolation prevented impact to other teams
- SCP protections remained intact

### What Didn't Work
- Cost Explorer lag allowed $1,100+ to accumulate in a single day before detection
- No real-time spending alerts (only periodic batch checks)
- No per-model or per-request throttling

---

## Recommendations

### Short-term (for current competition)

1. **Warn all teams** about Bedrock costs — especially Opus/Sonnet pricing
2. **Consider adding Bedrock model restrictions** via SCP — deny Opus models, allow only Haiku/Sonnet
3. **Reduce cost check interval** — increase monitoring frequency during competition

### Long-term (for ISB platform)

1. **Implement AWS Budgets with real-time alerts** — AWS Budgets can send SNS notifications within hours (faster than Cost Explorer)
2. **Add Bedrock throttling quotas** — Use Service Quotas to limit Bedrock requests per account
3. **Per-model SCP restrictions** — Deny expensive models (Opus) by default, require explicit opt-in
4. **Real-time cost anomaly detection** — Use AWS Cost Anomaly Detection for faster alerting
5. **Application-level token budgets** — Provide teams with a Bedrock proxy that enforces token limits

### SCP Example: Deny Expensive Models

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyExpensiveBedrockModels",
      "Effect": "Deny",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-*",
        "arn:aws:bedrock:*:*:inference-profile/*opus*"
      ]
    }
  ]
}
```

---

## Financial Resolution

| Item | Amount |
|------|--------|
| Budgeted | $50.00 |
| Actual cost | $1,316.41 |
| Overage | $1,266.41 |
| Covered by AWS credits? | TBD — check with AWS account team |
| Action | Escalate to finance / AWS support |

---

## Status

- [x] Incident detected
- [x] Account frozen
- [x] Root cause identified
- [x] Documentation created
- [ ] Team notified
- [ ] Financial resolution
- [ ] Preventive measures implemented
- [ ] Post-mortem with team
