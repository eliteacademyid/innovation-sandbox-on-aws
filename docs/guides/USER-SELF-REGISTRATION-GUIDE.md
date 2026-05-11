# Can Users Create Their Own Accounts to Request Leases?

## Short Answer: **No** ❌

Users **cannot** create their own accounts or self-register in the Innovation Sandbox on AWS. All users must be created by administrators in **AWS IAM Identity Center** before they can access the system.

---

## How Authentication Works

### Current Authentication Flow

```
User → SAML Sign-In → IAM Identity Center → Authentication → Innovation Sandbox
```

1. **User attempts to sign in** at the web application
2. **Redirected to SAML IdP** (IAM Identity Center)
3. **IAM Identity Center authenticates** the user
4. **SAML response sent back** to Innovation Sandbox
5. **Innovation Sandbox validates** the user exists in Identity Center
6. **JWT token issued** for session management

### Key Point: Pre-existing Users Only

The authentication code explicitly checks if the user exists in IAM Identity Center:

```typescript
// From source/lambdas/api/sso-handler/src/server.ts
const isbUser = await User.getIsbUser(user.nameID);

if (!isbUser) {
  logger.error("Unable to retrieve user information");
  return res.status(401).json({ message: "User not authenticated" });
}
```

**If the user doesn't exist in IAM Identity Center, authentication fails.**

---

## Why No Self-Registration?

### 1. **Enterprise Security Model**
The Innovation Sandbox is designed for **enterprise environments** where:
- IT administrators control user access
- Users are managed centrally in IAM Identity Center
- Access is granted based on organizational policies

### 2. **IAM Identity Center Integration**
The solution uses **AWS IAM Identity Center** (formerly AWS SSO) as the identity provider:
- IAM Identity Center doesn't support self-service user registration
- All users must be created by administrators
- This ensures proper governance and access control

### 3. **Role-Based Access Control**
Users are assigned to specific groups that determine their permissions:
- **Admin** - Full system access
- **Manager** - Can approve leases, assign leases to others
- **User** - Can request leases for themselves

Self-registration would bypass this controlled access model.

---

## How to Add New Users

### Option 1: Individual User Creation (Manual)

Use the provided script to create users one at a time:

```bash
./scripts/create-test-user.sh user@example.com FirstName LastName user
```

**Steps:**
1. Admin runs the script with user details
2. User is created in IAM Identity Center
3. User is added to the appropriate group (admin/manager/user)
4. User is assigned to the SAML application
5. Admin sends password reset email from IAM Identity Center console

### Option 2: Bulk User Creation

Use the bulk creation script for multiple users:

```bash
# Create CSV file
cat > users.csv << EOF
email,firstName,lastName,role,comments
alice@example.com,Alice,Smith,user,Development
bob@example.com,Bob,Jones,user,Testing
EOF

# Create users and assign leases
./scripts/create-users-and-assign-leases.sh users.csv <LEASE_TEMPLATE_UUID>
```

### Option 3: AWS Console (Manual)

1. Log into AWS Console with the Elite Academy account (862099794180)
2. Navigate to **IAM Identity Center**
3. Go to **Users** → **Add user**
4. Fill in user details
5. Add user to appropriate group
6. Assign user to the SAML application
7. Send password reset email

### Option 4: AWS CLI (Programmatic)

```bash
# Create user
aws identitystore create-user \
  --identity-store-id d-c8671c93a3 \
  --user-name "user@example.com" \
  --display-name "Full Name" \
  --name '{"GivenName":"First","FamilyName":"Last"}' \
  --emails '[{"Value":"user@example.com","Type":"work","Primary":true}]' \
  --profile elite-academy \
  --region ap-southeast-3

# Add to group
aws identitystore create-group-membership \
  --identity-store-id d-c8671c93a3 \
  --group-id <GROUP_ID> \
  --member-id '{"UserId":"<USER_ID>"}' \
  --profile elite-academy \
  --region ap-southeast-3

# Assign to SAML application
aws sso-admin create-application-assignment \
  --application-arn arn:aws:sso::862099794180:application/ssoins-666616fcfb74eec7/apl-66664d3a4fcad754 \
  --principal-id <USER_ID> \
  --principal-type USER \
  --profile elite-academy \
  --region ap-southeast-3
```

---

## User Onboarding Workflow

### Current Process (Admin-Driven)

```
1. Admin creates user in IAM Identity Center
   ↓
2. Admin assigns user to appropriate group
   ↓
3. Admin assigns user to SAML application
   ↓
4. Admin sends password reset email
   ↓
5. User receives email and sets password
   ↓
6. User can now sign in to Innovation Sandbox
   ↓
7. User can request leases (or admin can assign leases)
```

### What Users Can Do (After Creation)

Once a user account exists, users can:
- ✅ Sign in to the web application
- ✅ View available lease templates
- ✅ Request leases for themselves
- ✅ View their active leases
- ✅ Manage their own leases (within permissions)

