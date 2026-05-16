#!/usr/bin/env python3
"""
Send welcome emails to Innovation Sandbox users.

Usage:
    python3 scripts/user-management/send-welcome-emails.py <csv-file> <config-file> [template-file]
    python3 scripts/user-management/send-welcome-emails.py --dry-run <csv-file> <config-file> [template-file]

CSV Format (with header):
    email,firstName
    user1@example.com,Alice
    user2@example.com,Bob

Config file (JSON):
    {
        "apiEndpoint": "https://dd3kj1ggdvsy3.cloudfront.net/api",
        "jwtToken": "eyJ...",
        "isbPortal": "https://dd3kj1ggdvsy3.cloudfront.net",
        "fromEmail": "admin@example.com",
        "awsProfile": "my-profile",
        "awsRegion": "ap-southeast-1",
        "programName": "My Program",
        "organization": "My Org",
        "supportEmail": "support@example.com",
        "emailSubject": "Your Innovation Sandbox is Ready!"
    }
"""

import csv
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
import subprocess
from datetime import datetime


def load_config(config_path):
    """Load configuration from JSON file."""
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_template(template_path):
    """Load the HTML email template."""
    with open(template_path, "r", encoding="utf-8") as f:
        return f.read()


def read_users_csv(csv_path):
    """Read users from CSV file."""
    users = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if "email" not in reader.fieldnames:
            raise ValueError("CSV must have 'email' column")
        if "firstName" not in reader.fieldnames:
            raise ValueError("CSV must have 'firstName' column")
        for row in reader:
            email = row.get("email", "").strip()
            first_name = row.get("firstName", "").strip()
            if email and first_name:
                users.append({"email": email, "firstName": first_name})
    return users


def get_lease_info(email, config):
    """Get lease details for a user from the API."""
    url = f"{config['apiEndpoint']}/leases?userEmail={urllib.parse.quote(email)}&pageSize=1"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {config['jwtToken']}"}
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = json.loads(r.read().decode())
            results = data.get("data", {}).get("result", [])
            if results:
                return results[0]
    except Exception as e:
        print(f"  ⚠️  Error getting lease info: {e}")
    return None


def render_template(template, user, lease, config):
    """Replace placeholders in the template with actual values."""
    email = user["email"]
    first_name = user["firstName"]
    account_id = lease.get("awsAccountId", "Pending")
    template_name = lease.get("originalLeaseTemplateName", "N/A")
    duration = lease.get("leaseDurationInHours", 0)
    expiry_raw = lease.get("expirationDate", "N/A")
    max_spend = lease.get("maxSpend", 0)
    approved_by = lease.get("approvedBy", "N/A")

    # Parse thresholds
    budget_thresholds = lease.get("budgetThresholds", [])
    duration_thresholds = lease.get("durationThresholds", [])
    budget_alert = next(
        (t["dollarsSpent"] for t in budget_thresholds if t.get("action") == "ALERT"), 0
    )
    budget_freeze = next(
        (t["dollarsSpent"] for t in budget_thresholds if t.get("action") == "FREEZE_ACCOUNT"), 0
    )
    duration_alert = next(
        (t["hoursRemaining"] for t in duration_thresholds if t.get("action") == "ALERT"), 0
    )
    duration_freeze = next(
        (t["hoursRemaining"] for t in duration_thresholds if t.get("action") == "FREEZE_ACCOUNT"), 0
    )

    # Format expiry date
    expiry = expiry_raw
    if expiry_raw and expiry_raw != "N/A":
        try:
            dt = datetime.fromisoformat(expiry_raw.replace("Z", "+00:00"))
            expiry = dt.strftime("%B %d, %Y %H:%M UTC")
        except Exception:
            pass

    # Replace all placeholders
    html = template
    html = html.replace("{{FIRST_NAME}}", first_name)
    html = html.replace("{{ISB_PORTAL}}", config["isbPortal"])
    html = html.replace("{{EMAIL}}", email)
    html = html.replace("{{ACCOUNT_ID}}", str(account_id))
    html = html.replace("{{LEASE_TEMPLATE_NAME}}", template_name)
    html = html.replace("{{DURATION}}", str(duration))
    html = html.replace("{{EXPIRY}}", expiry)
    html = html.replace("{{MAX_SPEND}}", str(max_spend))
    html = html.replace("{{APPROVED_BY}}", approved_by)
    html = html.replace("{{BUDGET_ALERT}}", str(budget_alert))
    html = html.replace("{{BUDGET_FREEZE}}", str(budget_freeze))
    html = html.replace("{{DURATION_ALERT_HOURS}}", str(duration_alert))
    html = html.replace("{{DURATION_FREEZE_HOURS}}", str(duration_freeze))
    html = html.replace("{{PROGRAM_NAME}}", config["programName"])
    html = html.replace("{{SUPPORT_EMAIL}}", config["supportEmail"])
    html = html.replace("{{ORGANIZATION}}", config["organization"])

    return html


