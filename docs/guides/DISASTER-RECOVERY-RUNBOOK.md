# ISB Disaster Recovery Runbook

## Severity Levels

| Level | Definition | Response Time | Example |
|-------|-----------|---------------|---------|
| **P1** | ISB completely down, no users can access | 15 min | Hub account compromised, CloudFront down |
| **P2** | Core feature broken, workaround exists | 1 hour | Cleanup failures, lease creation broken |
| **P3** | Degraded but functional | 4 hours | Slow cleanup, missing metrics |
| **P4** | Cosmetic or minor | Next business day | Dashboard widget broken |

---

## Scenario 1: Hub Account Inaccessible (P1)

**Symptoms:** CloudFront 5xx, API 503, cannot assume role into hub account.

**Steps:**
1. Verify from management account:
   ```bash
   aws sts assume-role --role-arn arn:aws:iam::147826551593:role/OrganizationAccountAccessRole \
     --role-session-name dr-check --profile eta-andrian
   ```
2. If role assumption fails → AWS Support ticket (severity: critical)
3. If role works but services down → check us-east-1 health dashboard (global services)
4. Temporary mitigation: students continue via SSO portal directly (bypass ISB UI)
   ```
   SSO Portal: https://d-9667a833b5.awsapps.com/start
   ```
5. Active leases continue until expiry (DynamoDB TTL handles cleanup)

**Recovery:**
- Re-deploy compute stack: `npm run deploy:compute`
- Verify: `curl -s https://aws-sandbox.eliteacademy.id`

---

## Scenario 2: DynamoDB Table Corrupted/Deleted (P1)

**Symptoms:** API returns 500, accounts disappear from UI.

**Steps:**
1. Check table exists:
   ```bash
   aws dynamodb describe-table --table-name InnovationSandbox-Data-SandboxAccountTableEFB9C069-16YC6RUKNE15K \
     --profile eta-isb-andrian --region ap-southeast-1
   ```
2. If table deleted → restore from Point-in-Time Recovery (PITR):
   ```bash
   aws dynamodb restore-table-to-point-in-time \
     --source-table-name <original-name> \
     --target-table-name <original-name>-restored \
     --use-latest-restorable-time \
     --profile eta-isb-andrian --region ap-southeast-1
   ```
3. If data corrupted → restore to specific point:
   ```bash
   aws dynamodb restore-table-to-point-in-time \
     --source-table-name <table> \
     --target-table-name <table>-restored \
     --restore-date-time "2026-07-01T00:00:00Z" \
     --profile eta-isb-andrian --region ap-southeast-1
   ```
4. After restore: update stack to point to restored table, or rename

**Prevention:** PITR is enabled by default on ISB DynamoDB tables (CMK encrypted).

---

## Scenario 3: All Accounts Quarantined (P2)

**Symptoms:** Pool shows 0 Available, all accounts in Quarantine.

**Root Cause:** Usually OU restructuring or drift monitor false positive.

**Steps:**
1. Check quarantine reason:
   ```bash
   aws dynamodb scan --table-name InnovationSandbox-Data-SandboxAccountTableEFB9C069-16YC6RUKNE15K \
     --profile eta-isb-andrian --region ap-southeast-1 \
     --filter-expression "#s = :q" \
     --expression-attribute-names '{"#s":"status"}' \
     --expression-attribute-values '{":q":{"S":"Quarantine"}}' \
     --projection-expression "awsAccountId,#s" --select COUNT --query Count
   ```
2. Verify OU placement:
   ```bash
   aws organizations list-children --parent-id ou-e21c-cz4ntm1j --child-type ACCOUNT \
     --profile eta-andrian --query "Children | length(@)"
   ```
3. If OU is correct → mass retry cleanup via web UI (select all → Retry Cleanup)
4. If OU drift → move accounts back:
   ```bash
   # See docs/troubleshooting/FIX-QUARANTINE-ACCOUNTS.md for bulk fix
   ```

---

## Scenario 4: AWS Nuke Cleanup Failures (P2)

**Symptoms:** Accounts stuck in CleanUp, never return to Available.

**Steps:**
1. Check CodeBuild logs:
   ```bash
   aws codebuild list-builds-for-project --project-name AccountCleanerCodeBuildClea-FJkuoq69GCNf \
     --profile eta-isb-andrian --region ap-southeast-1 --query "ids[0:5]"
   ```
2. Get failure details:
   ```bash
   aws codebuild batch-get-builds --ids <build-id> \
     --profile eta-isb-andrian --region ap-southeast-1 \
     --query "builds[0].{Status:buildStatus,Phase:currentPhase,Logs:logs.deepLink}"
   ```
