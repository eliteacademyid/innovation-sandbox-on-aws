#!/usr/bin/env python3
"""Rename all sandbox accounts to ETA-Sandbox-01 through ETA-Sandbox-31
   Uses management account directly with --account-id parameter"""
import boto3, time

PROFILE = "eta-andrian"

session = boto3.Session(profile_name=PROFILE)
org = session.client("organizations", region_name="us-east-1")
# account client in management account can rename any member account
acct = session.client("account", region_name="us-east-1")

# Get all sandbox accounts, sorted by account ID for consistent numbering
accounts = org.list_accounts()["Accounts"]
sandbox = sorted(
    [a for a in accounts
     if ("Sandbox" in a["Name"] or "sandbox" in a["Name"].lower())
     and a["Id"] != "147826551593"],  # exclude hub account
    key=lambda x: x["Id"]
)

print(f"Found {len(sandbox)} sandbox accounts\n")

for i, account in enumerate(sandbox, 1):
    new_name = f"ETA-Sandbox-{i:02d}"
    old_name = account["Name"]
    account_id = account["Id"]

    if old_name == new_name:
        print(f"  ⏭  {account_id} already named {new_name}")
        continue

    try:
        acct.put_account_name(AccountId=account_id, AccountName=new_name)
        print(f"  ✅ {account_id}: {old_name} → {new_name}")
    except Exception as e:
        print(f"  ❌ {account_id}: {old_name} → {new_name} FAILED: {e}")

    time.sleep(0.3)

print("\n✅ Done!")
