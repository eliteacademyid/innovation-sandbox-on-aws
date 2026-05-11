# 🔧 Fix Quarantine Accounts

## 🎯 Goal:
Fix all Quarantine accounts so they become Available for leasing.

## ⚠️ Two Types of Quarantine Issues:

1. **OU Drift** - Account moved to wrong OU (bypasses cleanup, goes straight to Quarantine)
2. **Cleanup Failure** - Resources couldn't be deleted during cleanup process

**IMPORTANT:** Check for OU drift FIRST before investigating cleanup failures!

---

## 📋 STEP 0: Check for OU Drift (DO THIS FIRST!)

**OU drift is the most common cause of Quarantine status.** If an account is in the wrong OU, it will go straight to Quarantine without attempting cleanup.

### Check All Quarantine Accounts' OU Location:

```bash
# Get list of all accounts in Quarantine (from ISB web UI)
# Then check each account's OU location

# Check single account
aws organizations list-parents \
    --child-id ACCOUNT_ID \
    --profile elite-academy \
    --region ap-southeast-3

# Expected OU: ou-e21c-cz4ntm1j (Entry OU)
# If account is in a different OU, that's the problem!
```

### If Account is in Wrong OU:

**Fix: Move account back to Entry OU**

```bash
# Move account back to Entry OU
aws organizations move-account \
    --account-id ACCOUNT_ID \
    --source-parent-id CURRENT_OU_ID \
    --destination-parent-id ou-e21c-cz4ntm1j \
    --profile elite-academy \
    --region ap-southeast-3
```

**Then retry cleanup:**
1. Go to ISB web UI: https://d1nu7n93cpbse4.cloudfront.net
2. Administration → Accounts
3. Select the account
4. Actions → Retry cleanup
5. Account should move to CleanUp and then Available

### Check All 31 Accounts at Once:

```bash
# List all ISB-Sandbox accounts and their OU locations
aws organizations list-accounts \
    --profile elite-academy \
    --region ap-southeast-3 \
    --output json | jq -r '.Accounts[] | select(.Name | startswith("ISB-Sandbox")) | .Id' | while read account_id; do
    ou_id=$(aws organizations list-parents --child-id $account_id --profile elite-academy --region ap-southeast-3 --output json | jq -r '.Parents[0].Id')
    account_name=$(aws organizations describe-account --account-id $account_id --profile elite-academy --region ap-southeast-3 --output json | jq -r '.Account.Name')
    echo "$account_name ($account_id): $ou_id"
done
```

**Expected OU:** `ou-e21c-cz4ntm1j` (Entry OU)

**If any accounts are in a different OU, move them back!**

---

## 📋 STEP 1: If NOT OU Drift, Find What Resources Failed to Clean Up

1. **Go to Step Functions console** (Hub account 147826551593):
   ```
   https://ap-southeast-3.console.aws.amazon.com/states/home?region=ap-southeast-3
   ```

2. **Find the State Machine:**
   - Look for: `AccountCleanerStepFunctionStateMachine...`
   - Click on it

3. **Find Failed Executions:**
   - Look for executions with **"Failed"** status
   - Click on one of them

4. **Copy the Execution ID:**
   - From the Details tab, copy the executionId
   - Format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

---

### Step 2: Check CloudWatch Logs (Only if NOT OU Drift)

1. **Go to CloudWatch Logs Insights:**
   ```
   https://ap-southeast-3.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-3#logsV2:logs-insights
   ```

2. **Use Saved Query:**
   - Click **"Saved and sample queries"** (right side)
   - Expand **"ISB-myisb"**
   - Click **"AccountCleanupLogs"**

3. **Run Query:**
   - Replace `PasteStateMachineExecutionIdHere` with your execution ID
   - Adjust time range to include the failure time
   - Click **"Run query"**

4. **Note Failed Resources:**
   - Look at the **resourceType** column
   - Common failures:
     - `AWS::CloudTrail::Trail`
     - `AWS::SecurityHub::Hub`
     - `AWS::GuardDuty::Detector`
     - `AWS::IAM::Role` (organization-managed)

---

### Step 3: Update AWS Nuke Config (Only for Cleanup Failures)

1. **Go to AppConfig:**
   ```
   https://ap-southeast-3.console.aws.amazon.com/systems-manager/appconfig/applications?region=ap-southeast-3
   ```

2. **Open Application:**
   - Click: `InnovationSandboxData-Config-Application...`

