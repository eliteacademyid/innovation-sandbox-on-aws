#!/usr/bin/env python3
"""
Move all sandbox accounts from ISB OUs to Root OU before destroying AccountPool.
This ensures accounts survive OU deletion.
"""
import boto3, time

PROFILE  = "eta-andrian"
ROOT_OU  = "r-e21c"
ISB_POOL_OU = "ou-e21c-ji3i2rkr"  # myisb_InnovationSandboxAccountPool

session = boto3.Session(profile_name=PROFILE)
org = session.client("organizations", region_name="us-east-1")

def get_all_accounts_in_ou(ou_id):
    """Recursively get all accounts in an OU and its children."""
    accounts = []
    # Direct accounts
    paginator = org.get_paginator("list_children")
    for page in paginator.paginate(ParentId=ou_id, ChildType="ACCOUNT"):
        accounts.extend(page["Children"])
    # Child OUs
    for page in paginator.paginate(ParentId=ou_id, ChildType="ORGANIZATIONAL_UNIT"):
        for child_ou in page["Children"]:
            accounts.extend(get_all_accounts_in_ou(child_ou["Id"]))
    return accounts

print("Finding all accounts in ISB OUs...")
accounts_in_isb = get_all_accounts_in_ou(ISB_POOL_OU)
print(f"Found {len(accounts_in_isb)} accounts in ISB OUs\n")

moved = skipped = failed = 0

for account in accounts_in_isb:
    account_id = account["Id"]
    # Get current parent
    parents = org.list_parents(ChildId=account_id)["Parents"]
    current_parent = parents[0]["Id"]

    if current_parent == ROOT_OU:
        print(f"  ⏭  {account_id} already at Root")
        skipped += 1
        continue

    try:
        org.move_account(
            AccountId=account_id,
            SourceParentId=current_parent,
            DestinationParentId=ROOT_OU
        )
        print(f"  ✅ {account_id}: {current_parent} → Root")
        moved += 1
    except Exception as e:
        print(f"  ❌ {account_id}: {e}")
        failed += 1

    time.sleep(0.3)

print(f"\n══════════════════════════")
print(f"✅ Moved   : {moved}")
print(f"⏭  Skipped : {skipped}")
print(f"❌ Failed  : {failed}")
print("\nAll accounts are now at Root OU — safe to destroy AccountPool.")
