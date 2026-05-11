# FAQ - Common Issues

**Quick answers to frequently asked questions**

---

## General Questions

### Q: How long does account cleanup take?
**A:** Typically 10-15 minutes. If > 30 minutes, run `./scripts/fix-stuck-accounts.sh`

### Q: How many accounts can I register at once?
**A:** Up to 50 accounts can be cleaned in parallel. Use `./scripts/bulk-register-accounts.sh` for bulk registration.

### Q: What regions are required?
**A:** ap-southeast-3 and ap-southeast-5 must be enabled in all sandbox accounts.

### Q: Can I add custom fields to DynamoDB?
**A:** ❌ NO! Schema validation is strict. Only use documented fields or accounts will disappear from UI.

---

## Account Status

### Q: What do the different statuses mean?
- **Available**: Ready for lease assignment
- **Active**: Currently leased to a user
- **CleanUp**: Being cleaned (10-15 min)
- **Quarantine**: Drifted from Entry OU, needs manual fix
- **Frozen**: Manually frozen, won't be assigned

### Q: Account stuck in CleanUp, what do I do?
```bash
./scripts/fix-stuck-accounts.sh
```

### Q: All my accounts disappeared from the UI!
**A:** You likely added a custom field to DynamoDB. See RUNBOOK-TROUBLESHOOTING.md#accounts-disappeared-from-ui

### Q: Account shows "Entry" status error in logs
**A:** This is a Lambda caching issue. If DynamoDB shows correct status and cleanup is running, ignore the log warning.

---

## Registration

### Q: Can't register account - what's wrong?
**Check:**
1. Account in Entry OU? `aws organizations list-parents --child-id <id>`
2. Regions enabled? `./scripts/verify-infrastructure.sh`
3. Already registered? Check DynamoDB table

### Q: How do I register 30 accounts quickly?
```bash
# Create file with account IDs
echo "123456789012" > accounts.txt
echo "234567890123" >> accounts.txt

# Bulk register
./scripts/bulk-register-accounts.sh accounts.txt
```

---

## Cleanup

### Q: Why did cleanup fail?
**Common causes:**
1. **AccessDenied**: Spoke IAM role missing → Redeploy StackSet
2. **Region not enabled**: Enable ap-southeast-3 and ap-southeast-5
3. **Timeout**: Retry cleanup

### Q: How do I retry failed cleanup?
```bash
./scripts/fix-stuck-accounts.sh
```

### Q: Can I speed up cleanup?
**A:** No, AWS Nuke takes time. Typical duration: 10-15 minutes per account.

---

## Leases

### Q: How do I create a lease?
**Via Web UI:**
1. Navigate to Leases → Create Lease
2. Select user, template, duration, budget
3. Click Create

### Q: Can I extend an active lease?
**A:** Yes, via Web UI: Leases → Select lease → Extend

### Q: What happens when lease expires?
**A:** Account automatically moves to CleanUp, gets cleaned, returns to Available.

### Q: User can't access their leased account
**Check:**
1. User in correct IAM Identity Center group?
2. Lease still active (not expired)?
3. Account status is Active?

---

## Blueprints

### Q: How do I add a new blueprint?
**A:** Create StackSet in management account, then add via ISB Web UI → Blueprints → Create

### Q: Can I update an existing blueprint?
**A:** Yes, update the StackSet. Changes apply to new leases only.

### Q: Blueprint deployment failed
**A:** Check StackSet deployment status and CloudFormation stack events.

---

## Infrastructure

### Q: How do I check system health?
```bash
./scripts/health-check.sh
```

### Q: How do I verify infrastructure is working?
```bash
./scripts/verify-infrastructure.sh
```

### Q: StackSet not deploying to accounts
**Check:**
1. Regions enabled in accounts?
2. StackSet has correct permissions?
3. Accounts in correct OU?

---

## Errors

### Q: Getting 500 errors from API
**Check CloudWatch logs:**
```bash
aws logs tail InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL \
  --since 15m \
  --filter-pattern "ERROR" \
  --profile eta-isb
```

### Q: Getting "Invalid DateTime" errors
**A:** This was from adding custom `cleanupInitiatedTime` field. Remove it from DynamoDB.

### Q: Seeing "Entry" status validation errors
**A:** Non-critical if DynamoDB shows correct status. Lambda caching issue.

---

## Monitoring

### Q: How do I monitor cleanup progress?
```bash
./scripts/monitor-cleanup-progress.sh
```

### Q: Where are the logs?
```bash
aws logs tail InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL \
  --follow \
  --profile eta-isb \
  --region ap-southeast-3
```

### Q: How do I check Step Functions executions?
```bash
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:ap-southeast-3:147826551593:stateMachine:AccountCleanerStepFunctionStateMachineF32685E8-Fz5UGtEOpyyX \
  --status-filter RUNNING \
  --profile eta-isb
```

---

## Performance

### Q: How many accounts can ISB handle?
**A:** Tested up to 100 accounts. Theoretical limit much higher.

### Q: How many concurrent cleanups?
**A:** Up to 50 parallel cleanup workflows.

### Q: API rate limits?
**A:** API Gateway: 10,000 requests/second. DynamoDB: 40,000 read/write capacity units.

---

## Best Practices

### Q: How many Available accounts should I maintain?
**A:** Keep at least 20% of total accounts Available. Minimum 5 accounts.

### Q: When should I register new accounts?
**A:** During off-hours (evenings/weekends) to avoid impacting active users.

### Q: How often should I check system health?
**A:** Daily health check recommended. Weekly detailed review.

### Q: Should I enable more regions?
**A:** Only if needed. More regions = longer cleanup time.

---

## Troubleshooting Quick Reference

| Symptom | Quick Fix |
|---------|-----------|
| Account stuck in CleanUp | `./scripts/fix-stuck-accounts.sh` |
| Accounts disappeared | Remove custom DynamoDB fields |
| Can't register account | Check OU, regions, StackSet |
| Cleanup failed | Check logs, redeploy StackSet if AccessDenied |
| No available accounts | Wait for cleanup or register more |
| Lease creation fails | Check available accounts and user exists |
| 500 API error | Check CloudWatch logs |
| StackSet not deploying | Enable regions, check permissions |

---

## Scripts Quick Reference

```bash
# Health & Status
./scripts/health-check.sh                      # Dashboard view
./scripts/check-account-status-detailed.sh     # Detailed status
./scripts/verify-infrastructure.sh             # Infrastructure check

# Operations
./scripts/bulk-register-accounts.sh <file>     # Bulk registration
./scripts/monitor-cleanup-progress.sh          # Monitor cleanup
./scripts/fix-stuck-accounts.sh                # Fix stuck accounts

# Regions
./scripts/enable-ap-southeast-regions.sh <id>  # Enable regions
./scripts/check-ap-southeast-regions.sh <id>   # Check regions
```

---

## When to Escalate

**Escalate immediately if:**
- Multiple accounts in Quarantine
- System health < 50
- Data loss or corruption
- Security incident

**Escalate within 1 hour if:**
- Cleanup success rate < 80%
- Multiple accounts stuck
- Critical functionality broken

**Escalate next business day if:**
- Single account issue
- Minor configuration problems
- Feature requests

---

## Additional Resources

- **Daily Operations**: RUNBOOK-DAILY-OPERATIONS.md
- **Troubleshooting**: RUNBOOK-TROUBLESHOOTING.md
- **Architecture**: ARCHITECTURE-DEEP-DIVE.md
- **Web UI**: https://d1nu7n93cpbse4.cloudfront.net

---

**Can't find your answer?** Check RUNBOOK-TROUBLESHOOTING.md or contact technical lead.