3. **Open Config Profile:**
   - Click: `InnovationSandboxData-Config-NukeConfigHostedConfiguration...`

4. **Create New Version:**
   - Click **"Create version"**

5. **Add Filters:**
   
   Example filters to add (based on common issues):
   
   ```yaml
   accounts:
     "*":
       filters:
         # Existing filters...
         
         # Add these to ignore organization-managed resources:
         IAMRole:
           - type: "glob"
             value: "AWSServiceRoleFor*"
           - type: "glob"
             value: "OrganizationAccountAccessRole"
         
         CloudTrailTrail:
           - type: "glob"
             value: "*"
         
         SecurityHubHub:
           - type: "glob"
             value: "*"
         
         GuardDutyDetector:
           - type: "glob"
             value: "*"
   ```

6. **Save:**
   - Click **"Create hosted configuration version"**

7. **Deploy:**
   - Click **"Start deployment"**
   - Select deployment strategy
   - Click **"Start deployment"**

---

### Step 4: Retry Cleanup

1. **Go to ISB Web UI:**
   ```
   https://d1nu7n93cpbse4.cloudfront.net
   ```

2. **Go to Accounts:**
   - Administration → Accounts

3. **Select Quarantine Accounts:**
   - Select all 7 accounts with "Quarantine" status

4. **Retry Cleanup:**
   - Click **"Actions"** → **"Retry cleanup"**

5. **Wait:**
   - Accounts will move to "CleanUp" status
   - Wait 10-15 minutes
   - They should become "Available"

---

## ⚡ Quick Fix Guide

### Fix Type 1: OU Drift (Most Common - Check This First!)

**Symptoms:**
- Account went to Quarantine immediately after registration
- No cleanup attempt was made
- Drift monitor Lambda detected OU mismatch

**Quick Fix:**
```bash
# 1. Check account OU location
aws organizations list-parents \
    --child-id ACCOUNT_ID \
    --profile elite-academy \
    --region ap-southeast-3

# 2. If not in Entry OU (ou-e21c-cz4ntm1j), move it back
aws organizations move-account \
    --account-id ACCOUNT_ID \
    --source-parent-id CURRENT_OU_ID \
    --destination-parent-id ou-e21c-cz4ntm1j \
    --profile elite-academy \
    --region ap-southeast-3

# 3. Retry cleanup via ISB web UI
# Administration → Accounts → Select account → Actions → Retry cleanup
```

**Duration:** 5 minutes + 10-15 minutes cleanup

---

### Fix Type 2: Cleanup Failure (Less Common)

**Symptoms:**
- Account went to Quarantine after cleanup attempt
- Cleanup process started but failed
- CloudWatch Logs show resource deletion errors

**Quick Fix:**

If you already know the resources causing issues (e.g., CloudTrail), you can skip Step 1-2 and go directly to Step 3 to add filters.

### Common Filters to Add:

```yaml
accounts:
  "*":
    filters:
      # Organization-managed IAM roles
      IAMRole:
        - type: "glob"
          value: "AWSServiceRoleFor*"
        - type: "glob"
          value: "OrganizationAccountAccessRole"
      
      # CloudTrail (if organization trail exists)
      CloudTrailTrail:
        - type: "glob"
          value: "*"
      
      # Security Hub
      SecurityHubHub:
        - type: "glob"
          value: "*"
      
      # GuardDuty
      GuardDutyDetector:
        - type: "glob"
          value: "*"
      
      # Config
      ConfigConfigurationRecorder:
        - type: "glob"
          value: "*"
      
      ConfigDeliveryChannel:
        - type: "glob"
          value: "*"
```

---

## 🎯 Expected Result:

After fixing and retrying:
- **Quarantine:** 0
- **Clean Up:** 10 (temporarily)
- **Available:** 10 (after cleanup completes)

Then you'll have 10 accounts ready for leasing!

---

## 📊 Current Situation:

You have 10 accounts registered, but need to:
1. Fix 7 Quarantine accounts
2. Wait for 3 Clean Up accounts to finish
3. Register the remaining 21 accounts (31 total - 10 already registered)

---

## 🚀 Next Steps:

1. **Fix Quarantine accounts** (this guide)
2. **Wait for all 10 to become Available**
3. **Register remaining 21 accounts** via web UI
4. **Wait for cleanup**
5. **You'll have 31 Available accounts!**
6. **Assign leases to 23 participants**

---

**Start here:** Step Functions console to find failed resources