def send_email_ses(to_email, subject, html_body, config):
    """Send email using AWS SES via CLI."""
    message = {
        "Subject": {"Data": subject, "Charset": "UTF-8"},
        "Body": {
            "Html": {"Data": html_body, "Charset": "UTF-8"},
            "Text": {
                "Data": f"Your Innovation Sandbox on AWS is ready! Login at {config['isbPortal']} with your email: {to_email}",
                "Charset": "UTF-8",
            },
        },
    }

    cmd = [
        "aws", "ses", "send-email",
        "--from", config["fromEmail"],
        "--destination", json.dumps({"ToAddresses": [to_email]}),
        "--message", json.dumps(message),
        "--profile", config["awsProfile"],
        "--region", config["awsRegion"],
        "--output", "json",
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        msg_id = json.loads(result.stdout).get("MessageId", "unknown")
        return True, msg_id
    else:
        return False, result.stderr.strip()


def main():
    # Parse --dry-run flag
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv

    if len(args) < 2:
        print("Usage: python3 send-welcome-emails.py [--dry-run] <csv-file> <config-file> [template-file]")
        print()
        print("Options:")
        print("  --dry-run    Preview emails without sending")
        print()
        print("CSV format (with header):")
        print("  email,firstName")
        print("  user1@example.com,Alice")
        print()
        print("Config file (JSON) - see script header for full schema")
        print()
        print("Template file (optional):")
        print("  Defaults to scripts/templates/email-welcome.html")
        sys.exit(1)

    csv_path = args[0]
    config_path = args[1]
    template_path = args[2] if len(args) > 2 else None

    # Load config
    try:
        config = load_config(config_path)
    except FileNotFoundError:
        print(f"❌ Config file not found: {config_path}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ Invalid JSON in config file: {e}")
        sys.exit(1)

    # Validate required config keys
    required_keys = [
        "apiEndpoint", "jwtToken", "isbPortal", "fromEmail",
        "awsProfile", "awsRegion", "programName", "organization",
        "supportEmail", "emailSubject"
    ]
    missing = [k for k in required_keys if k not in config]
    if missing:
        print(f"❌ Missing config keys: {', '.join(missing)}")
        sys.exit(1)

    # Load template
    if not template_path:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        template_path = os.path.join(script_dir, "..", "templates", "email-welcome.html")

    try:
        template = load_template(template_path)
    except FileNotFoundError:
        print(f"❌ Template file not found: {template_path}")
        sys.exit(1)

    # Load users
    try:
        users = read_users_csv(csv_path)
    except FileNotFoundError:
        print(f"❌ CSV file not found: {csv_path}")
        sys.exit(1)
    except ValueError as e:
        print(f"❌ {e}")
        sys.exit(1)

    if not users:
        print("❌ No users found in CSV file")
        sys.exit(1)

    # Summary
    mode_label = "[DRY RUN] " if dry_run else ""
    print("=" * 60)
    print(f"{mode_label}Send Welcome Emails - Innovation Sandbox on AWS")
    print("=" * 60)
    print(f"CSV File:      {csv_path}")
    print(f"Config:        {config_path}")
    print(f"Template:      {template_path}")
    print(f"Total Users:   {len(users)}")
    print(f"From:          {config['fromEmail']}")
    print(f"Program:       {config['programName']}")
    print(f"Organization:  {config['organization']}")
    print(f"Portal:        {config['isbPortal']}")
    if dry_run:
        print(f"Mode:          DRY RUN (no emails will be sent)")
    print("=" * 60)
    print()

    if not dry_run:
        # Confirm
        confirm = input(f"Send emails to {len(users)} users? (yes/no): ").strip().lower()
        if confirm not in ["yes", "y"]:
            print("Cancelled.")
            sys.exit(0)

    print()
    success_count = 0
    fail_count = 0

    for idx, user in enumerate(users, 1):
        email = user["email"]
        print(f"[{idx}/{len(users)}] {'[DRY RUN] ' if dry_run else ''}Sending to: {email}")

        # Get lease info
        lease = get_lease_info(email, config)
        if not lease:
            print("  ⚠️  No lease info found, using defaults")
            lease = {}

        # Render
        html = render_template(template, user, lease, config)

        if dry_run:
            account_id = lease.get("awsAccountId", "Pending")
            expiry = lease.get("expirationDate", "N/A")
            max_spend = lease.get("maxSpend", "N/A")
            duration = lease.get("leaseDurationInHours", "N/A")
            template_name = lease.get("originalLeaseTemplateName", "N/A")
            status = lease.get("status", "N/A")
            approved_by = lease.get("approvedBy", "N/A")
            start_date = lease.get("startDate", "N/A")
            print(f"  📧 To: {email}")
            print(f"  📧 Subject: {config['emailSubject']}")
            print(f"  📧 Account: {account_id}")
            print(f"  📧 Status: {status}")
            print(f"  📧 Template: {template_name}")
            print(f"  📧 Duration: {duration}h")
            print(f"  📧 Budget: ${max_spend} USD")
            print(f"  📧 Start: {start_date}")
            print(f"  📧 Expiry: {expiry}")
            print(f"  📧 Approved By: {approved_by}")
            print(f"  📧 Rendered: {len(html)} chars")
            print(f"  ✅ [DRY RUN] Would send email")
            success_count += 1
        else:
            success, msg = send_email_ses(email, config["emailSubject"], html, config)
            if success:
                print(f"  ✅ Sent (MessageId: {msg})")
                success_count += 1
            else:
                print(f"  ❌ Failed: {msg}")
                fail_count += 1

        time.sleep(0.3)

    # Results
    print()
    print("=" * 60)
    print(f"{mode_label}Complete")
    print("=" * 60)
    print(f"Total:   {len(users)}")
    print(f"Success: {success_count}")
    print(f"Failed:  {fail_count}")
    print("=" * 60)


if __name__ == "__main__":
    main()
