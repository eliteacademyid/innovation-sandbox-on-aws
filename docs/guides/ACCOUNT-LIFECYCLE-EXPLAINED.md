# 🔄 Innovation Sandbox Account Lifecycle - Complete Explanation

## Overview

Innovation Sandbox accounts go through a **circular lifecycle** where they are created, cleaned, leased to users, and then recycled back into the pool for reuse.

---

## 📊 Account States

| State | Description | Duration | Next State |
|-------|-------------|----------|------------|
| **Entry** | New account in Entry OU, not yet registered | Manual | CleanUp (after registration) |
| **CleanUp** | Being cleaned by AWS Nuke | 10-15 minutes | Available or Quarantine |
| **Available** | Ready to be leased to users | Until leased | Active |
| **Active** | Currently leased to a user | Lease duration (e.g., 48 hours) | CleanUp |
| **Quarantine** | Cleanup failed, needs manual intervention | Until fixed | CleanUp (after fix) |
| **Frozen** | Temporarily suspended by admin | Until unfrozen | Previous state |

---

## 🔄 Complete Lifecycle Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    ACCOUNT LIFECYCLE                             │
└─────────────────────────────────────────────────────────────────┘

1. CREATE ACCOUNT (AWS Organizations)
   │
   ├─→ Account created in AWS Organizations
   │   Account ID: 123456789012
   │   Name: ISB-Sandbox-01
   │   Email: isb-sandbox-01@example.com
   │
   ↓

2. MOVE TO ENTRY OU
   │
   ├─→ Account moved to Entry OU (ou-e21c-cz4ntm1j)
   │   State: Entry
   │   Status: Not yet registered to ISB pool
   │
   ↓

3. REGISTER TO ISB POOL
   │
   ├─→ Account registered via ISB web UI or API
   │   State: Entry → CleanUp
   │   Trigger: AWS Step Functions workflow
   │
   ↓

4. FIRST CLEANUP (Initial)
   │
   ├─→ AWS Nuke removes all resources
   │   State: CleanUp
   │   Duration: 10-15 minutes
   │   Process:
   │   • CodeBuild job starts
   │   • AWS Nuke scans account
   │   • Deletes all resources (EC2, S3, Lambda, etc.)
   │   • Respects filters (keeps org-managed resources)
   │
   ├─→ SUCCESS → Available
   │   OR
   └─→ FAILURE → Quarantine
       │
       ├─→ Fix: Update AWS Nuke config
       │   Retry cleanup
       │
       └─→ Back to CleanUp

   ⚠️ DRIFT DETECTION (Parallel Process)
   │
   ├─→ Drift monitor Lambda checks account OU location
   │   Runs periodically (every few minutes)
   │   
   ├─→ IF account in wrong OU (not Entry or Sandbox OU)
   │   State: Any → Quarantine (BYPASSES cleanup)
   │   
   └─→ Fix: Move account back to correct OU
       Retry cleanup
       Back to CleanUp

5. AVAILABLE STATE
   │
   ├─→ Account ready to be leased
   │   State: Available
   │   Duration: Until a user requests it
   │   Waiting in pool for assignment
   │
   ↓

6. LEASE ASSIGNMENT
   │
   ├─→ User requests sandbox (or admin assigns)
   │   State: Available → Active
   │   Process:
   │   • Lease created in DynamoDB
   │   • Account assigned to user
   │   • Blueprint deployed (if configured)
   │   • User receives email with credentials
   │   • Budget alarm created ($10 limit)
   │   • Lease timer starts (48 hours)
   │
   ↓

7. ACTIVE STATE (User Working)
   │
   ├─→ User has full access to account
   │   State: Active
   │   Duration: Lease duration (e.g., 48 hours)
   │   User can:
   │   • Create resources (EC2, S3, Lambda, etc.)
   │   • Deploy applications
   │   • Run experiments
   │   • Use GenAI services
   │   
   │   Constraints:
   │   • Budget limit: $10
   │   • Time limit: 48 hours
   │   • Cannot modify org-managed resources
   │
   ↓

8. LEASE EXPIRATION
   │
   ├─→ Lease duration ends (48 hours)
   │   OR
   ├─→ User manually terminates lease
   │   OR
   └─→ Admin terminates lease
       │
       State: Active → CleanUp
       Process:
       • Lease marked as expired
       • User access revoked
       • Cleanup workflow triggered
       │
       ↓

