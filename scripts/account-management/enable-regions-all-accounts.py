#!/usr/bin/env python3
"""Enable ap-southeast-3 and ap-southeast-5 in all sandbox accounts."""
import boto3, time

PROFILE = "eta-andrian"
REGIONS_TO_ENABLE = ["ap-southeast-3", "ap-southeast-5"]

session = boto3.Session(profile_name=PROFILE)
org = session.client("organizations", region_name="us-east-1")

# Get all sandbox accounts
paginator = org.get_paginator("list_accounts")
accounts = []
for page in paginator.paginate():
    accounts.extend(page["Accounts"])
sandbox = [a for a in accounts if "Sandbox" in a["Name"]]
print(f"Enabling regions in {len(sandbox)} sandbox accounts...\n")

for region in REGIONS_TO_ENABLE:
    print(f"=== Enabling {region} ===")
    enabled = skipped = failed = 0
    for acc in sandbox:
        acc_id = acc["Id"]
        try:
            # Use account client from management account
            acct = session.client("account", region_name="us-east-1")
            status = acct.get_region_opt_status(AccountId=acc_id, RegionName=region)
            current = status["RegionOptStatus"]
            if current in ["ENABLED", "ENABLING", "ENABLED_BY_DEFAULT"]:
                skipped += 1
                continue
            acct.enable_region(AccountId=acc_id, RegionName=region)
            enabled += 1
            if enabled % 10 == 0:
                print(f"  Enabled {enabled}...")
        except Exception as e:
            if "already opted in" in str(e).lower() or "ENABLED" in str(e):
                skipped += 1
            else:
                print(f"  ❌ {acc_id} ({acc['Name']}): {e}")
                failed += 1
        time.sleep(0.3)
    print(f"  ✅ Enabled: {enabled}, Skipped: {skipped}, Failed: {failed}\n")

print("✅ Done! Regions may take 5-10 minutes to fully activate.")
print("After activation, retry cleanup for quarantined accounts.")