3. Common fixes:
   - **Resource filter needed** → update AppConfig nuke config
   - **Region not enabled** → enable region on account
   - **Service not supported** → add filter to nuke config
4. After fixing config, retry via web UI

---

## Scenario 5: Rate Limiter Stuck (P3)

**Symptoms:** Account throttled but won't auto-recover.

**Steps:**
1. Check throttle state:
   ```bash
   ./scripts/cost-controls/list-throttled-accounts.sh
   ```
2. Manual unfreeze:
   ```bash
   ./scripts/cost-controls/unfreeze-bedrock.sh <account-id>
   ```
3. If SCP still attached (recovery Lambda failed):
   ```bash
   # List SCPs on account
   aws organizations list-policies-for-target --target-id <account-id> \
     --filter SERVICE_CONTROL_POLICY --profile eta-andrian \
     --query "Policies[?contains(Name,'bedrock-deny')]"
   
   # Manual detach + delete
   aws organizations detach-policy --policy-id <policy-id> --target-id <account-id> --profile eta-andrian
   aws organizations delete-policy --policy-id <policy-id> --profile eta-andrian
   ```

---

## Scenario 6: SSO/IDC Broken (P2)

**Symptoms:** Users can't login, SSO portal returns error.

**Steps:**
1. Check IDC instance:
   ```bash
   aws sso-admin list-instances --profile eta-andrian --region ap-southeast-1
   ```
2. Check if ISB permission sets still exist:
   ```bash
   aws sso-admin list-permission-sets --instance-arn arn:aws:sso:::instance/ssoins-821055714a3e49c5 \
     --profile eta-andrian --region ap-southeast-1
   ```
3. If SCIM sync broken (Google Workspace):
   - Check SCIM provisioning status in Google Admin
   - Verify SAML certificate not expired
   - Re-provision if needed: redeploy IDC stack
4. Temporary workaround: assign users directly via console

---

## Scenario 7: Cost Explosion (P1)

**Symptoms:** Budget alerts firing, unexpected $100+ charges.

**Immediate Actions (execute in order):**
1. **Kill-switch** — freeze ALL sandbox Bedrock:
   ```bash
   ./scripts/cost-controls/kill-switch-bedrock.sh
   ```
2. **Check which account** is responsible:
   ```bash
   # Cost Explorer (last 24h by linked account)
   aws ce get-cost-and-usage --time-period Start=2026-07-02,End=2026-07-03 \
     --granularity DAILY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
     --profile eta-andrian --region us-east-1
   ```
3. **Terminate offending leases** via web UI
4. **Investigate** root cause:
   ```bash
   ./scripts/cost-controls/check-bedrock-incident.sh <account-id>
   ```
5. After investigation → unfreeze non-offending accounts:
   ```bash
   ./scripts/cost-controls/unfreeze-bedrock.sh <good-account-id>
   ```

---

## Scenario 8: CloudFront/WAF Blocking Legitimate Traffic (P2)

**Symptoms:** Users get 403 from WAF, "RequestHeaderSectionTooLarge".

**Steps:**
1. Check WAF logs (if enabled)
2. Common causes:
   - SAML response too large → minimize attributes in IdP
   - Pagination tokens blocked → update WAF rule SizeRestrictions
3. Temporary fix: add user's IP to WAF allow list
4. Permanent fix: adjust WAF rules in Compute stack

---

## Recovery Checklist — After Any P1/P2 Incident

```
□ Root cause identified and documented (docs/incidents/)
□ Fix applied (config change, code fix, or infrastructure update)
□ Monitoring verified (dashboard shows healthy)
□ Active leases verified (all users can access their accounts)
□ Pool health checked (Available accounts > 10)
□ Stakeholders notified (if user-facing impact > 5 min)
□ Post-mortem written (if impact > 30 min)
```

---

## Key Contacts

| Role | Contact | Method |
|------|---------|--------|
| ISB Admin | andrian@eliteacademy.id | Email, Slack |
| AWS Support | Console → Support Center | Critical: phone callback |
| ISB Upstream | github.com/aws-solutions/innovation-sandbox-on-aws | GitHub issues |

## Key Resources

| Resource | Location |
|----------|----------|
| CloudWatch Dashboard | [ISB-Operations-myisb](https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards/dashboard/ISB-Operations-myisb) |
| Web UI | https://aws-sandbox.eliteacademy.id |
| SSO Portal | https://d-9667a833b5.awsapps.com/start |
| Hub Console | https://ap-southeast-1.console.aws.amazon.com/console/home?region=ap-southeast-1 (account 147826551593) |
| Mgmt Console | (account 862099794180) |
| Lessons Learned | docs/LESSONS-LEARNED.md |
| Cost Controls README | scripts/cost-controls/README.md |
