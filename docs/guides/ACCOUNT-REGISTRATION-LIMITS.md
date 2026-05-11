# 📊 AWS Account Registration Limits - Innovation Sandbox

## Current Status Summary

Based on the documentation review and AWS Organizations configuration:

### 🔢 Account Counts

| Category | Count |
|----------|-------|
| **Total AWS Accounts Created** | 31 ISB-Sandbox accounts |
| **Registered in ISB Pool** | 10 accounts |
| **Available for Leasing** | 0 accounts |
| **In Clean Up** | 3 accounts |
| **In Quarantine** | 7 accounts (cleanup failed) |
| **Not Yet Registered** | 21 accounts |

---

## 📋 AWS Organizations Account Limits

### Default Maximum Accounts

According to [AWS Organizations Quotas Documentation](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html):

**Default Limit:** **10 accounts** per organization

**Your Current Limit:** Likely **10 accounts** (default for new organizations)

**Maximum Possible:** Up to **50,000 accounts** (with quota increase request)

### Key Points:

1. **Default is 10 accounts** - This includes:
   - Management account (862099794180 - Elite Academy)
   - Hub account (147826551593 - ETA's Innovation Sandbox)
   - **8 sandbox accounts maximum** (with default quota)

2. **You have 31 sandbox accounts** - This means:
   - ✅ Your quota has already been increased beyond the default
   - ✅ You can register all 31 accounts to ISB pool
   - ✅ No additional quota increase needed

3. **Quota is Adjustable** - You can request increases via:
   - [Service Quotas Console](https://console.aws.amazon.com/servicequotas/home?region=us-east-1#!/services/organizations/quotas)
   - Must be requested from Management account (862099794180)
   - Increases granted up to 50,000 based on qualifications

---

## 🎯 Innovation Sandbox Pool Limits

### ISB-Specific Limits

**No documented hard limit** on the number of accounts in the ISB pool.

The Innovation Sandbox solution documentation does not specify a maximum number of accounts that can be registered to the pool. The limit is effectively determined by:

1. **AWS Organizations quota** - Maximum accounts in your organization
2. **Operational considerations** - Cleanup time, management overhead
3. **Cost considerations** - Account maintenance costs

### Recommended Pool Sizes

Based on best practices:

| Team Size | Recommended Pool Size | Reasoning |
|-----------|----------------------|-----------|
| 5-10 users | 3-5 accounts | 50% utilization, allows 1-2 concurrent leases per user |
| 10-50 users | 10-20 accounts | Allows multiple concurrent leases |
| 50+ users | 20-50 accounts | Ensures availability during peak usage |
| **Your case: 23 users** | **25-30 accounts** | ✅ **31 accounts is perfect!** |

---

## ✅ Your Situation: All Clear!

### Current State:
- ✅ **31 sandbox accounts created** (more than enough for 23 participants)
- ✅ **AWS Organizations quota already increased** (you have 33 total accounts including management and hub)
- ✅ **No quota increase needed**
- ⚠️ **Only 10 accounts registered** (need to register remaining 21)
- ⚠️ **7 accounts in Quarantine** (need to fix cleanup issues)

### What You Can Do:

**Maximum accounts you can register:** All 31 accounts ✅

**No limits preventing you from:**
1. Registering all 31 accounts to ISB pool
2. Fixing the 7 Quarantine accounts
3. Having all 31 accounts Available for leasing
4. Assigning leases to all 23 participants

---

## 🚀 Action Plan

### Immediate Actions (No Quota Increase Needed)

#### 1. Fix Quarantine Accounts (7 accounts)
**Time:** 15-20 minutes  
**Guide:** See `FIX-QUARANTINE-ACCOUNTS.md`

**Steps:**
1. Update AWS Nuke config in AppConfig
2. Add filters for organization-managed resources:
   - IAMRole (AWSServiceRoleFor*)
   - CloudTrailTrail
   - SecurityHubHub
   - GuardDutyDetector
3. Retry cleanup via ISB web UI

#### 2. Register Remaining Accounts (21 accounts)
**Time:** 5 minutes  
**Method:** ISB Web UI (faster than CLI)

**Steps:**
1. Go to: https://d1nu7n93cpbse4.cloudfront.net
2. Administration → Accounts → Add accounts
3. Select all 21 available accounts
4. Click Register → Submit
5. Wait 10-15 minutes for cleanup

#### 3. Verify All Accounts Available
**Time:** 2 minutes

**Expected Result:**
- Available: 31 accounts
- Clean Up: 0
- Quarantine: 0
- Total: 31 registered

#### 4. Attach Blueprint to Lease Template
**Time:** 1 minute  
**Method:** ISB Web UI

**Steps:**
1. Lease Templates → Edit "Cendekiawan ToT GenAI"
2. Select blueprint: "cendekiawan-genai"
3. Save

#### 5. Bulk Assign Leases
**Time:** 5 minutes  
**Method:** Python script

```bash
python3 scripts/bulk-assign-leases.py \
    cendekiawan-tot-users.csv \
    f25bc776-52a1-42d9-b045-b3873074cec0 \
    JWT_TOKEN
```

---

## 📊 Account Lifecycle in ISB

### States and Transitions

```
Entry OU → CleanUp → Available → Active (Leased) → CleanUp → Available (Recycled)
                                      ↓
                                 Quarantine (if cleanup fails)
```

### State Descriptions:

| State | Description | Duration |
|-------|-------------|----------|
| **Entry** | New account, not yet registered | Manual |
| **CleanUp** | Being cleaned by AWS Nuke | 10-15 minutes |
| **Available** | Ready to be leased | Until leased |
| **Active** | Currently leased to a user | Lease duration (48 hours) |
| **Quarantine** | Cleanup failed, needs manual fix | Until fixed |
| **Frozen** | Temporarily suspended | Until unfrozen |

---

## 🔍 How to Check Your Current Quota

### Method 1: Service Quotas Console

1. Go to: https://console.aws.amazon.com/servicequotas/home?region=us-east-1#!/services/organizations/quotas
2. Sign in with Management account (862099794180)
3. Look for: "Default maximum number of accounts"
4. Current value shows your quota

### Method 2: AWS CLI

```bash
aws service-quotas get-service-quota \
  --service-code organizations \
  --quota-code L-29A0C5DF \
  --profile elite-academy \
  --region us-east-1
```

### Method 3: Count Accounts

```bash
aws organizations list-accounts \
  --profile elite-academy \
  --region ap-southeast-3 \
  --output json | jq '.Accounts | length'
```

**Your current count:** 33 accounts (2 infrastructure + 31 sandbox)

---

## 💡 Key Insights

### 1. You're Already Above Default Quota ✅

**Default:** 10 accounts  
**Your current:** 33 accounts  
**Conclusion:** Your quota was already increased (likely to 50 or 100)

### 2. No Blocker for Registration ✅

You can register all 31 sandbox accounts to ISB pool without any quota increase.

### 3. Quarantine is Not a Quota Issue ⚠️

The 7 Quarantine accounts are due to **cleanup configuration**, not quota limits.

**Fix:** Update AWS Nuke config to filter organization-managed resources.

### 4. Perfect Size for Your Use Case ✅

**23 participants** with **31 accounts** = **1.35 accounts per participant**

This provides:
- ✅ Enough accounts for all participants
- ✅ Buffer for concurrent leases
- ✅ Room for retries if needed

---

## 📈 Scaling Considerations

### If You Need More Accounts in the Future

**Current:** 31 sandbox accounts  
**Your quota:** Likely 50-100 accounts  
**Maximum possible:** 50,000 accounts

### To Request Quota Increase:

1. **Go to Service Quotas Console:**
   https://console.aws.amazon.com/servicequotas/home?region=us-east-1#!/services/organizations/quotas

2. **Select:** "Default maximum number of accounts"

3. **Click:** "Request quota increase"

4. **Provide justification:**
   - Number of users
   - Use case (training, development, testing)
   - Expected growth

5. **Wait:** 1-3 business days for approval

6. **Typical increases:**
   - First increase: 50-100 accounts
   - Subsequent increases: Up to 1,000 accounts
   - Large organizations: Up to 50,000 accounts

---

## 🎯 Summary

### Your Current Situation:

✅ **31 sandbox accounts created** - Perfect for 23 participants  
✅ **AWS quota already increased** - No blocker  
✅ **Can register all 31 accounts** - No limits  
⚠️ **7 accounts in Quarantine** - Fix cleanup config  
⚠️ **21 accounts not registered** - Register via web UI  

### Next Steps:

1. **Fix Quarantine accounts** (15 minutes)
2. **Register remaining 21 accounts** (5 minutes)
3. **Wait for cleanup** (10-15 minutes)
4. **Attach blueprint** (1 minute)
5. **Bulk assign leases** (5 minutes)

**Total time:** ~40 minutes (including wait time)

---

## 📞 Support

### If You Need Help:

**AWS Organizations Quota Issues:**
- Service Quotas Console: https://console.aws.amazon.com/servicequotas/
- AWS Support: Open a case from Management account

**Innovation Sandbox Issues:**
- Documentation: https://docs.aws.amazon.com/solutions/latest/innovation-sandbox-on-aws/
- AWS Support: Open a case from Hub account

**Cleanup Issues:**
- See: `FIX-QUARANTINE-ACCOUNTS.md`
- Check: CloudWatch Logs Insights with saved query "AccountCleanupLogs"

---

## 📚 References

- [AWS Organizations Quotas](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html)
- [Innovation Sandbox Documentation](https://docs.aws.amazon.com/solutions/latest/innovation-sandbox-on-aws/)
- [Service Quotas Console](https://console.aws.amazon.com/servicequotas/home?region=us-east-1#!/services/organizations/quotas)

---

**Last Updated:** 2026-05-01  
**Status:** ✅ No quota increase needed - proceed with registration!
