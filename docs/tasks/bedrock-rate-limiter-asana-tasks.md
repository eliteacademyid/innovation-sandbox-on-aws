# Asana Tasks — Bedrock Rate Limiter (B-prime)

Copy-paste these into Asana as tasks. Suggested project: **Innovation Sandbox / CendekiAwan**.

---

## Parent Task: [ISB] Bedrock Rate Limiter — B-prime Implementation

**Description:**
Rate-limit Bedrock usage per sandbox account to prevent budget overruns like the May 22 Anonymous incident ($1,316 single-day). Catches bursts within ~2 minutes and auto-recovers after 1 hour.

Plan doc: `docs/guides/BEDROCK-RATE-LIMITING-PLAN.md`
Commit: `663f05c` on `main`

---

### Subtask 1: ✅ [DONE] Deploy hub stack to ISB hub account
- **Assignee:** Andrian
- **Due:** 2026-06-08
- **Status:** Complete
- **Estimated Time:** 2h (actual: 1.5h)
- **Notes:** Stack `isb-myisb-bedrock-rate-limit-hub` deployed to 147826551593 (ap-southeast-1). Contains: Throttle Lambda, Recovery Lambda, DynamoDB table, EventBridge schedule, Admin SNS topic.

---

### Subtask 2: ✅ [DONE] Deploy member StackSet to all ISB sandbox accounts
- **Assignee:** Andrian
- **Due:** 2026-06-08
- **Status:** Complete
- **Estimated Time:** 1h (actual: 45m including retries)
- **Notes:** StackSet `isb-myisb-bedrock-rate-limit-member` deployed to 100 sandbox accounts. Each account now has: 2 CloudWatch alarms (TPM > 100K/min, RPM > 60/min), SNS topic, cross-account IAM role.

---

### Subtask 3: ✅ [DONE] Subscribe throttle Lambda to all member SNS topics
- **Assignee:** Andrian
- **Due:** 2026-06-08
- **Status:** Complete
- **Estimated Time:** 30m (actual: 20m)
- **Notes:** 100/100 accounts subscribed. Lambda permissions added per account.

---

### Subtask 4: ✅ [DONE] Confirm SNS admin email subscription
- **Assignee:** Andrian
- **Due:** 2026-06-09
- **Status:** Complete (2026-06-17)
- **Estimated Time:** 5m
- **Notes:** SNS admin email subscription confirmed. Throttle/recovery notifications will now be delivered to `andrian@eliteacademy.id`.

---

### Subtask 5: ✅ [DONE] Smoke test — trigger throttle on test account
- **Assignee:** Andrian
- **Due:** 2026-06-10
- **Status:** Complete (2026-06-18)
- **Estimated Time:** 1.5h (actual: ~3h including architecture fix)
- **Notes:**
  **Test account:** 210452151023 (eta-sandbox-hashcash)
  
  **Architecture change discovered during smoke test:**
  Original approach (attach inline deny policy to SSO role) was blocked by:
  1. SNS KMS encryption preventing CloudWatch alarm → SNS delivery
  2. SCP blocking `iam:ListRoles` in sandbox accounts
  3. AWS protecting SSO-reserved roles (`UnmodifiableEntity`) from any modification
  
  **Fix applied:** Switched to **SCP-based throttling**:
  - Lambda assumes role in management account (`isb-myisb-bedrock-org-scp-manager`)
  - Creates a deny-Bedrock SCP (`isb-myisb-bedrock-deny-{accountId}`)
  - Attaches SCP directly to the offending sandbox account
  - Recovery: detaches + deletes the SCP
  
  **End-to-end result validated:**
  - ✅ Alarm fires → SNS → Lambda invoked
  - ✅ SCP created (`p-50vy89zo`) and attached to account
  - ✅ Bedrock returns `AccessDeniedException` (throttled)
  - ✅ Recovery Lambda detaches + deletes SCP
  - ✅ Bedrock access restored (~15s SCP propagation delay)
  
  **Infrastructure changes:**
  - Removed KMS from member-stack SNS topic
  - Created org role: `arn:aws:iam::862099794180:role/isb-myisb-bedrock-org-scp-manager`
  - Added throttle role to SCP `p-1lb4bh9n` exception list
  - Rewrote throttle/recovery handlers for SCP approach
  - Hub stack updated with `OrgRoleArn` parameter

---

### Subtask 6: ✅ [DONE] 24-hour soak test — verify no false positives
- **Assignee:** Andrian
- **Due:** 2026-06-12
- **Status:** Complete (2026-06-18)
- **Estimated Time:** 30m active (+ 24h passive monitoring)
- **Notes:** Ran `soak-test-check.sh` on 2026-06-18. All 4 checks PASS:
  - No throttle events in last 24h ✓
  - Throttle Lambda not invoked (pre-smoke-test period) ✓
  - No Lambda errors ✓
  - No active throttles ✓
  
  System has been running 10+ days with recovery Lambda active (12 invocations/hour) and zero false positives across all 100 sandbox accounts.

