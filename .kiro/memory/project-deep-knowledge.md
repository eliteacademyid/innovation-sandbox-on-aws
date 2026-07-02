# Innovation Sandbox on AWS — Deep Project Knowledge

## Identity
- **Name**: Innovation Sandbox on AWS (SO0284)
- **Version**: 1.2.12 (deployed 2 Jul 2026)
- **Organization**: Elitery / Elite Academy (CendekiAwan program)
- **License**: Apache-2.0
- **Path**: /Users/andrianmaulana/elitery/projects/innovation-sandbox-on-aws
- **Runtime**: Node 22, TypeScript, AWS CDK v2, Vite (frontend)
- **Test**: Vitest + aws-sdk-client-mock
- **Monorepo**: npm workspaces

## Purpose
Platform sandbox AWS untuk program pendidikan CendekiAwan (Elite Academy). Memberikan temporary AWS account ke mahasiswa/peserta workshop dengan auto-provisioning, auto-cleanup (AWS Nuke), governance via SCP/budget/rate-limiting, dan web UI.

## Multi-Account Architecture
- **Management Account (862099794180)**: AWS Organizations + IAM Identity Center + AccountPool Stack + IDC Stack + Org SCP Manager Role
- **Hub Account (147826551593)**: Data Stack (DynamoDB, AppConfig, S3) + Compute Stack (Lambda, API GW, CloudFront, Step Functions) + Bedrock Rate Limiter + Bedrock Model Router
- **100 Sandbox Accounts** (Pool OU: ou-e21c-9df44eh0, Entry OU: ou-e21c-cz4ntm1j)
- Regions: us-east-1, us-west-2, ap-southeast-1, ap-southeast-3, ap-southeast-5
- Budget: $10/lease, freeze $45-50, Lease duration: 48 hours

## 4 CDK Stacks
1. **AccountPool** (Management) — OU management, account registration, SCPs
2. **IDC** (Management) — SSO groups, permission sets
3. **Data** (Hub) — DynamoDB tables (accounts, leases, lease-templates), AppConfig, S3
4. **Compute** (Hub) — API Gateway, Lambda, Step Functions, CloudFront, CodeBuild (Nuke), WAF

## Source Structure
- `source/frontend` — React + Vite SPA (Cloudscape Design System)
- `source/infrastructure` — CDK app (4 stacks)
- `source/common` — Shared types, SDK clients, utilities, domain logic (InnovationSandbox facade class)
- `source/lambdas/api` — REST handlers (accounts, leases, blueprints, lease-templates, authorizer, sso-handler, configurations)
- `source/lambdas/account-management` — Account lifecycle
- `source/lambdas/account-cleanup` — AWS Nuke orchestration
- `source/lambdas/blueprint-deployment` — StackSet deployment
- `source/lambdas/notification` — Email/notification
- `source/lambdas/metrics` — Operational metrics
- `source/layers` — Lambda layers (shared deps)

## Domain Model

### SandboxAccount
- Statuses: `Available` → `Active` → `CleanUp` → `Quarantine`
- Fields: awsAccountId, email, name, driftAtLastScan, status
- Current pool: 100 accounts (95 Available, 5 Active as of 2 Jul 2026)

### Lease
- Statuses: `Requested` → `Active` → `Frozen` → `Expired`/`Terminated`/`Denied`
- Fields: leaseId (UUID), userId, accountId, leaseTemplateId, budgetUsed

### LeaseTemplate
- Fields: id, name, maxBudget, maxDuration, blueprintId, autoApproval

### Blueprint
- CFN StackSet template body registered as managed CloudFormation StackSets

## Event-Driven Architecture (EventBridge)
Key events: LeaseRequestedEvent, LeaseApprovedEvent, LeaseFrozenEvent, LeaseTerminatedEvent, AccountQuarantinedEvent, CleanAccountRequest, BlueprintDeploymentRequest

## Security Model (5 Layers)
1. **IAM Identity Center (SSO)** — Groups: IsbAdmins, IsbManagers, IsbUsers
2. **5 SCPs** — protect ISB resources, restrictions, service allowlist, write protection, region lock
3. **OU Drift Detection** — Lambda quarantines accounts moved out of expected OU
4. **Budget Controls** — Auto-freeze at threshold
5. **Bedrock Rate Limiter (SCP-based)** — CloudWatch → SNS → Hub Lambda → creates deny-Bedrock SCP per account, auto-recovery 1h