### What Users Cannot Do

Users cannot:
- ❌ Create their own accounts
- ❌ Register themselves in the system
- ❌ Invite other users
- ❌ Modify their own roles/permissions
- ❌ Access the system without being pre-created by an admin

---

## Alternative Approaches (If You Need Self-Service)

If you need self-service user registration, you would need to implement a custom solution:

### Option A: External Identity Provider with Self-Registration

1. **Use an external IdP** that supports self-registration:
   - Okta
   - Auth0
   - Azure AD B2C
   - Google Workspace (with self-registration enabled)

2. **Configure SAML federation** between the external IdP and IAM Identity Center

3. **Implement user provisioning** (SCIM) to sync users from external IdP to IAM Identity Center

**Challenges:**
- Complex setup
- Additional costs for external IdP
- Still requires SCIM provisioning to IAM Identity Center
- May not align with enterprise security policies

### Option B: Custom Registration Portal

1. **Build a custom registration portal** (separate web app)
2. **Portal collects user information** and validates email
3. **Portal calls AWS APIs** to create users in IAM Identity Center
4. **Portal sends approval request** to administrators
5. **Admin approves** and user is created

**Challenges:**
- Significant development effort
- Requires additional infrastructure
- Security considerations for automated user creation
- Still requires admin approval for security

### Option C: Automated User Provisioning from HR System

1. **Integrate with HR/Identity system** (e.g., Workday, BambooHR)
2. **Automated sync** when new employees are added
3. **Users automatically created** in IAM Identity Center
4. **Role assignment** based on department/job title

**Challenges:**
- Requires HR system integration
- May create users who don't need sandbox access
- Complex to set up initially

---

## Recommended Approach

### For Small Teams (< 50 users)
**Use the provided scripts:**
- `create-test-user.sh` for individual users
- `create-users-and-assign-leases.sh` for bulk onboarding

### For Medium Teams (50-200 users)
**Implement a streamlined process:**
1. Create a Google Form or similar for user requests
2. Form submissions trigger a notification to admins
3. Admin reviews and runs bulk creation script weekly
4. Users receive welcome email with sign-in instructions

### For Large Teams (200+ users)
**Consider automation:**
1. Integrate with your existing identity management system
2. Use SCIM provisioning if your IdP supports it
3. Automate user creation based on organizational data
4. Implement approval workflows for sandbox access

---

## Frequently Asked Questions

### Q: Can users sign up with their email address?
**A:** No. All users must be created by administrators in IAM Identity Center first.

### Q: What if a user tries to sign in without an account?
**A:** Authentication will fail with "User not authenticated" error.

### Q: Can users from external organizations access the sandbox?
**A:** Only if an administrator creates an account for them in IAM Identity Center. They must have a valid email address that can receive the password reset email.

### Q: Can we allow users to request access?
**A:** Not built-in, but you could create a separate request form that notifies administrators, who then create the accounts manually.

### Q: How long does it take to create a new user?
**A:** Using the script: ~5 seconds per user. Bulk creation: ~0.5 seconds per user after the first.

### Q: Can users change their own passwords?
**A:** Yes, once their account is created, users can change their password through IAM Identity Center.

### Q: What happens if a user's email changes?
**A:** An administrator must update the user's email in IAM Identity Center.

---

## Summary

| Feature | Supported |
|---------|-----------|
| Self-service user registration | ❌ No |
| Admin-created users | ✅ Yes |
| SAML authentication | ✅ Yes |
| Password reset by user | ✅ Yes (after initial creation) |
| Bulk user creation | ✅ Yes (via scripts) |
| External IdP integration | ⚠️ Possible (requires SCIM) |
| Users can request leases | ✅ Yes (after account creation) |
| Users can invite others | ❌ No |

---

## Related Documentation

- **User Creation Script:** `scripts/create-test-user.sh`
- **Bulk User Creation:** `scripts/create-users-and-assign-leases.sh`
- **Bulk Lease Assignment:** `scripts/BULK-LEASE-ASSIGNMENT.md`
- **Deployment Outputs:** `deployment-outputs.md`

---

## Your Current Setup

Based on your deployment:

- **Identity Store ID:** `d-c8671c93a3`
- **SSO Instance ARN:** `arn:aws:sso:::instance/ssoins-666616fcfb74eec7`
- **SAML Application ARN:** `arn:aws:sso::862099794180:application/ssoins-666616fcfb74eec7/apl-66664d3a4fcad754`
- **Web App URL:** https://d1nu7n93cpbse4.cloudfront.net
- **Identity Source:** IAM Identity Center built-in directory

**To add users, use:**
```bash
./scripts/create-test-user.sh user@example.com FirstName LastName user
```

---

**Bottom Line:** The Innovation Sandbox follows an enterprise security model where administrators control user access. Users cannot self-register, but administrators have scripts and tools to quickly create users individually or in bulk.