9. RECYCLING CLEANUP
   │
   ├─→ AWS Nuke removes all user resources
   │   State: CleanUp
   │   Duration: 10-15 minutes
   │   Process:
   │   • CodeBuild job starts
   │   • AWS Nuke scans account
   │   • Deletes all resources created by user
   │   • Account reset to clean state
   │
   ├─→ SUCCESS → Available (back to step 5)
   │   OR
   └─→ FAILURE → Quarantine
       │
       ├─→ Fix: Update AWS Nuke config
       │   Retry cleanup
       │
       └─→ Back to CleanUp

10. CYCLE REPEATS
    │
    └─→ Account returns to Available pool
        Ready for next user
        Cycle continues indefinitely
```

---

## 🎯 Detailed State Explanations

### 1. **Entry State**

**What it means:**
- Account exists in AWS Organizations
- Located in Entry OU (ou-e21c-cz4ntm1j)
- Not yet registered to Innovation Sandbox pool
- Not visible in ISB web UI

**How to get here:**
- Create account via AWS Organizations
- Move account to Entry OU

**How to leave:**
- Register account via ISB web UI or API
- Automatically moves to CleanUp state

**Duration:** Manual (until admin registers it)

---

### 2. **CleanUp State**

**What it means:**
- Account is being cleaned by AWS Nuke
- All resources are being deleted
- CodeBuild job is running
- Cannot be leased during cleanup

**What happens:**
1. **Step Functions workflow starts**
   - Execution ARN: `arn:aws:states:ap-southeast-3:147826551593:execution:...`

2. **CodeBuild job launches**
   - Project: `InnovationSandbox-Compute-AccountCleanerCodeBuildProject...`
   - Container: AWS Nuke Docker image
   - Timeout: 60 minutes

3. **AWS Nuke scans account**
   - Lists all resources in all regions
   - Applies filters from AppConfig
   - Identifies resources to delete

4. **Resources deleted**
   - EC2 instances, volumes, snapshots
   - S3 buckets and objects
   - Lambda functions
   - RDS databases
   - DynamoDB tables
   - IAM roles, policies, users
   - VPCs, subnets, security groups
   - CloudFormation stacks
   - And 150+ other resource types

5. **Verification**
   - Confirms all resources deleted
   - Checks for any remaining resources
   - Logs results to CloudWatch

**Duration:** 10-15 minutes (typical)

**Success → Available**  
**Failure → Quarantine**

**Common reasons for failure:**
- Organization-managed resources (can't be deleted)
- Resources with deletion protection
- Resources with dependencies
- IAM roles in use
- CloudTrail trails
- SecurityHub hubs
- GuardDuty detectors

---

### 3. **Available State**

**What it means:**
- Account is clean and ready to use
- Waiting in pool for lease assignment
- Visible in ISB web UI as "Available"
- Can be leased immediately

**What's in the account:**
- No user resources (all cleaned)
- Only organization-managed resources:
  - OrganizationAccountAccessRole (for admin access)
  - AWSServiceRoleFor* (AWS service-linked roles)
  - Organization CloudTrail (if configured)
  - Organization Config (if configured)
  - Organization SecurityHub (if configured)

**How to leave:**
- User requests sandbox
- Admin assigns lease
- Automatically moves to Active state

**Duration:** Until leased (can be minutes, hours, or days)

---

### 4. **Active State**

**What it means:**
- Account is leased to a user
- User has full access
- Lease timer is running
- Budget alarm is active

**What the user can do:**
- Sign in to AWS Console
- Create any AWS resources
- Deploy applications
- Run experiments
- Use AWS CLI/SDK
- Access GenAI services (if blueprint deployed)

**What the user CANNOT do:**
- Modify organization-managed resources
- Delete OrganizationAccountAccessRole
- Disable CloudTrail (if org trail)
- Leave AWS Organizations
- Exceed budget limit ($10)
- Extend lease beyond duration (48 hours)

**Lease details stored in DynamoDB:**
```json
{
  "leaseUuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "accountId": "123456789012",
  "userEmail": "user@example.com",
  "leaseTemplateUuid": "f25bc776-52a1-42d9-b045-b3873074cec0",
  "startTime": "2026-05-01T10:00:00Z",
  "endTime": "2026-05-03T10:00:00Z",
  "budgetLimit": 10,
  "status": "Active"
}
```

**Monitoring:**
- Budget alarm: Alerts at 80% and 100% of $10
- Lease timer: Counts down to expiration
- CloudWatch Logs: All API calls logged
- Cost Explorer: Tracks spending

**Duration:** Lease duration (e.g., 48 hours)

**How to leave:**
- Lease expires (automatic)
- User terminates lease (manual)
- Admin terminates lease (manual)
- Budget exceeded (automatic termination)

---

### 5. **Quarantine State**

**What it means:**
- Cleanup failed OR OU drift detected
- Account has resources that couldn't be deleted OR account moved to wrong OU
- Requires manual intervention
- Cannot be leased until fixed

**Why accounts go to Quarantine:**

1. **OU Drift Detection (bypasses cleanup)**
   - Account moved to wrong OU (not in Entry OU or Sandbox OU)
   - Drift monitor Lambda detects location mismatch
   - Account goes DIRECTLY to Quarantine (skips cleanup)
   - Must be moved back to correct OU before retry

2. **Cleanup Failures (during cleanup process)**
   
   a. **Organization-managed resources**
      - CloudTrail trails (organization trail)
      - SecurityHub hubs (organization hub)
      - GuardDuty detectors (organization detector)
      - Config recorders (organization config)
      - IAM roles (AWSServiceRoleFor*)

   b. **Resources with deletion protection**
      - RDS databases with deletion protection
      - DynamoDB tables with deletion protection
      - S3 buckets with object lock

   c. **Resources with dependencies**
      - VPCs with attached resources
      - Security groups in use
      - IAM roles attached to resources

3. **AWS Nuke configuration issues**
   - Missing filters for protected resources
   - Incorrect resource type names
   - Region not enabled

4. **Unexpected failures**
   - API throttling during cleanup
   - Service outages
   - Permission issues

**How to fix:**

**For OU Drift (account in wrong OU):**

1. **Check account location**
   ```bash
   aws organizations list-parents \
     --child-id 123456789012 \
     --profile elite-academy
   ```

2. **Move account back to Entry OU**
   ```bash
   aws organizations move-account \
     --account-id 123456789012 \
     --source-parent-id ou-xxxx-xxxxxxxx \
     --destination-parent-id ou-e21c-cz4ntm1j \
     --profile elite-academy
   ```

3. **Retry cleanup**
   - ISB web UI → Select account
   - Actions → Retry cleanup
   - Account moves back to CleanUp state

**For Cleanup Failures (resources couldn't be deleted):**

1. **Check CloudWatch Logs**
   - Find which resources failed to delete
   - Note the resource types

2. **Update AWS Nuke config**
   - Add filters for failed resource types
   - Example:
     ```yaml
     accounts:
       "*":
         filters:
           IAMRole:
             - type: "glob"
               value: "AWSServiceRoleFor*"
           CloudTrailTrail:
             - type: "glob"
               value: "*"
     ```

3. **Deploy new config**
   - AppConfig → Create new version
   - Deploy to environment

4. **Retry cleanup**
   - ISB web UI → Select account
   - Actions → Retry cleanup
   - Account moves back to CleanUp state

**Duration:** Until fixed (manual intervention required)

---

### 6. **Frozen State**

**What it means:**
- Account temporarily suspended by admin
- User access blocked
- Lease timer paused
- Resources remain intact

**Why freeze an account:**
- Security incident investigation
- Budget exceeded (manual freeze)
- Policy violation
- Suspicious activity
- Maintenance required

**What happens:**
- User cannot access account
- Lease timer paused
- Resources not deleted
- Account not cleaned

**How to unfreeze:**
- Admin unfreezes via web UI
- Account returns to previous state (usually Active)
- Lease timer resumes

**Duration:** Until admin unfreezes (manual)

---

## 🔄 Lifecycle Examples

### Example 1: Normal Lifecycle (Happy Path)

```
Day 1, 09:00 - Account created
   State: Entry
   Action: Admin creates account in AWS Organizations