## Custom Extensions (Elitery-Specific)
- **Bedrock Rate Limiter** (`infra/cost-controls/bedrock-rate-limit/`) — SCP-based throttling (migrated from IAM inline policy June 2026)
- **Bedrock Model Router** (`infra/cost-controls/bedrock-model-router/`) — Complexity-based routing (Nova Pro for simple, Claude Sonnet for complex)
- **Blueprints**: cendekiawan-genai.yaml, cendekiawan-genai-sandbox.yaml, aiml-sandbox.yaml
- **University batch onboarding** (`scripts/user-management/full-university-onboarding.sh`)
- **Team sandbox sharing** (team-sandbox-share.sh) — multiple users → 1 account via IDC group
- **Cost controls kill-switch** (kill-switch-bedrock.sh)
- **Health monitoring** scripts (health-check.sh, check-account-pool-status.sh)
- **Welcome emails** via SES (send-welcome-emails.py)
- **SCP configs** (`config/scp/`) — 5 production policies

## Key URLs (Production)
- Web App: https://aws-sandbox.eliteacademy.id (custom domain)
- CloudFront: https://dd3kj1ggdvsy3.cloudfront.net
- SSO Portal: https://d-9667a833b5.awsapps.com/start
- API: https://ob90f1sd45.execute-api.ap-southeast-1.amazonaws.com/prod/
- Identity Store ID: d-9667a833b5
- SSO Instance ARN: arn:aws:sso:::instance/ssoins-821055714a3e49c5
- Deploy Region: ap-southeast-1

## .env Configuration
- HUB_ACCOUNT_ID=147826551593
- NAMESPACE=myisb
- PARENT_OU_ID=r-e21c
- AWS_REGIONS=us-east-1,us-west-2,ap-southeast-3,ap-southeast-1,ap-southeast-5
- IDENTITY_STORE_ID=d-9667a833b5
- ORG_MGT_ACCOUNT_ID=862099794180
- IDC_ACCOUNT_ID=862099794180

## DynamoDB Tables (actual names)
- Accounts: `InnovationSandbox-Data-SandboxAccountTableEFB9C069-16YC6RUKNE15K`
- Leases: `InnovationSandbox-Data-LeaseTable473C6DF2-2KGOUCRMIVP9`
- Lease Templates: `InnovationSandbox-Data-LeaseTemplateTable5128F8F4-1V51RSU3M18W8`
- Throttle Events: `isb-myisb-bedrock-throttle-events`
- Prompt Cache (model router): `isb-myisb-bedrock-prompt-cache`

## Operational Commands
- Deploy all: `npm run deploy:all`
- Deploy compute: `npm run deploy:compute`
- Add accounts: `scripts/account-management/create-sandbox-accounts.sh` + `register-accounts-to-pool.sh`
- Add users: `scripts/user-management/create-users-and-assign-leases.sh users.csv TEMPLATE_ID`
- University batch: `scripts/user-management/full-university-onboarding.sh`
- Health check: `scripts/monitoring/health-check.sh`
- List throttled: `scripts/cost-controls/list-throttled-accounts.sh`
- Unfreeze: `scripts/cost-controls/unfreeze-bedrock.sh <account-id>`
- Kill switch: `scripts/cost-controls/kill-switch-bedrock.sh`
- Subscribe new accounts: `scripts/cost-controls/subscribe-member-topics.sh`
- Deploy model router: `scripts/cost-controls/deploy-bedrock-model-router.sh`
- Destroy: `npm run destroy:all`

