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

### Subtask 5: 🔲 Smoke test — trigger throttle on test account
- **Assignee:** Andrian
- **Due:** 2026-06-10
- **Status:** To Do
- **Estimated Time:** 1.5h
- **Notes:** 
  1. Pick one Available sandbox account
  2. Run a Python script that calls Haiku rapidly (100 calls in 30s)
  3. Verify CloudWatch alarm fires → SNS → Lambda → deny policy attached
  4. Verify email notification received
  5. Wait 1h (or run `unfreeze-bedrock.sh`) → verify auto-recovery works
  6. Document results in this task

---

### Subtask 6: 🔲 24-hour soak test — verify no false positives
- **Assignee:** Andrian
- **Due:** 2026-06-12
- **Status:** To Do
- **Estimated Time:** 30m active (+ 24h passive monitoring)
- **Notes:** Monitor 2–3 active student sandboxes for 24h. Confirm no false alarms during normal usage (< 30 RPM, < 50K TPM).

---

### Subtask 7: 🔲 Add to ISB operations runbook
- **Assignee:** Andrian
- **Due:** 2026-06-13
- **Status:** To Do
- **Estimated Time:** 45m
- **Notes:** Update `docs/README-operations.md` with:
  - Quick reference commands (list-throttled, unfreeze, kill-switch)
  - Alert response SOP (what to do when you get a throttle email)
  - When to run `subscribe-member-topics.sh` (after new sandboxes join pool)

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

## Quick Copy — CSV format (for Asana CSV import)

```csv
Name,Section,Assignee,Due Date,Estimated Time,Description,Tags
"[ISB] Confirm SNS admin email subscription",Bedrock Rate Limiter,Andrian,2026-06-09,5m,"Check andrian@eliteacademy.id for AWS SNS confirmation. Click link.",ISB;Urgent
"[ISB] Smoke test throttle on test account",Bedrock Rate Limiter,Andrian,2026-06-10,1.5h,"Trigger throttle with rapid Haiku calls. Verify alarm → deny → email → recovery.",ISB;Testing
"[ISB] 24-hour soak test — no false positives",Bedrock Rate Limiter,Andrian,2026-06-12,30m (+24h passive),"Monitor active sandboxes for 24h. Confirm no false alarms.",ISB;Testing
"[ISB] Update operations runbook with rate limiter SOP",Bedrock Rate Limiter,Andrian,2026-06-13,45m,"Add commands and alert response procedure to docs/README-operations.md",ISB;Docs
"[ISB] [v2] Cost Anomaly Detection for slow-burn protection",Bedrock Rate Limiter,Andrian,2026-06-20,3h,"Per-account Cost Anomaly Detection on Bedrock service. Backlog.",ISB;v2
"[ISB] [v2] Per-team Inference Profiles for attribution",Bedrock Rate Limiter,Andrian,2026-06-30,4h,"Create Bedrock inference profiles per team. Backlog.",ISB;v2
"[ISB] [v2] Daily Bedrock usage report email",Bedrock Rate Limiter,Andrian,2026-06-30,3h,"EventBridge + Lambda for daily cross-account usage CSV. Backlog.",ISB;v2
```

## Summary — Total Estimated Time

| Category | Tasks | Time |
|---|---|---|
| Already done | #1, #2, #3 | ~2.5h (actual: 2h 35m) |
| Immediate (this week) | #4, #5, #6, #7 | ~2h 50m active |
| v2 backlog | #8, #9, #10 | ~10h |
| **Total remaining** | **7 tasks** | **~13h** |