Day 1, 09:05 - Account moved to Entry OU
   State: Entry
   Action: Admin moves account to ou-e21c-cz4ntm1j

Day 1, 09:10 - Account registered
   State: Entry → CleanUp
   Action: Admin registers via ISB web UI

Day 1, 09:25 - Cleanup complete
   State: CleanUp → Available
   Duration: 15 minutes
   Result: Account clean and ready

Day 1, 10:00 - User requests sandbox
   State: Available → Active
   Action: User clicks "Request Sandbox"
   Lease: 48 hours, $10 budget

Day 1-3, 10:00-10:00 - User working
   State: Active
   Duration: 48 hours
   User creates: EC2, S3, Lambda, RDS

Day 3, 10:00 - Lease expires
   State: Active → CleanUp
   Action: Automatic lease expiration
   User access revoked

Day 3, 10:15 - Cleanup complete
   State: CleanUp → Available
   Duration: 15 minutes
   Result: All user resources deleted

Day 3, 11:00 - Next user requests sandbox
   State: Available → Active
   Cycle repeats...
```

### Example 2: Quarantine Due to OU Drift

```
Day 1, 09:00 - Account registered
   State: Entry → CleanUp

Day 1, 09:05 - Admin accidentally moves account to wrong OU
   Action: Account moved to "Sandbox-Test" OU (not Entry or Sandbox OU)

