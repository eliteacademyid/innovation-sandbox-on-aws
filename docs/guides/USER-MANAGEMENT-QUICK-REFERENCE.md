# User Management Quick Reference

## Can Users Self-Register? **NO** ❌

Users **cannot** create their own accounts. All users must be created by administrators in IAM Identity Center.

---

## How to Add Users

### Quick Commands

```bash
# Single user
./scripts/create-test-user.sh user@example.com FirstName LastName user

# Bulk users (create + assign leases)
./scripts/create-users-and-assign-leases.sh users.csv <LEASE_TEMPLATE_UUID>

# Bulk assign leases to existing users
python3 scripts/bulk-assign-leases.py users.csv <LEASE_TEMPLATE_UUID>
```

---

## Authentication Flow

```
User → SAML Sign-In → IAM Identity Center → Validation → Innovation Sandbox
```

**Key Point:** User must exist in IAM Identity Center **before** they can sign in.

---

## What Users Can/Cannot Do

### ✅ Users CAN:
- Sign in (after admin creates account)
- Request leases for themselves
- View available lease templates
- Manage their own leases
- Change their password (after initial setup)

### ❌ Users CANNOT:
- Create their own accounts
- Self-register in the system
- Invite other users
- Modify their roles/permissions
- Access without being pre-created

---

## User Roles

| Role | Permissions |
|------|-------------|
| **User** | Request leases, view own leases |
| **Manager** | + Approve leases, assign leases to others |
| **Admin** | + Full system access, manage configuration |

---

## User Creation Methods

### 1. Script (Recommended)
```bash
./scripts/create-test-user.sh alice@example.com Alice Smith user
```

### 2. AWS Console
IAM Identity Center → Users → Add user → Assign to group → Assign to SAML app

### 3. AWS CLI
```bash
aws identitystore create-user \
  --identity-store-id d-c8671c93a3 \
  --user-name "user@example.com" \
  --display-name "Full Name" \
  --name '{"GivenName":"First","FamilyName":"Last"}' \
  --emails '[{"Value":"user@example.com","Type":"work","Primary":true}]'
```

---

## Onboarding Process

1. **Admin creates user** in IAM Identity Center
2. **Admin assigns to group** (user/manager/admin)
3. **Admin assigns to SAML app**
4. **Admin sends password reset email**
5. **User sets password** via email link
6. **User signs in** at https://d1nu7n93cpbse4.cloudfront.net
7. **User requests lease** (or admin assigns one)

---

## Common Scenarios

### New Employee Onboarding
```bash
# Create user
./scripts/create-test-user.sh newemployee@company.com New Employee user

# Assign a lease
python3 scripts/bulk-assign-leases.py newemployee.csv <TEMPLATE_UUID>
```

### Bulk Team Onboarding
```bash
# Create CSV
cat > team.csv << EOF
email,firstName,lastName,role,comments
alice@company.com,Alice,Smith,user,Dev team
bob@company.com,Bob,Jones,user,Dev team
carol@company.com,Carol,Davis,manager,Team lead
EOF

# Create all users and assign leases
./scripts/create-users-and-assign-leases.sh team.csv <TEMPLATE_UUID>
```

### Workshop/Training Event
```bash
# Create 20 student accounts
for i in {1..20}; do
  ./scripts/create-test-user.sh student${i}@university.edu Student${i} User user
done

# Bulk assign leases
python3 scripts/bulk-assign-leases.py students.csv <TEMPLATE_UUID>
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| User can't sign in | Verify user exists in IAM Identity Center |
| "User not authenticated" | User not assigned to SAML application |
| User has no permissions | User not added to any group |
| Password reset not received | Check email address, resend from console |

---

## Your Configuration

- **Identity Store:** `d-c8671c93a3`
- **Web App:** https://d1nu7n93cpbse4.cloudfront.net
- **Admin Account:** Elite Academy (862099794180)
- **Region:** ap-southeast-3

### Group IDs
- **Admin:** `41490da6-b0d1-705a-bcf8-41a1478c6ea7`
- **Manager:** `31992d76-1001-7028-631c-bd3034732ddb`
- **User:** `81098d36-e041-703d-e15b-90337bb290a1`

---

## Related Files

- `scripts/create-test-user.sh` - Create individual users
- `scripts/create-users-and-assign-leases.sh` - Bulk create + assign
- `scripts/bulk-assign-leases.py` - Bulk assign to existing users
- `USER-SELF-REGISTRATION-GUIDE.md` - Detailed explanation
- `BULK-LEASE-ASSIGNMENT-SUMMARY.md` - Bulk assignment guide

---

## Key Takeaway

**Innovation Sandbox uses an enterprise security model where administrators control all user access. There is no self-service registration. Use the provided scripts to quickly create users individually or in bulk.**
