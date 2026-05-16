# SCP Configuration (Production)

Saved: 2026-05-12
Environment: CendekiAwan APU Finalist (ap-southeast-1)

## Active SCPs

| # | Policy ID | Name | File | Statements |
|---|-----------|------|------|-----------|
| 1 | p-4p75t89y | InnovationSandboxProtectISBResourcesScp | [scp/protect-isb-resources.json](protect-isb-resources.json) | 5 |
| 2 | p-qn5f2vtd | InnovationSandboxRestrictionsScp | [scp/restrictions.json](restrictions.json) | 3 |
| 3 | p-cpq9rpbq | InnovationSandboxAwsNukeSupportedServicesScp | [scp/service-allowlist.json](service-allowlist.json) | 1 |
| 4 | p-1lb4bh9n | InnovationSandboxWriteProtectionScp | [scp/write-protection.json](write-protection.json) | 1 |
| 5 | p-vsndsymc | InnovationSandboxLimitRegionsScp | [scp/limit-regions.json](limit-regions.json) | 1 |

## Security Model

- **Full admin access** to all AWS services
- **Denied:** Account/org settings, billing modification, RI/Savings Plan purchases
- **Allowed:** Cost Explorer (read-only), IAM (full), all services
- **Protected:** ISB control plane roles, Control Tower resources, SSO config
- **Regions:** us-east-1, ap-southeast-1, ap-southeast-3, ap-southeast-5
- **Budget:** Auto-freeze at $45/$50
