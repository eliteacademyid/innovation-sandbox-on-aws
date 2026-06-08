# Deployment Log — v1.2.10 Update

**Date**: June 8, 2026
**Deployed by**: andrian@eliteacademy.id (via Kiro)
**Source**: Fork `eliteacademyid/innovation-sandbox-on-aws` (main branch @ `950ca41`)
**Previous version**: v1.2.8 (deployed May 11, 2026 — skipped v1.2.9)
**New version**: v1.2.10

---

## Why this update

Security-only release covering two upstream releases (v1.2.9 + v1.2.10):

- `js-cookie` upgrade — CVE-2026-46625 (frontend bundle, served via CloudFront)
- `uuid` upgrade — CVE-2026-41907 (Lambda + frontend)
- `fast-uri` upgrade — CVE-2026-6321, CVE-2026-6322 (Lambda JSON schema validation)
- AmazonLinux base image digest update for the account-cleaner ECS task
- AppConfig Lambda extension layer ARNs bumped to v2.0.17054.0 across all regions

No feature changes, no schema changes, no breaking API changes.

---

## Deployment Results

| Stack | Status | Time | Account | Region |
|-------|--------|------|---------|--------|
| AccountPool | ✅ Complete | 48s | 862099794180 (mgmt) | ap-southeast-1 |
| Data | ✅ Complete | 17s | 147826551593 (hub) | ap-southeast-1 |
| IDC | ✅ Complete | 43s | 862099794180 (mgmt) | ap-southeast-1 |
| Compute | ✅ Complete | 170s | 147826551593 (hub) | ap-southeast-1 |
| **Total** | **✅ All done** | **~5 min CFN time, ~10 min wall clock with synth** | | |

Deploy started: 2026-06-08 13:48 WIB
Deploy ended:   2026-06-08 14:30 WIB

---

## Stack ARNs (unchanged from v1.2.8)

| Stack | ARN |
|-------|-----|
| AccountPool | `arn:aws:cloudformation:ap-southeast-1:862099794180:stack/InnovationSandbox-AccountPool/a7572010-4a75-11f1-8960-0ac10975c181` |
| Data | `arn:aws:cloudformation:ap-southeast-1:147826551593:stack/InnovationSandbox-Data/22f10320-4a77-11f1-98b1-067b15c8f3a5` |
| IDC | `arn:aws:cloudformation:ap-southeast-1:862099794180:stack/InnovationSandbox-IDC/7bf27680-4a76-11f1-92d5-0aed7cda2925` |
| Compute | `arn:aws:cloudformation:ap-southeast-1:147826551593:stack/InnovationSandbox-Compute/c23bc360-4a7d-11f1-bfcb-0a7af713fef3` |

---

## Compute Stack Outputs (unchanged)

| Output | Value |
|--------|-------|
| CloudFront URL | https://dd3kj1ggdvsy3.cloudfront.net |
| API Endpoint | https://ob90f1sd45.execute-api.ap-southeast-1.amazonaws.com/prod/ |
| Deployment UUID | c880210d-d9da-46ce-85af-9acf6e14870d |
| JWT Secret ARN | `arn:aws:secretsmanager:ap-southeast-1:147826551593:secret:/InnovationSandbox/myisb/Auth/JwtSecret-1lUanE` |
| IdP Cert ARN | `arn:aws:secretsmanager:ap-southeast-1:147826551593:secret:/InnovationSandbox/myisb/Auth/IdpCert-U1GDDt` |

---

## Smoke Test Results

| Check | Result |
|---|---|
| CloudFront `GET /` | 200, TTFB 445ms, served from S3 |
| New frontend bundle | `/assets/index-BHmmjOna.js` (v1.2.10 vite build) |
| API Gateway reachability | `/api/configurations` returns 403 (expected — no auth token) |
| DynamoDB tables (Lease, LeaseTemplate, SandboxAccount) | Preserved (no schema changes) |
| IDC users/groups | Untouched |
| Active leases | Preserved (verified via stack output unchanged) |

---

## Commands Used

```bash
# AccountPool (mgmt account)
export AWS_PROFILE=eta-andrian
npm run deploy:account-pool

# Data (hub account)
export AWS_PROFILE=eta-isb-andrian
npm run deploy:data

# IDC (mgmt account)
export AWS_PROFILE=eta-andrian
npm run deploy:idc

# Compute (hub account)
export AWS_PROFILE=eta-isb-andrian
npm run deploy:compute
```

## Verification Checklist

- [x] AccountPool stack updated successfully (SCPs + StackSet refreshed)
- [x] Data stack updated (DynamoDB tables preserved, AppConfig refreshed)
- [x] IDC stack updated (user access preserved)
- [x] Compute stack updated (28 Lambdas + frontend deployed, CloudFront invalidated)
- [x] Web app loads at CloudFront URL with new bundle
- [x] API endpoint reachable
- [ ] Manual login flow test (Andrian to verify)
- [ ] Lease creation/freeze test (Andrian to verify)
- [ ] Stuck-lease termination on next monitoring cycle (auto, ~hourly)

---

## Notes

- All four stacks updated in-place. No resource recreation. No data loss risk.
- Pre-deploy: rebased onto upstream v1.2.10, resolved one `package-lock.json` conflict by accepting upstream (canonical lockfile).
- Vite build emitted 5 warnings about `amazon-cognito-identity-js` importing named exports from `js-cookie`'s ESM build. These are pre-existing (existed in v1.2.9 too) and don't affect runtime — vite still bundles correct code. Upstream issue.
- Custom local commits preserved (Bedrock SCP changes, university onboarding scripts, kiro-lease setup, BEDROCK-RATE-LIMITING-PLAN). None affected the deployment artifacts.
- New regions added in upstream layer ARN map (`ap-east-2`, `ap-southeast-6`, `ap-southeast-7`, `mx-central-1`) — N/A for our deployment (`ap-southeast-1`).
