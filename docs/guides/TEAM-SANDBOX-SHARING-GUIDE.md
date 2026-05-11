# Team Sandbox Sharing Guide

## Overview

This guide explains how to share a single sandbox account with multiple team members for collaborative projects. It uses an **IDC group-based approach** — one group per team, assigned to one sandbox account.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                  GROUP-BASED SHARING                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Team leader gets a lease (normal ISB flow)              │
│     → Sandbox account assigned (e.g., 123456789012)         │
│                                                             │
│  2. Admin creates IDC group "isb-team-alpha"                │
│     → Adds all team members to the group                    │
│                                                             │
│  3. Admin assigns GROUP to the sandbox account              │
│     → All members instantly get access via SSO portal       │
│                                                             │
│  4. Team composition changes?                               │
│     → Just add/remove from group — no re-assignment needed  │
│                                                             │
│  5. Lease expires?                                          │
│     → ISB revokes access + cleans account                   │
│     → Admin deletes the team group (cleanup)                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

- AWS CLI configured with `elite-academy` profile
- `jq` installed
- Team members must already exist in IAM Identity Center
- Team leader must have an active lease (sandbox account assigned)

### Create a Team Share

```bash
# Make script executable (first time only)
chmod +x scripts/team-sandbox-share.sh

# Create team and assign to sandbox account
./scripts/team-sandbox-share.sh create <team-name> <sandbox-account-id> <email1> <email2> ...

# Example:
./scripts/team-sandbox-share.sh create alpha 123456789012 \
  alice@company.com \
  bob@company.com \
  carol@company.com
```

### Manage Team Members

```bash
# Add a new member
./scripts/team-sandbox-share.sh add alpha dave@company.com

# Remove a member
./scripts/team-sandbox-share.sh remove alpha bob@company.com

# List current members
./scripts/team-sandbox-share.sh list alpha
```

### Cleanup (When Project Ends)

```bash
# Delete team group + revoke account access
./scripts/team-sandbox-share.sh delete alpha 123456789012
```

---

## For Team Members

Once your admin has set up the team share:

1. Go to the **AWS Access Portal**: https://d-9667a833b5.awsapps.com/start
2. Sign in with your email and password
3. You'll see the shared sandbox account listed
4. Click on it → choose the permission set → access the AWS Console
5. Start collaborating!

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  IAM Identity Center (Account: 862099794180)                │
│                                                             │
│  ┌─────────────────────────────────────────┐               │
│  │  Group: isb-team-alpha                  │               │
│  │  Members:                               │               │
│  │    • alice@company.com                  │               │
│  │    • bob@company.com                    │               │
│  │    • carol@company.com                  │               │
│  └──────────────────┬──────────────────────┘               │
│                     │                                       │
│                     │ Account Assignment                    │
│                     │ (IsbUsersPS permission set)           │
│                     │                                       │
└─────────────────────┼───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│  Sandbox Account: 123456789012                              │
│                                                             │
│  All group members get federated access                     │
│  Same permissions as a normal ISB user                      │
│  Budget is SHARED across all members                        │
└─────────────────────────────────────────────────────────────┘
```

---

## Important Notes

### Budget

- The sandbox account has a **single budget** (set by the lease template)
- All team members' usage counts toward this one budget
- **Recommendation**: Use a higher budget for team leases (e.g., $20-50 instead of $10)

### ISB Dashboard

- ISB only shows the **lease holder** (team leader) in its dashboard
- Other team members are invisible to ISB
- This is a known limitation of the workaround approach

### Lease Expiry

- When the lease expires, ISB calls `revokeAllUserAccess` on the account
- This revokes the **individual** user assignment (lease holder)
- The **group** assignment is NOT automatically revoked by ISB
- **You must run `delete` to clean up the group assignment**

### Cleanup Checklist

When a team project ends:

- [ ] Run `./scripts/team-sandbox-share.sh delete <team-name> <account-id>`
- [ ] Verify the lease has expired or terminate it in ISB
- [ ] Account will be cleaned by AWS Nuke automatically

### SCPs Still Apply

Team members get the same restrictions as any sandbox user:
- ❌ Cannot create IAM users
- ❌ Cannot purchase Reserved Instances
- ❌ Cannot modify account/billing settings
- ✅ Can use all AWS Nuke-supported services
- ✅ Can create resources within budget

---

## When to Use This vs Individual Accounts

| Scenario | Recommendation |
|----------|---------------|
| Workshop/training (individual learning) | 1 account per person |
| Team project (shared resources) | **Shared account (this guide)** |
| Hackathon (team competition) | **Shared account (this guide)** |
| Individual experimentation | 1 account per person |
| Cost-sensitive (limited accounts) | **Shared account (this guide)** |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "User not found" | Ensure user exists in IAM Identity Center first |
| "Group already exists" | Script handles this gracefully — continues with existing group |
| Member can't see account in SSO portal | Wait 1-2 minutes for propagation, then refresh |
| Permission set not found | Check that ISB IDC stack is deployed correctly |
| Budget exceeded quickly | Shared budget — consider increasing lease template budget |

---

## Configuration

| Parameter | Value |
|-----------|-------|
| Identity Store ID | `d-9667a833b5` |
| SSO Instance ARN | `arn:aws:sso:::instance/ssoins-821055714a3e49c5` |
| IDC Account | `862099794180` |
| AWS Profile | `elite-academy` |
| Region | `ap-southeast-3` |
| Group naming | `isb-team-<team-name>` |
| SSO Portal | https://d-9667a833b5.awsapps.com/start |

---

## Related Files

- `scripts/team-sandbox-share.sh` — Main script for team sharing
- `scripts/create-test-user.sh` — Create individual users
- `scripts/bulk-assign-leases.py` — Bulk lease assignment
- `USER-MANAGEMENT-QUICK-REFERENCE.md` — User management overview
