# Operations Documentation

| Doc | Description |
|-----|-------------|
| [LESSONS-LEARNED.md](LESSONS-LEARNED.md) | All lessons from production deployment |
| [DEPLOYMENT-LOG-v1.2.8.md](DEPLOYMENT-LOG-v1.2.8.md) | v1.2.8 deployment record |
| [guides/](guides/) | User management & team sharing guides |
| [troubleshooting/](troubleshooting/) | FAQ & quarantine fixes |

---

## Bedrock Rate Limiter — Operations SOP

### Quick Reference Commands

```bash
# List currently throttled accounts
./scripts/cost-controls/list-throttled-accounts.sh          # human-readable
./scripts/cost-controls/list-throttled-accounts.sh -q       # account IDs only

# Unfreeze a specific account (clears throttle + removes deny policy)
./scripts/cost-controls/unfreeze-bedrock.sh <account-id>

# EMERGENCY: throttle ALL sandbox accounts immediately
./scripts/cost-controls/kill-switch-bedrock.sh              # default 1h duration
./scripts/cost-controls/kill-switch-bedrock.sh --duration 7200   # custom (seconds)

# Investigate a specific account's throttle history
./scripts/cost-controls/check-bedrock-incident.sh <account-id>
```

### Alert Response SOP — Throttle Email Received

When you receive a `[ISB] Bedrock throttle activated` email from the admin SNS topic:

1. **Acknowledge** — no immediate action required; the auto-throttle already attached a deny policy to the offending account's `IsbUsers` role.
2. **Verify** the throttle is active:
   ```bash
   ./scripts/cost-controls/list-throttled-accounts.sh
   ```
3. **Investigate** if needed (check who/what triggered the burst):
   ```bash
   ./scripts/cost-controls/check-bedrock-incident.sh <account-id>
   ```
4. **Wait for auto-recovery** — the throttle expires after 1 hour (EventBridge → Recovery Lambda). No manual action needed unless you want to extend or clear early.
5. **If the user contacts you** requesting early unfreeze:
   ```bash
   ./scripts/cost-controls/unfreeze-bedrock.sh <account-id>
   ```
6. **If multiple accounts are spiking** (coordinated or systemic issue), use the kill switch and investigate root cause:
   ```bash
   ./scripts/cost-controls/kill-switch-bedrock.sh
   ```

### When to Run `subscribe-member-topics.sh`

Run this script **after new sandbox accounts join the pool** (e.g., after `create-sandbox-accounts.sh` or `bulk-register-accounts.sh`):

```bash
./scripts/cost-controls/subscribe-member-topics.sh
```

This subscribes the hub-account throttle Lambda to each new member account's SNS topic (`isb-<ns>-bedrock-throttle-trigger`). Without this step, new accounts will **not** be monitored by the rate limiter.

> **Tip:** Add this as a post-step in your account provisioning runbook to avoid gaps in coverage.
