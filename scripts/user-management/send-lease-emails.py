#!/usr/bin/env python3
"""
Bulk assign leases via ISB API and send email notifications.
Usage: python3 scripts/send-lease-emails.py
"""

import boto3
import csv
import json
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────
API_ENDPOINT   = "https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod"
LEASE_TEMPLATE = "4f20eae7-4ac4-4778-9318-976ef1189331"  # cendekiawan-apu-tot-lt
USERS_CSV      = "cendekiawan-tot-users.csv"
ISB_PORTAL     = "https://aws-sandbox.eliteacademy.id"
FROM_EMAIL     = "helpdesk@eliteacademy.id"
SES_PROFILE    = "eta-andrian"
SES_REGION     = "ap-southeast-1"
EMAIL_TEMPLATE = "scripts/email-template.html"

# ── JWT Token ─────────────────────────────────────────────────────────────────
JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyIjp7ImRpc3BsYXlOYW1lIjoiYW5kcmlhbiBtYXVsYW5hIiwidXNlck5hbWUiOiJhbmRyaWFuQGVsaXRlYWNhZGVteS5pZCIsImVtYWlsIjoiYW5kcmlhbkBlbGl0ZWFjYWRlbXkuaWQiLCJyb2xlcyI6WyJBZG1pbiJdfSwiaWF0IjoxNzc3NjcxNzI2LCJleHAiOjE3Nzc2NzUzMjZ9.1FntfUyL7j6ZDIaEz439u4UdQ-ijmVyFkOqcLAsJtS0"

def api_post(path, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{API_ENDPOINT}{path}",
        data=data,
        headers={
            "Authorization": f"Bearer {JWT}",
            "Content-Type": "application/json"
        },
        method="POST"
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())

def format_expiry(iso_str):
    try:
        dt = datetime.strptime(iso_str, "%Y-%m-%dT%H:%M:%S.%fZ")
        return dt.strftime("%d %B %Y, %H:%M UTC")
    except:
        return iso_str

def send_email(ses, to_email, first_name, account_id, expiry, lease_data=None):
    with open(EMAIL_TEMPLATE) as f:
        html = f.read()

    lease_data = lease_data or {}
    html = html.replace("{{FIRST_NAME}}", first_name)
    html = html.replace("{{EMAIL}}", to_email)
    html = html.replace("{{ACCOUNT_ID}}", account_id)
    html = html.replace("{{EXPIRY}}", format_expiry(expiry))
    html = html.replace("{{ISB_PORTAL}}", ISB_PORTAL)
    html = html.replace("{{LEASE_TEMPLATE_NAME}}", lease_data.get("originalLeaseTemplateName", "cendekiawan-apu-tot-lt"))
    html = html.replace("{{DURATION}}", str(lease_data.get("leaseDurationInHours", 48)))
    html = html.replace("{{MAX_SPEND}}", str(lease_data.get("maxSpend", 10)))
    html = html.replace("{{APPROVED_BY}}", lease_data.get("approvedBy", "AUTO_APPROVED"))
    # Replace static placeholders in First Time Login section
    html = html.replace("PORTAL_PLACEHOLDER", ISB_PORTAL)
    html = html.replace("EMAIL_PLACEHOLDER", to_email)

    # Extract budget thresholds from lease data
    budget_thresholds = lease_data.get("budgetThresholds", [])
    budget_alert  = next((t["dollarsSpent"] for t in budget_thresholds if t.get("action") == "ALERT"), "—")
    budget_freeze = next((t["dollarsSpent"] for t in budget_thresholds if t.get("action") == "FREEZE_ACCOUNT"), "—")

    # Extract duration thresholds from lease data
    duration_thresholds = lease_data.get("durationThresholds", [])
    duration_alert  = next((t["hoursRemaining"] for t in duration_thresholds if t.get("action") == "ALERT"), "—")
    duration_freeze = next((t["hoursRemaining"] for t in duration_thresholds if t.get("action") == "FREEZE_ACCOUNT"), "—")

    html = html.replace("{{BUDGET_ALERT_USD}}", str(budget_alert))
    html = html.replace("{{BUDGET_FREEZE_USD}}", str(budget_freeze))
    html = html.replace("{{DURATION_ALERT_HOURS}}", str(duration_alert))
    html = html.replace("{{DURATION_FREEZE_HOURS}}", str(duration_freeze))

    resp = ses.send_email(
        FromEmailAddress=FROM_EMAIL,
        Destination={"ToAddresses": [to_email]},
        Content={
            "Simple": {
                "Subject": {"Data": "Your AWS GenAI Sandbox is Ready - Cendekiawan ToT", "Charset": "UTF-8"},
                "Body": {"Html": {"Data": html, "Charset": "UTF-8"}}
            }
        }
    )
    return resp["MessageId"]