Day 1, 09:06 - Drift monitor detects OU mismatch
   State: CleanUp → Quarantine (BYPASSES cleanup)
   Reason: Account in wrong OU

Day 1, 09:10 - Admin investigates
   Action: Check account location
   Finding: Account in "Sandbox-Test" OU instead of Entry OU

Day 1, 09:15 - Admin moves account back
   Action: Move account to Entry OU (ou-e21c-cz4ntm1j)

Day 1, 09:20 - Admin retries cleanup
   State: Quarantine → CleanUp
   Action: Retry cleanup via web UI

Day 1, 09:35 - Cleanup succeeds
   State: CleanUp → Available
   Result: Account ready for use
```

### Example 3: Quarantine Due to Cleanup Failure

```
Day 1, 09:00 - Account registered
   State: Entry → CleanUp

Day 1, 09:15 - Cleanup fails
   State: CleanUp → Quarantine
   Reason: CloudTrail trail couldn't be deleted

Day 1, 09:20 - Admin investigates
   Action: Check CloudWatch Logs
   Finding: Organization CloudTrail trail

Day 1, 09:25 - Admin updates config
   Action: Add CloudTrailTrail filter to AWS Nuke config
   Deploy: New AppConfig version

Day 1, 09:30 - Admin retries cleanup
   State: Quarantine → CleanUp
   Action: Retry cleanup via web UI

Day 1, 09:45 - Cleanup succeeds
   State: CleanUp → Available
   Result: Account ready for use
```

### Example 3: Multiple Leases (Account Reuse)

```
Week 1:
   User A: 48 hours → CleanUp → Available
   User B: 48 hours → CleanUp → Available
   User C: 48 hours → CleanUp → Available

Week 2:
   User D: 48 hours → CleanUp → Available
   User E: 48 hours → CleanUp → Available

Total: 5 users, 1 account, 10 days
```

---

## 📊 State Transitions Summary

| From State | To State | Trigger | Duration |
|------------|----------|---------|----------|
| Entry | CleanUp | Register account | Immediate |
| CleanUp | Available | Cleanup succeeds | 10-15 min |
| CleanUp | Quarantine | Cleanup fails | 10-15 min |
| **Any** | **Quarantine** | **OU drift detected** | **Immediate** |
| Available | Active | Lease assigned | Immediate |
| Active | CleanUp | Lease expires | Immediate |
| Quarantine | CleanUp | Retry cleanup (after fix) | Immediate |
| Any | Frozen | Admin freezes | Immediate |
| Frozen | Previous | Admin unfreezes | Immediate |

**Note:** OU drift detection can move an account to Quarantine from ANY state, bypassing the normal cleanup process.

---

## 🎯 Key Concepts

### 1. **Account Pool**
- Collection of Available accounts
- Ready to be leased immediately
- Size: 31 accounts (in your case)
- Goal: Always have Available accounts for users

### 2. **Lease**
- Temporary assignment of account to user
- Duration: Configurable (e.g., 48 hours)
- Budget: Configurable (e.g., $10)
- Blueprint: Optional CloudFormation StackSet

### 3. **Lease Template**
- Defines lease parameters:
  - Duration (e.g., 48 hours)
  - Budget (e.g., $10)
  - Blueprint (e.g., cendekiawan-genai)
  - Regions (e.g., ap-southeast-3)
- Reusable configuration
- Example: "Cendekiawan ToT GenAI"

### 4. **Blueprint**
- CloudFormation StackSet
- Deployed when lease is assigned
- Pre-configures account with resources
- Example: GenAI services, IAM roles, S3 buckets

### 5. **AWS Nuke**
- Open-source tool for deleting AWS resources
- Runs in CodeBuild container
- Configured via AppConfig
- Filters protect organization-managed resources

### 6. **Cleanup Workflow**
- AWS Step Functions state machine
- Orchestrates cleanup process
- Triggers CodeBuild job
- Updates account status in DynamoDB

---

## 🔍 Monitoring the Lifecycle

### Via Web UI:
```
https://d1nu7n93cpbse4.cloudfront.net
Administration → Accounts
```

**View:**
- Account name and ID
- Current state
- Last state change time
- Lease information (if Active)

### Via API:
```bash
curl -H "Authorization: Bearer $JWT_TOKEN" \
  https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod/accounts