## Bedrock Rate Limiter Architecture (SCP-based, as of June 2026)
```
Sandbox Account: CloudWatch alarms (TPM>100K, RPM>60) → SNS topic (no KMS)
                      ↓ subscription
Hub Account: Throttle Lambda → assumes org role in mgmt account
                      ↓
Management Account: Creates SCP (isb-myisb-bedrock-deny-{accountId}) → attaches to account
Recovery: EventBridge every 5min → Recovery Lambda → detaches + deletes SCP
```
- Org Role: `arn:aws:iam::862099794180:role/isb-myisb-bedrock-org-scp-manager`
- Trust: only hub Lambda roles (throttle-handler + recovery-handler)
- Permissions: organizations:CreatePolicy/DeletePolicy/AttachPolicy/DetachPolicy/ListPolicies/DescribePolicy
- StackSet: `isb-myisb-bedrock-rate-limit-member` (service-managed, 7 OUs, 100 accounts)
- Kill-switch: freeze ALL sandboxes at once (emergency)
- Why SCP not IAM: AWS protects AWSReservedSSO_* roles as UnmodifiableEntity; SCP doesn't need cross-account IAM in sandboxes

## Bedrock Model Router (code complete, not yet deployed)
- Lambda: complexity-based routing (heuristic classifier)
- Simple → Amazon Nova Pro (us-east-1, cheapest)
- Complex → Claude Sonnet 3.5 (round-robin: us-east-1, us-west-2, eu-west-1)
- DynamoDB prompt cache with 24h TTL
- Stack: `infra/cost-controls/bedrock-model-router/stack.yaml`
- Deploy: `./scripts/cost-controls/deploy-bedrock-model-router.sh`

## Key Lessons Learned
1. Nuke config must filter org-managed resources (CloudTrail, IAM service roles) BEFORE registration
2. Never add custom fields to DynamoDB — strict schema validation drops records from UI
3. OU drift = #1 cause of Quarantine
4. SAML attributes must be minimal (Subject, email, name only) to avoid CloudFront 8KB header limit
5. Pool size formula: 1.3× concurrent users
6. Cleanup takes 10-15 min per account
7. ap-southeast-5 has limited service support (noisy but non-fatal)
8. Enable opt-in regions BEFORE registering accounts
9. Keep ISB updated — security patches every 1-2 weeks
10. Use short namespace to avoid CFN name length limits
11. CloudWatch Alarms CANNOT publish to SNS with alias/aws/sns KMS encryption (no kms:GenerateDataKey grant)
12. AWS protects AWSReservedSSO_* roles — cannot attach inline policies (UnmodifiableEntity)
13. SCP-based throttling is cleaner than IAM — managed from hub, no cross-account IAM needed in sandboxes
14. StackSet updates need CAPABILITY_NAMED_IAM if template has named IAM roles
15. After StackSet recreates SNS topics, must re-run subscribe-member-topics.sh

## Frontend Tech
- React 18 + Cloudscape Design System + Vite + TanStack React Query + React Router + SCSS Modules
- Domains: accounts, leases, leaseTemplates, blueprints, settings, home
- Auth: SSO OIDC JWT tokens, Lambda Authorizer (role-based)

## AWS Profiles Used
- `eta-andrian` (management account 862099794180)
- `eta-isb-andrian` (hub account 147826551593)
- `elite-academy` (general)

## Account Lifecycle Flow
1. Register account → status: CleanUp → AWS Nuke runs
2. Nuke success → Available (in pool)
3. User requests lease → Approved → Account assigned → Active
4. Blueprint deployed via StackSet → User gets SSO access
5. Lease expires/terminated → SSO revoked → CleanUp → Nuke → Available (recycled)

## Deployment History
- v1.2.7: Initial production deployment (April 2026)
- v1.2.8: Fix lease termination when user deleted from IDC (May 2026)
- v1.2.9: fast-uri CVE fix (May 2026)
- v1.2.10: js-cookie, uuid CVE fixes (May 2026)
- v1.2.11: BudgetProgressBar fix + react-router CVE (June 2026)
- v1.2.12: Security release — openssl (5 CVEs), golang, jq, python3-pip, vite, form-data (deployed 2 Jul 2026)

## Incident History
- May 22, 2026: Anonymous budget overrun (documented in docs/incidents/)
- 87 cleanup failures from non-existent CloudTrail trail (fixed via nuke config filter)
- 7/10 accounts quarantined on first registration (OU drift — fixed by moving to Entry OU)
- June 18, 2026: Rate limiter architecture change — IAM inline → SCP-based (SSO roles are UnmodifiableEntity)
