# Lessons Learned — Innovation Sandbox on AWS Production Deployment

**Organization**: Elitery (Elite Academy)  
**Deployment Region**: ap-southeast-3 (Jakarta)  
**Version Deployed**: v1.2.7  
**Date**: May 2026

---

## Critical Issues Encountered

### 1. 87 Cleanup Failures from Non-Existent CloudTrail Trail

**Problem**: AWS Nuke attempted to delete a CloudTrail trail named "trail-yow" that didn't exist. The `TrailNotFoundException` was treated as a fatal error, causing ALL cleanup workflows to fail.

**Impact**: 87 failed executions, ~29 hours wasted CodeBuild time, ~$15-20 cost, 2 hours troubleshooting.

**Fix**: Added `trail-yow` to the CloudTrail trail filter in AWS Nuke config (AppConfig).

```yaml
CloudTrailTrail:
  - type: glob
    value: aws-controltower-*
  - type: exact
    value: all-org-cloud-trail
  - type: exact
    value: trail-yow  # ← THIS FIXED IT
```

**Lesson**: Always test nuke config on 1-2 accounts before bulk registration. One bad filter = all cleanups fail.

---

### 2. Accounts Disappear from UI After DynamoDB Modification

**Problem**: Adding a custom field (`cleanupInitiatedTime`) to DynamoDB caused accounts to disappear from the ISB web UI entirely.

**Root Cause**: ISB has strict schema validation on DynamoDB records. Unknown fields cause "Invalid DateTime" errors and the UI silently drops those records.

**Fix**: Removed the custom field. Never modify DynamoDB schema directly.

**Lesson**: ISB's DynamoDB tables have strict schemas. Never add custom fields — accounts will vanish from the UI.

---

### 3. 7/10 Accounts Quarantined on First Registration

**Problem**: After registering 10 accounts, 7 immediately went to Quarantine status without even attempting cleanup.

**Root Cause**: OU drift detection. The accounts were in the wrong OU (not Entry OU), so the drift monitor Lambda quarantined them immediately.

**Fix**: Move accounts to Entry OU (`ou-e21c-cz4ntm1j`) then retry cleanup.

```bash
aws organizations move-account \
  --account-id ACCOUNT_ID \
  --source-parent-id WRONG_OU_ID \
  --destination-parent-id ou-e21c-cz4ntm1j \
  --profile elite-academy
```

**Lesson**: OU drift is the #1 cause of Quarantine. Always check OU location FIRST before investigating cleanup failures.

---

### 4. SAML RequestHeaderSectionTooLarge Error

**Problem**: Users received "RequestHeaderSectionTooLarge" error when accessing the CloudFront URL. CloudFront has an 8KB header limit.

**Root Cause**: Google Workspace SCIM was sending too many attributes and group memberships in the SAML response, exceeding the 8KB limit.

**Fix**: Minimize SAML attributes to only 3 required ones:
- Subject: `${user:email}` (emailAddress format)
- email: `${user:email}`
- name: `${user:name}`

The `groups` attribute is OPTIONAL and should be removed if users belong to many groups.

**Lesson**: Keep SAML attributes minimal. If using Google Workspace with SCIM, filter group provisioning to only sync ISB-related groups.

---

## Deployment Gotchas

### 5. Enable Opt-In Regions BEFORE Registering Accounts

AWS Nuke cleanup fails if regions aren't enabled on sandbox accounts. Enable all needed regions on every sandbox account before registering them to the ISB pool.

```bash
python3 scripts/account-management/enable-regions-all-accounts.py
```

### 6. Pre-Configure Nuke Filters for Org-Managed Resources

These resources exist in sandbox accounts but can't be deleted. Add filters BEFORE first cleanup:

```yaml
filters:
  IAMRole:
    - type: glob
      value: AWSServiceRoleFor*
    - type: exact
      value: OrganizationAccountAccessRole
  CloudTrailTrail:
    - type: glob
      value: aws-controltower-*
  IAMSAMLProvider:
    - type: contains
      value: AWSSSO
```

### 7. ap-southeast-5 Has Limited Service Support

Many services return errors in ap-southeast-5 (non-fatal but noisy in logs):
- Bedrock: ValidationException, AccessDeniedException, InternalServerErrorException
- EC2 Verified Access: InvalidAction
- SageMaker Notebooks: UnknownOperationException
- SSM Quick Setup: DNS lookup failed
- DocDB Elastic: DNS lookup failed

These don't cause cleanup failures but clutter logs.

### 8. WAF Blocks Pagination Tokens for >20 Accounts

The `SizeRestrictions_QUERYSTRING` WAF rule blocks legitimate AWS Organizations pagination tokens on the GET /accounts/unregistered endpoint when handling more than 20 accounts. Fixed in ISB v1.0.5.

### 9. IDC Stack Fails with Many Groups/Permission Sets

If your Identity Center has many groups or permission sets, the IDC Configuration custom resource times out during deployment. Fixed in ISB v1.0.1 — use v1.0.1+ to avoid this.

### 10. Short Namespace Avoids Name Length Limits

Use a short namespace (e.g., "myisb") to avoid hitting CloudFormation resource name length limits. Long namespaces cause deployment failures.

---

## Operational Lessons

### 11. No Self-Registration — Build Bulk Scripts

ISB uses an enterprise security model. Users cannot create their own accounts. All users must be created by administrators in IAM Identity Center. Build automation:

```bash
# Single user
./scripts/user-management/create-test-user.sh user@co.com First Last user

# Bulk from CSV
./scripts/user-management/create-users-and-assign-leases.sh users.csv <TEMPLATE_UUID>
```

### 12. ISB Only Supports 1 User Per Lease

For team projects sharing 1 account, use the group-based workaround:

