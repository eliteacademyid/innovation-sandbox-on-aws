#!/usr/bin/env python3
"""
Send Welcome Emails to University Team Members via SES (ap-southeast-3)

Usage:
    # Dry run (prints emails without sending)
    python3 scripts/user-management/send-welcome-emails.py emails.csv --dry-run

    # Send emails (also sends copy to admin)
    python3 scripts/user-management/send-welcome-emails.py emails.csv --send

CSV Format (with header):
    team_name,email,first_name,last_name,role,account_id,password,university,budget,duration,expiry_date,regions,freeze_threshold

Example:
    team_name,email,first_name,last_name,role,account_id,password,university,budget,duration,expiry_date,regions,freeze_threshold
    dewan-ai,WONG.SHIN.CHEN1@student.mmu.edu.my,Wong,Shin Chen,Team Leader,123456789012,TempPass1!,MMU,$50,30 days,June 28 2026,"us-east-1, ap-southeast-1, ap-southeast-3, ap-southeast-5",$45
"""

import boto3
import csv
import json
import sys
import time
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────────────────────
SES_REGION = "ap-southeast-3"
FROM_EMAIL = "helpdesk@eliteacademy.id"
ADMIN_COPY_EMAIL = "andrian@eliteacademy.id"
AWS_PROFILE = "eta-andrian"
TEMPLATE_FILE = "scripts/templates/welcome-sandbox.html"

# ── Load Template ─────────────────────────────────────────────────────────────
def load_template():
    template_path = Path(__file__).parent.parent / "templates" / "welcome-sandbox.html"
    if not template_path.exists():
        # Try relative to cwd
        template_path = Path(TEMPLATE_FILE)
    if not template_path.exists():
        print(f"❌ Template not found: {template_path}")
        sys.exit(1)
    return template_path.read_text()


def render_template(template: str, row: dict) -> str:
    """Replace {{VARIABLE}} placeholders with values from CSV row."""
    name = f"{row['first_name']} {row['last_name']}"
    html = template
    html = html.replace("{{NAME}}", name)
    html = html.replace("{{EMAIL}}", row["email"])
    html = html.replace("{{PASSWORD}}", row.get("password", "See IDC Console"))
    html = html.replace("{{UNIVERSITY}}", row.get("university", ""))
    html = html.replace("{{TEAM_NAME}}", row.get("team_name", ""))
    html = html.replace("{{ROLE}}", row.get("role", "Team Member"))
    html = html.replace("{{ACCOUNT_ID}}", row.get("account_id", "TBD"))
    html = html.replace("{{BUDGET}}", row.get("budget", "$50"))
    html = html.replace("{{DURATION}}", row.get("duration", "30 days"))
    html = html.replace("{{EXPIRY_DATE}}", row.get("expiry_date", "TBD"))
    html = html.replace("{{REGIONS}}", row.get("regions", "us-east-1, ap-southeast-1, ap-southeast-3, ap-southeast-5"))
    html = html.replace("{{FREEZE_THRESHOLD}}", row.get("freeze_threshold", "$45 (alert at $40)"))
    return html


def send_email(ses_client, to_email: str, subject: str, html_body: str, cc_admin: bool = True):
    """Send email via SES."""
    destination = {"ToAddresses": [to_email]}
    if cc_admin and to_email != ADMIN_COPY_EMAIL:
        destination["BccAddresses"] = [ADMIN_COPY_EMAIL]

    response = ses_client.send_email(
        FromEmailAddress=FROM_EMAIL,
        Destination=destination,
        Content={
            "Simple": {
                "Subject": {"Data": subject},
                "Body": {
                    "Html": {"Data": html_body},
                    "Text": {"Data": f"Your AWS Sandbox is ready! Login at https://eliteacademy.awsapps.com/start with email: {to_email}"}
                }
            }
        }
    )
    return response.get("MessageId")


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 send-welcome-emails.py <csv-file> [--dry-run | --send]")
        print("")
        print("Options:")
        print("  --dry-run   Preview emails without sending")
        print("  --send      Send emails (BCC copy to admin)")
        sys.exit(1)

    csv_file = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "--dry-run"
    dry_run = mode == "--dry-run"

    # Load CSV
    try:
        with open(csv_file, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
    except FileNotFoundError:
        print(f"❌ CSV file not found: {csv_file}")
        sys.exit(1)

    if not rows:
        print("❌ No rows in CSV")
        sys.exit(1)

    # Load template
    template = load_template()

    # Setup SES client
    if not dry_run:
        session = boto3.Session(profile_name=AWS_PROFILE, region_name=SES_REGION)
        ses_client = session.client("sesv2")
    else:
        ses_client = None

    # Process
    university = rows[0].get("university", "")
    print("=" * 60)
    print(f"{'DRY RUN' if dry_run else 'SENDING'} Welcome Emails")
    print("=" * 60)
    print(f"From: {FROM_EMAIL}")
    print(f"BCC:  {ADMIN_COPY_EMAIL}")
    print(f"Region: {SES_REGION}")
    print(f"University: {university}")
    print(f"Recipients: {len(rows)}")
    print("=" * 60)
    print("")

    success = 0
    failed = 0

    for i, row in enumerate(rows, 1):
        email = row["email"].strip()
        name = f"{row['first_name']} {row['last_name']}"
        team = row.get("team_name", "")
        subject = f"🎉 Your AWS Sandbox is Ready — CendekiAwan {university} Finalist"

        html_body = render_template(template, row)

        if dry_run:
            print(f"  [{i}/{len(rows)}] 📧 {email}")
            print(f"         Name: {name} | Team: {team} | Role: {row.get('role','')}")
            print(f"         Account: {row.get('account_id','TBD')} | Password: {row.get('password','N/A')}")
            print("")
            success += 1
        else:
            try:
                msg_id = send_email(ses_client, email, subject, html_body)
                print(f"  [{i}/{len(rows)}] ✅ {email} — {msg_id}")
                success += 1
            except Exception as e:
                print(f"  [{i}/{len(rows)}] ❌ {email} — {e}")
                failed += 1
            time.sleep(0.5)  # Rate limit

    print("")
    print("=" * 60)
    print(f"{'DRY RUN' if dry_run else 'SENT'} Complete")
    print(f"Success: {success} | Failed: {failed}")
    print("=" * 60)

    if dry_run:
        print("")
        print("To send for real, run:")
        print(f"  python3 {sys.argv[0]} {csv_file} --send")


if __name__ == "__main__":
    main()
