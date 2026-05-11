# Google Workspace Configuration Fix

Since you've already:
- ✅ Minimized IAM Identity Center attributes to 3 (Subject, email, name)
- ✅ Cleared all browser cookies
- ✅ Tested in fresh incognito window
- ❌ Still getting RequestHeaderSectionTooLarge error

**The problem is Google Workspace sending too many attributes via SCIM.**

---

## 🎯 Solution: Configure Google Workspace Attribute Mapping

### Step 1: Access Google Workspace SCIM Configuration

1. Open: https://admin.google.com
2. Sign in with your Google Workspace admin account
3. Navigate to: **Apps** → **Web and mobile apps**
4. Find and click: **AWS IAM Identity Center** (might also be called "AWS SSO" or "AWS Single Sign-On")

### Step 2: Locate Attribute Mappings

Look for one of these sections (varies by Google Workspace version):
- **"Attributes"**
- **"Attribute mapping"**
- **"User provisioning"** → **"Attributes"**
- **"SCIM provisioning"** → **"Attribute mapping"**

### Step 3: Current Problem

Google Workspace is likely sending attributes like:
- ✅ email (keep)
- ✅ name / givenName / familyName (keep)
- ❌ groups (remove or limit)
- ❌ department (remove)
- ❌ title (remove)
- ❌ phoneNumber (remove)
- ❌ address (remove)
- ❌ manager (remove)
- ❌ employeeNumber (remove)
- ❌ costCenter (remove)
- ❌ organization (remove)
- ❌ division (remove)
- ❌ ... and many more custom attributes

### Step 4: Minimize Attributes

**Keep ONLY these attributes:**
- `email` → `emails[primary]` or `userName`
- `givenName` → `name.givenName`
- `familyName` → `name.familyName`

**Remove or disable ALL other attributes**, especially:
- Groups (if users belong to many groups)
- Department, title, phone, address
- Any custom attributes

### Step 5: Save and Force Sync

1. Click **"Save"** or **"Update"**
2. Find the **"Provisioning"** or **"Sync"** section
3. Click **"Sync now"** or **"Force sync"** or **"Test connection"**
4. Wait **10-15 minutes** for the sync to complete

### Step 6: Verify in AWS

```bash
# Check if user attributes are minimal now
aws identitystore describe-user \
  --identity-store-id d-c8671c93a3 \
  --user-id 11695dc6-2031-7023-7f93-f38b662b1f5a \
  --profile elite-academy \
  --region ap-southeast-3 \
  --output json
```

You should see ONLY:
- UserName
- Name (GivenName, FamilyName)
- Emails
- DisplayName

NO other attributes should be present.

### Step 7: Test Again

1. Wait 15 minutes after sync completes
2. Open a **NEW incognito window**
3. Go to: https://d1nu7n93cpbse4.cloudfront.net
4. Sign in

---

## Alternative: Disable Group Provisioning

If you can't find attribute mappings, try disabling group provisioning:

### In Google Workspace Admin Console:

1. Go to the AWS IAM Identity Center app configuration
2. Find **"Group provisioning"** or **"Provision groups"**
3. **Disable** or **Turn off** group provisioning
4. Save changes
5. Force sync
6. Wait 10 minutes and test

---

## If You Can't Find These Settings

Google Workspace interface varies. Try these alternative paths:

### Path 1:
Apps → SAML apps → AWS IAM Identity Center → User provisioning

### Path 2:
Directory → Users → More → Manage custom attributes → (check what's defined)

### Path 3:
Apps → Web and mobile apps → AWS IAM Identity Center → SCIM → Attribute mapping

---

## Still Not Working?

If you still can't resolve it through Google Workspace, we have two options:

### Option A: Disable SCIM Entirely (Temporary Test)

1. In Google Workspace, disable SCIM provisioning for AWS IAM Identity Center
2. Manually create a test user directly in IAM Identity Center (via AWS Console)
3. Assign that user to the SAML application
4. Test with that user
5. If it works → SCIM is definitely the problem
6. If it still fails → We need Lambda@Edge solution

### Option B: Implement Lambda@Edge (Guaranteed Fix)

I can help you implement a Lambda@Edge solution that will:
- Intercept large headers
- Store them temporarily
- Replace with small tokens
- Guaranteed to work regardless of SAML/SCIM configuration

This requires modifying the CDK infrastructure and redeploying.

---

## What to Check in Google Workspace

Take screenshots or note what you see for:
1. **Attribute mappings** - What attributes are being sent?
2. **Group provisioning** - Is it enabled? How many groups?
3. **User provisioning settings** - What's configured?

Share this information and I can provide more specific guidance.

---

**Next Step**: Check Google Workspace attribute mappings and let me know what you find.
