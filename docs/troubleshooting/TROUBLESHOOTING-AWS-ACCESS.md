# Troubleshooting AWS Access Issue

## Problem

Getting "ForbiddenException: No access" when trying to use the `elite-academy` profile, even after successful SSO login.

```
An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access
```

## Root Cause

The SSO login was successful, but there's a permission issue preventing role assumption. This could be due to:

1. **SSO Permission Set not assigned** - The AdministratorAccess permission set may not be assigned to your user for account 862099794180
2. **IAM Identity Center access revoked** - Your user may have lost access to the account
3. **Role trust policy issue** - The AdministratorAccess role may not trust the SSO principal

## Solution Options

### Option 1: Check SSO Assignments in AWS Console

1. Log into AWS Console as an administrator
2. Go to **IAM Identity Center**
3. Click **AWS accounts** in the left menu
4. Find account **862099794180** (Elite Academy)
5. Click on it and check **Users and groups** tab
6. Verify your user has the **AdministratorAccess** permission set assigned

If not assigned:
- Click **Assign users or groups**
- Select your user
- Assign the **AdministratorAccess** permission set

### Option 2: Use AWS Console Directly

Since CLI access isn't working, you can create users directly in the AWS Console:

1. Log into AWS Console for account 862099794180
2. Go to **IAM Identity Center** → **Users**
3. Click **Add user** for each person
4. Fill in details from `cendekiawan-tot-users.csv`
5. Add to group: `myisb_IsbUsersGroup`
6. Assign to SAML application

### Option 3: Use a Different AWS Account/Role

If you have access to a different AWS account or role that has permissions to manage IAM Identity Center:

```bash
# Try using AWS Console access instead
# Or use a different profile if available
aws configure list-profiles
```

### Option 4: Request Access from Administrator

Contact your AWS administrator and request:
- AdministratorAccess permission set for account 862099794180
- Or specific permissions for:
  - `identitystore:CreateUser`
  - `identitystore:CreateGroupMembership`
  - `sso-admin:CreateApplicationAssignment`

## Verification Steps

After getting access restored, verify with:

```bash
# Test basic access
aws sts get-caller-identity --profile elite-academy

# Test Identity Store access
aws identitystore list-users \
  --identity-store-id d-c8671c93a3 \
  --profile elite-academy \
  --region ap-southeast-3 \
  --max-results 1
```

If both commands work, you can proceed with user creation.

## Alternative: Manual User Creation via Console

If CLI access cannot be restored quickly, here's the manual process:

### For Each User in cendekiawan-tot-users.csv:

1. **Create User:**
   - IAM Identity Center → Users → Add user
   - Username: (email address)
   - Email: (same as username)
   - First name: (from CSV)
   - Last name: (from CSV)
   - Display name: (First Last)

2. **Add to Group:**
   - Select the user
   - Groups tab → Add user to groups
   - Select: `myisb_IsbUsersGroup`

3. **Assign to Application:**
   - IAM Identity Center → Applications
   - Select: "ETA Innovation Sandbox App"
   - Assigned users tab → Assign users
   - Select the user

4. **Send Password Reset:**
   - Go back to Users
   - Select the user
   - Actions → Reset password → Send email

## Users to Create (23 Total)

See `cendekiawan-tot-users.csv` for the complete list.

## Contact

If you need help resolving the access issue, contact:
- Your AWS Organization administrator
- The person who originally set up the Innovation Sandbox deployment
- AWS Support (if you have a support plan)

## Files

- `cendekiawan-tot-users.csv` - List of all users to create
- `create-cendekiawan-users-simple.sh` - Automated script (requires working CLI access)
- This file - Troubleshooting guide