def main():
    print("╔══════════════════════════════════════════════════════════╗")
    print("║   Bulk Lease Assignment + Email Notification             ║")
    print("║   Cendekiawan ToT AWS GenAI Workshop                     ║")
    print("╚══════════════════════════════════════════════════════════╝\n")

    # Init SES + IDC
    session = boto3.Session(profile_name=SES_PROFILE, region_name=SES_REGION)
    ses = session.client("sesv2")

    # Get list of users who have had leases before (not new)
    hub_session = boto3.Session(profile_name="eta-isb-andrian", region_name="ap-southeast-3")
    ddb = hub_session.client("dynamodb")
    lease_table = "InnovationSandbox-Data-LeaseTable473C6DF2-1434D64HU5AB"

    # Read users
    with open(USERS_CSV) as f:
        users = list(csv.DictReader(f))

    print(f"👥 Users to process: {len(users)}\n")

    success = skipped = failed = 0

    for user in users:
        email      = user["email"].strip()
        first_name = user["firstName"].strip()
        last_name  = user["lastName"].strip()

        print(f"─── {first_name} {last_name} <{email}>")

        # Create lease via ISB API
        status_code, body = api_post("/leases", {
            "leaseTemplateUuid": LEASE_TEMPLATE,
            "userEmail": email,
            "comments": "Cendekiawan ToT Program"
        })

        if status_code == 201:
            data       = body["data"]
            account_id = data.get("awsAccountId", "N/A")
            expiry     = data.get("expirationDate", "N/A")
            lease_id   = data.get("uuid", "N/A")
            print(f"  ✅ Lease created | Account: {account_id} | Expires: {format_expiry(expiry)}")

            # Send email with full lease details
            try:
                msg_id = send_email(ses, email, first_name, account_id, expiry, lease_data=data)
                print(f"  📧 Email sent → {email}")
                success += 1
            except Exception as e:
                print(f"  ⚠️  Email failed: {e}")
                success += 1  # lease still created

        elif status_code == 409:
            print(f"  ⏭  Already has active lease")
            skipped += 1

        else:
            err = body.get("message") or body.get("data", {})
            print(f"  ❌ Failed (HTTP {status_code}): {err}")
            failed += 1

        time.sleep(0.5)
        print()

    print("══════════════════════════════════════════")
    print(f"✅ Assigned  : {success}")
    print(f"⏭  Skipped   : {skipped} (already active)")
    print(f"❌ Failed    : {failed}")
    print("══════════════════════════════════════════")

if __name__ == "__main__":
    # Test mode: single user
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        session = boto3.Session(profile_name=SES_PROFILE, region_name=SES_REGION)
        ses = session.client("sesv2")
        print("🧪 Test mode: andrian.maulana@elitery.com")
        status_code, body = api_post("/leases", {
            "leaseTemplateUuid": LEASE_TEMPLATE,
            "userEmail": "andrian.maulana@elitery.com",
            "comments": "Cendekiawan ToT Program - Test"
        })
        print(f"  Lease API: HTTP {status_code}")
        if status_code == 201:
            data = body["data"]
            print(f"  Account: {data.get('awsAccountId')}")
            print(f"  Expiry:  {format_expiry(data.get('expirationDate',''))}")
            msg_id = send_email(ses, "andrian.maulana@elitery.com", "Andrian",
                                data.get("awsAccountId","N/A"), data.get("expirationDate","N/A"))
            print(f"  Email:   {msg_id}")
        elif status_code == 409:
            print("  Already has active lease — sending reminder email")
            msg_id = send_email(ses, "andrian.maulana@elitery.com", "Andrian",
                                "455939971817", "2026-05-03T21:44:24.716Z")
            print(f"  Email:   {msg_id}")
        else:
            print(f"  Error: {body}")
    else:
        main()