```bash
./scripts/user-management/team-sandbox-share.sh create team-alpha 123456789012 \
  alice@co.com bob@co.com carol@co.com
```

Creates an IDC group, adds members, assigns group to the sandbox account.

### 13. Group Assignments Survive Lease Expiration

When a lease expires, ISB revokes the individual user assignment but NOT group assignments. You must manually clean up:

```bash
./scripts/user-management/team-sandbox-share.sh delete team-alpha 123456789012
```

### 14. Pool Sizing Formula: 1.3× Concurrent Users

- 23 concurrent users → 31 accounts (8 buffer)
- Buffer accounts cover cleanup time (10-15 min per account)
- Without buffer, users wait for cleanup to finish

### 15. Cleanup Takes 10-15 Minutes

Plan for this delay. If all accounts are in use and one expires, the next user waits 10-15 minutes for cleanup before getting an account.

### 16. ISB Has No Operational Dashboards

Build your own monitoring from day 1:

```bash
./scripts/monitoring/health-check.sh          # System overview
./scripts/monitoring/check-account-pool-status.sh  # Pool availability
./scripts/monitoring/monitor-cleanup-progress.sh   # Cleanup jobs
```

### 17. Quarantine Troubleshooting Order

1. Check OU location (OU drift = #1 cause)
2. Check CloudWatch Logs for cleanup errors
3. Update nuke config filters
4. Retry cleanup via web UI

---

## Architecture Decisions That Worked

### 18. Rely on ISB SCPs, Don't Duplicate in Blueprints

ISB has 5 comprehensive SCPs that already block dangerous operations. Adding custom IAM deny policies in blueprints is redundant and harder to maintain.

- **Blueprint**: Enables services (AWS managed policies)
- **ISB SCPs**: Restricts operations (single source of truth)
- **Budgets**: Monitors costs

### 19. Use AWS Managed Policies in Blueprints

Instead of writing custom IAM policies, use AWS managed policies (e.g., `AmazonBedrockFullAccess`, `AmazonS3FullAccess`). They're maintained by AWS and follow best practices.

### 20. S3 Lifecycle Policies in Blueprints

Add `ExpirationInDays: 2` to all S3 buckets in blueprints. Even if AWS Nuke fails, data auto-deletes.

### 21. DynamoDB PAY_PER_REQUEST

No cost when idle, scales automatically. Perfect for sandbox accounts that may or may not be used.

### 22. Hub Account Separate from Management Account

- Management (862099794180): Organizations + IDC
- Hub (147826551593): ISB infrastructure (Compute + Data)

Better isolation, cleaner permissions, easier to troubleshoot.

---

## Cost Management

### 23. $10 Budget Per Account Is Enough for Workshops

Bedrock on-demand pricing is cheap for learning. Most users spend $2-5 in a 48-hour workshop.

### 24. Failed Cleanups Waste Money

87 failed CodeBuild executions × ~20 min each = ~$15-20 wasted. Fix nuke config issues quickly.

### 25. More Enabled Regions = Longer Cleanup = Higher Cost

AWS Nuke scans ALL enabled regions. Only enable regions you actually need. Our config: `us-east-1, ap-southeast-3, ap-southeast-1, ap-southeast-5`.

### 26. SageMaker Notebooks Are Expensive

Restrict to `ml.t3.medium` and `ml.t3.large` only in blueprints. Users forget to stop notebooks.

---

## Security

### 27. Keep ISB Updated — Security Patches Every 1-2 Weeks

The CHANGELOG shows CVE patches in nearly every release. Critical dependencies: aws-nuke, fast-xml-parser, xmldom, python, openssl, vite.

### 28. JWT Signature Verification Was Missing Until v1.2.0

Before v1.2.0, authentication could be bypassed if API Gateway was bypassed. Always use v1.2.0+.

### 29. SCIM from Google Workspace Adds Attack Surface

Large SAML responses can effectively DoS the application via CloudFront's header size limit. Minimize attributes and filter groups.

### 30. Accounts in Wrong OU Are Immediately Quarantined

The drift detection Lambda runs periodically and quarantines any account not in the expected OU. This is a security feature — prevents accounts from escaping ISB governance.

---

## Pre-Deployment Checklist

```
Before deploying ISB:
□ Increase AWS Organizations account quota (default is 10)
□ Enable opt-in regions on all sandbox accounts BEFORE registration
□ Pre-configure nuke filters for: CloudTrail, SecurityHub, GuardDuty, Config, org IAM roles
□ Test nuke config on 1-2 accounts before bulk registration
□ Minimize SAML attributes (only Subject, email, name needed)
□ Use short namespace (avoid CloudFormation name length limits)
□ Verify service availability in your chosen regions
□ Build user creation scripts (no self-registration)
□ Build health-check/monitoring scripts
□ Plan pool size: 1.3× expected concurrent users
□ Deploy ISB v1.2.0+ (JWT signature verification)
□ Set up CloudWatch alarms for cleanup failures
```

---

## Quick Reference

| Parameter | Value |
|-----------|-------|
| Management Account | 862099794180 |
| Hub Account | 147826551593 |
| Namespace | myisb |
| Entry OU | ou-e21c-cz4ntm1j |
| Identity Store ID | d-9667a833b5 |
| SSO Instance ARN | arn:aws:sso:::instance/ssoins-821055714a3e49c5 |
| Web App | https://d1nu7n93cpbse4.cloudfront.net |
| SSO Portal | https://d-9667a833b5.awsapps.com/start |
| API Endpoint | https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod |
| Regions | us-east-1, ap-southeast-3, ap-southeast-1, ap-southeast-5 |
| Pool Size | 31 accounts |
| Budget per Lease | $10 |
| Lease Duration | 48 hours |
