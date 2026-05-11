# Deployment Log — v1.2.8 Update

**Date**: May 11, 2026  
**Deployed by**: andrian@eliteacademy.id  
**Source**: Fork `eliteacademyid/innovation-sandbox-on-aws` (main branch)  
**Previous version**: v1.2.7  
**New version**: v1.2.8

---

## Deployment Results

| Stack | Status | Time | Account | Region |
|-------|--------|------|---------|--------|
| AccountPool | ✅ Complete | 45s | 862099794180 (mgmt) | ap-southeast-1 |
| Data | ✅ Complete | 74s | 147826551593 (hub) | ap-southeast-1 |
| IDC | ✅ Complete | 38s | 862099794180 (mgmt) | ap-southeast-1 |
| Compute | ✅ Complete | 163s | 147826551593 (hub) | ap-southeast-1 |
| **Total** | **✅ All done** | **~5 min** | | |

---

## Stack ARNs

| Stack | ARN |
|-------|-----|
| AccountPool | `arn:aws:cloudformation:ap-southeast-1:862099794180:stack/InnovationSandbox-AccountPool/a7572010-4a75-11f1-8960-0ac10975c181` |
| Data | `arn:aws:cloudformation:ap-southeast-1:147826551593:stack/InnovationSandbox-Data/22f10320-4a77-11f1-98b1-067b15c8f3a5` |
| IDC | `arn:aws:cloudformation:ap-southeast-1:862099794180:stack/InnovationSandbox-IDC/7bf27680-4a76-11f1-92d5-0aed7cda2925` |
| Compute | `arn:aws:cloudformation:ap-southeast-1:147826551593:stack/InnovationSandbox-Compute/c23bc360-4a7d-11f1-bfcb-0a7af713fef3` |

---

## Compute Stack Outputs

| Output | Value |
|--------|-------|
| CloudFront URL | https://dd3kj1ggdvsy3.cloudfront.net |
| API Endpoint | https://ob90f1sd45.execute-api.ap-southeast-1.amazonaws.com/prod/ |
| Deployment UUID | c880210d-d9da-46ce-85af-9acf6e14870d |
| IDP Cert ARN | arn:aws:secretsmanager:ap-southeast-1:147826551593:secret:/InnovationSandbox/myisb/Auth/IdpCert-U1GDDt |
| JWT Secret ARN | arn:aws:secretsmanager:ap-southeast-1:147826551593:secret:/InnovationSandbox/myisb/Auth/JwtSecret-1lUanE |

---

## What Was Fixed (v1.2.8 Release Notes)

### Bug Fix
- **Allow lease termination and freeze when user is deleted from IDC** — Previously, if a user was deleted from IAM Identity Center while they still had an active lease, the lease could not be terminated. Now fixed.

### Security Patches
- CVE-2026-4046 (glibc, glibc-common, glibc-minimal-langpack)
- CVE-2026-4786 (python3, python3-libs, python-unversioned-command)
- CVE-2026-6100 (python3, python3-libs, python-unversioned-command)

---

## Context: Why This Update Was Needed

3 leases were stuck in "expired but can't terminate" state since May 8, 2026:

| User | Lease ID | Account |
|------|----------|---------|
| adeline.john@apu.edu.my | 99341be9-00ba-449a-989b-53e7f13b9421 | 717056864071 |
| nur.azyyati@apu.edu.my | 7828a833-3a56-4cb3-8456-498aa82029ca | 100731996679 |
| tulasi.appalasamy@apu.edu.my | 9c35a530-d8b3-46fd-a4fb-632fe8aad981 | 657588917485 |

Error: `CouldNotRetrieveUserError: Unable to retrieve user information.`

These users were deleted from IDC but their leases were still active. The v1.2.8 fix resolves this exact issue.

---

## Deployment Method

```bash
# Profiles used
AWS_PROFILE=eta-andrian    # Management account (862099794180)
AWS_PROFILE=eta-isb-andrian  # Hub account (147826551593)

# Commands executed
npm run deploy:account-pool   # → eta-andrian profile
npm run deploy:data           # → eta-isb-andrian profile
npm run deploy:idc            # → eta-andrian profile
npm run deploy:compute        # → eta-isb-andrian profile
```

---

## Verification Checklist

- [x] AccountPool stack updated successfully
- [x] Data stack updated (DynamoDB tables preserved)
- [x] IDC stack updated (user access preserved)
- [x] Compute stack updated (Lambda functions + frontend deployed)
- [ ] Web app accessible at CloudFront URL
- [ ] Stuck leases terminate on next monitoring cycle
- [ ] Users can still sign in