```

### Via CloudWatch:
```
Log Group: InnovationSandbox-Compute-ISBLogGroupE607F9A7-xO8Eo5n6uPSL
Saved Query: AccountCleanupLogs
```

### Via DynamoDB:
```
Table: InnovationSandbox-Data-SandboxAccountTableEFB9C069-VUMV43OSS94
```

---

## 💡 Best Practices

### 1. **Right-Size Your Pool**
- Formula: Pool size = 1.3 × concurrent users
- Example: 23 users → 30 accounts (you have 31 ✅)
- Buffer accounts for cleanup time

### 2. **Monitor Quarantine Accounts**
- Check daily for Quarantine accounts
- Fix AWS Nuke config proactively
- Common filters needed:
  - IAMRole: AWSServiceRoleFor*
  - CloudTrailTrail: *
  - SecurityHubHub: *
  - GuardDutyDetector: *

### 3. **Set Appropriate Lease Durations**
- Short workshops: 4-8 hours
- Training programs: 24-48 hours
- Development: 7 days
- Long-term: 30 days

### 4. **Configure Budget Alarms**
- Set realistic budgets
- Alert at 80% and 100%
- Automatic termination at 100%

### 5. **Use Blueprints**
- Pre-configure accounts
- Reduce user setup time
- Ensure consistency
- Include necessary IAM roles

---

## 🚀 Lifecycle Optimization

### Parallel Cleanup
- Multiple accounts clean simultaneously
- Limited by CodeBuild concurrent builds
- Default: 5 concurrent builds
- Request increase for large pools (100+ accounts)

### Cleanup Time Reduction
- Optimize AWS Nuke filters
- Exclude unnecessary resource types
- Use specific filters (not wildcards)
- Enable only needed regions

### Pool Management
- Maintain buffer of Available accounts
- Monitor pool utilization
- Scale pool size based on demand
- Automate account creation (if needed)

---

## 📊 Your Current Situation

### Account Distribution:
- **Total accounts:** 31
- **In CleanUp:** 31 (currently)
- **Expected Available:** 31 (in 10-15 minutes)
- **Will be Active:** 23 (after lease assignment)
- **Will remain Available:** 8 (buffer)

### Lifecycle Flow for Your Accounts:
```
Now:        31 accounts in CleanUp
+15 min:    31 accounts Available
+20 min:    23 accounts Active (leased)
            8 accounts Available (buffer)
+48 hours:  23 accounts CleanUp (lease expired)
            8 accounts Available (buffer)
+48h+15m:   31 accounts Available (ready for reuse)
```

---

## 🎯 Summary

**Account lifecycle is circular:**
1. **Create** → Entry OU
2. **Register** → CleanUp (first time)
3. **Clean** → Available
4. **Lease** → Active (user working)
5. **Expire** → CleanUp (recycling)
6. **Clean** → Available (ready for next user)
7. **Repeat** steps 4-6 indefinitely

**Key points:**
- ✅ Accounts are reused (not deleted)
- ✅ Cleanup happens automatically
- ✅ Users get clean accounts every time
- ✅ Pool size determines concurrent users
- ✅ Lifecycle is fully automated

**Your accounts are currently in step 2-3** (first cleanup after registration). Once they reach "Available", they'll be ready for step 4 (lease assignment). 🚀