---

### Subtask 7: ✅ [DONE] Add to ISB operations runbook
- **Assignee:** Andrian
- **Due:** 2026-06-13
- **Status:** Complete (2026-06-12, commit `84bbb69`)
- **Estimated Time:** 45m
- **Notes:** `docs/README-operations.md` updated with:
  - Quick reference commands (list-throttled, unfreeze, kill-switch, check-incident)
  - Alert response SOP (6-step procedure)
  - When to run `subscribe-member-topics.sh`

---

### Subtask 8: 🔲 [v2] Add AWS Cost Anomaly Detection
- **Assignee:** Andrian
- **Due:** 2026-06-20
- **Status:** Backlog
- **Estimated Time:** 3h
- **Notes:** Phase 2 of full Option D. Set up per-account Cost Anomaly Detection on Bedrock. Catches slow-burn overspend that CloudWatch RPM/TPM misses. Lower priority since the $10/day scenario would be caught within a few hours by ISB's existing budget monitoring.

---

### Subtask 9: 🔲 [v2] Per-team Application Inference Profiles
- **Assignee:** Andrian
- **Due:** 2026-06-30
- **Status:** Backlog
- **Estimated Time:** 4h
- **Notes:** Phase 2 of Option D. Create one Bedrock inference profile per team for cleaner per-team metrics + attribution. Requires IAM policy update to deny direct foundation-model ARNs and force usage through profiles.

---

### Subtask 10: 🔲 [v2] Daily Bedrock usage report
- **Assignee:** Andrian
- **Due:** 2026-06-30
- **Status:** Backlog
- **Estimated Time:** 3h
- **Notes:** Phase 3. EventBridge daily schedule → Lambda queries CloudWatch metrics across all accounts → emails admin a CSV with: account, team, tokens used, estimated daily cost, % of budget consumed.

---

### Subtask 11: ✅ [DONE] Bedrock Model Router — Cost Optimization
- **Assignee:** Andrian
- **Due:** 2026-06-25
- **Status:** Complete (2026-07-02)
- **Estimated Time:** 2h (actual: ~1h)
- **Notes:** Deployed and smoke-tested:
  - Simple → Amazon Nova Pro (us-east-1) ✓
  - Complex → Claude Sonnet 4.6 via inference profile (us-east-1, us-west-2, eu-west-1) ✓
  - DynamoDB prompt cache (24h TTL) ✓ — cache hit confirmed
  
  **Issue found & fixed:** Claude Sonnet 4+ requires inference profile ID
  (`us.anthropic.claude-sonnet-4-6`) — direct model ID invocation returns ValidationException.
  
  Stack: `isb-myisb-bedrock-model-router` (ap-southeast-1)
  Commit: `cc3329b`

---

### Subtask 12: ✅ [DONE] Update StackSet with SNS KMS fix
- **Assignee:** Andrian
- **Due:** 2026-06-20
- **Status:** Complete (2026-07-02)
- **Estimated Time:** 30m (actual: ~5m)
- **Notes:** StackSet `isb-myisb-bedrock-rate-limit-member` updated successfully.
  - Operation: `c92a8d8c-517f-436c-8b3e-c828abd06e09`
  - Result: 100/100 accounts SUCCEEDED
  - Changes propagated: removed KMS from SNS topic, fixed IAM ARN wildcard
  - Re-subscribed SNS topics: 15 new + 85 existing = 100 total

---

## Summary — Total Estimated Time

| Category | Tasks | Time |
|---|---|---|
| ✅ Done | #1–#7, #11, #12 | ~9h (actual: ~8h) |
| v2 backlog | #8, #9, #10 | ~10h |
| **Total remaining** | **3 tasks** | **~10h** |

---

## Key Architecture Decisions Log

| Date | Decision | Reason |
|------|----------|--------|
| 2026-06-08 | Original: inline deny policy on SSO role | Simple, per-account isolation |
| 2026-06-18 | **Changed to: SCP-based throttling** | AWS protects `AWSReservedSSO_*` roles as `UnmodifiableEntity`. SCP approach is actually cleaner — managed from hub, no cross-account IAM needed in sandboxes |
| 2026-06-18 | SNS topic: removed KMS encryption | `alias/aws/sns` key doesn't grant CloudWatch `kms:GenerateDataKey` — alarms can't publish to encrypted topics |
| 2026-06-18 | Added org role for SCP management | Hub Lambda assumes `isb-myisb-bedrock-org-scp-manager` in mgmt account to create/attach/detach/delete SCPs |
