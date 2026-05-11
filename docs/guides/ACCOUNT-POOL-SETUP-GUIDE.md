# Account Pool Setup Guide

## Current Status

**Sandbox Accounts in Pool:** 0
**Organization Accounts:** 2
- 862099794180 - Elite Academy (Management Account)
- 147826551593 - ETA's Innovation Sandbox on AWS (Hub Account)

## What is an Account Pool?

The Account Pool is a collection of AWS accounts that can be leased to users as temporary sandboxes. When a user requests a lease, the Innovation Sandbox:
1. Takes an available account from the pool
2. Grants the user access to that account
3. After the lease expires, cleans up the account
4. Returns it to the pool for reuse

## Why You Need More Accounts

Currently, you have **0 sandbox accounts** in the pool, which means:
- ❌ Users cannot request leases
- ❌ No sandbox environments available
- ❌ The system cannot provision any resources

**You need to add AWS accounts to the pool before users can start using the Innovation Sandbox.**

## Options to Add Accounts

### Option 1: Create New AWS Accounts (Recommended)

Create new AWS accounts specifically for sandbox use:

**Advantages:**
- Clean, dedicated sandbox accounts
- No risk to existing resources
- Easy to manage and track

**How to Create:**
1. Log into AWS Organizations (account 862099794180)
2. Go to **AWS Organizations** → **AWS accounts** → **Add an AWS account**
3. Create multiple accounts (recommended: 5-10 to start)
4. Name them clearly (e.g., "ISB-Sandbox-01", "ISB-Sandbox-02", etc.)

**Recommended Naming Convention:**
```
ISB-Sandbox-01
ISB-Sandbox-02
ISB-Sandbox-03
...
ISB-Sandbox-10
```

### Option 2: Use Existing Accounts

If you have existing AWS accounts that are:
- Not in production use
- Can be cleaned/reset
- Don't contain critical resources

You can register them to the pool.

⚠️ **Warning:** Accounts in the pool will be cleaned up regularly, which means:
- All resources will be deleted
- All data will be lost
- The account will be reset to a clean state

## Account Pool Architecture

```
AWS Organization (862099794180)
├── Root OU (r-e21c)
│   ├── Management Account (862099794180)
│   ├── Hub Account (147826551593)
│   └── Sandbox Accounts (to be created)
│       ├── ISB-Sandbox-01
│       ├── ISB-Sandbox-02
│       ├── ISB-Sandbox-03
│       └── ...
```

## How to Register Accounts to the Pool

### Prerequisites
1. AWS accounts created in your organization
2. Accounts moved to the correct OU (if using OUs)
3. AWS CLI access with appropriate permissions

### Method 1: Via API (Programmatic)

```bash
# Register an account to the pool
curl -X POST \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"awsAccountId": "123456789012"}' \
  https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod/accounts
```

### Method 2: Via Web UI

1. Log into the Innovation Sandbox web app as an Admin
2. Go to **Accounts** section
3. Click **"Register Account"**
4. Enter the AWS Account ID
5. Click **"Register"**

### Method 3: Using AWS CLI Script

I'll create a script for you to register multiple accounts at once.

## Recommended Setup for Different Team Sizes

### Small Team (5-10 users)
- **Accounts needed:** 3-5 sandbox accounts
- **Reasoning:** Assuming 50% utilization, allows 1-2 concurrent leases per user

### Medium Team (10-50 users)
- **Accounts needed:** 10-20 sandbox accounts
- **Reasoning:** Allows for multiple concurrent leases and experimentation

### Large Team (50+ users)
- **Accounts needed:** 20-50 sandbox accounts
- **Reasoning:** Ensures availability during peak usage

## Account Lifecycle

```
1. Created → 2. Registered → 3. Available → 4. Active (Leased) → 5. Cleanup → 6. Available (repeat)
```

### States:
- **Available:** Ready to be leased
- **Active:** Currently leased to a user
- **CleanUp:** Being cleaned after lease expiration
- **Quarantine:** Failed cleanup, needs manual intervention
- **Frozen:** Temporarily suspended

## Cost Considerations

### Per Account Costs:
- **AWS Account:** Free (no charge for the account itself)
- **Resources:** Only pay for what users create during leases
- **Cleanup:** Minimal cost (Step Functions, Lambda executions)

### Budget Recommendations:
- Set max spend limits on lease templates
- Monitor costs via Cost Explorer
- Use budget alerts

## Next Steps

1. **Decide how many accounts you need** (start with 5-10)
2. **Create the accounts** in AWS Organizations
3. **Register them** to the Innovation Sandbox pool
4. **Test** by requesting a lease
5. **Monitor** usage and add more as needed

## Creating Accounts Script

Would you like me to create a script to help you:
1. Create multiple AWS accounts via Organizations API?
2. Register them to the Innovation Sandbox pool?
3. Verify they're properly configured?

## Current Configuration

From your `.env` file:
- **Parent OU ID:** r-e21c (root)
- **Regions:** us-east-1, ap-southeast-3, ap-southeast-1, ap-southeast-5
- **Namespace:** myisb

## Questions?

**Q: Can I use the management account (862099794180) as a sandbox?**
A: No, never use the management account for sandboxes. It controls your entire organization.

**Q: Can I use the hub account (147826551593) as a sandbox?**
A: No, the hub account runs the Innovation Sandbox infrastructure.

**Q: How long does it take to create an account?**
A: AWS Organizations can create accounts in 5-15 minutes.

**Q: Can I remove accounts from the pool later?**
A: Yes, you can eject accounts from the pool via the web UI or API.

**Q: What happens if all accounts are in use?**
A: Users will see "No accounts available" when requesting a lease. Add more accounts to the pool.

---

**Ready to add accounts?** Let me know and I'll create a script to help you create and register multiple accounts at once!
