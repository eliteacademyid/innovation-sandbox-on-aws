#!/usr/bin/env python3
"""
Create sandbox accounts ETA-Sandbox-51 through ETA-Sandbox-100 (50 accounts).
"""
import boto3, time, json, sys

PROFILE      = "eta-andrian"
START_NUM    = 58
END_NUM      = 100
EMAIL_DOMAIN = "eliteacademy.id"

session = boto3.Session(profile_name=PROFILE)
org = session.client("organizations", region_name="us-east-1")

def create_account(name, email):
    resp = org.create_account(
        AccountName=name,
        Email=email,
        IamUserAccessToBilling="DENY"
    )
    return resp["CreateAccountStatus"]["Id"]

def wait_for_account(request_id, timeout=300):
    start = time.time()
    while time.time() - start < timeout:
        status = org.describe_create_account_status(
            CreateAccountRequestId=request_id
        )["CreateAccountStatus"]
        state = status["State"]
        if state == "SUCCEEDED":
            return status["AccountId"]
        elif state == "FAILED":
            raise Exception(f"Account creation failed: {status.get('FailureReason')}")
        time.sleep(10)
    raise TimeoutError(f"Timed out after {timeout}s")

total = END_NUM - START_NUM + 1
print(f"Creating accounts ETA-Sandbox-{START_NUM:02d} to ETA-Sandbox-{END_NUM:02d}")
print(f"Total: {total} accounts\n")
sys.stdout.flush()

created = []
failed  = []

for num in range(START_NUM, END_NUM + 1):
    name  = f"ETA-Sandbox-{num:02d}"
    email = f"eta-sandbox-{num:02d}@{EMAIL_DOMAIN}"
    idx   = num - START_NUM + 1

    print(f"[{idx}/{total}] {name} ({email})", flush=True)

    try:
        request_id = create_account(name, email)
        print(f"  ⏳ Request: {request_id}", flush=True)
        account_id = wait_for_account(request_id)
        print(f"  ✅ Created: {account_id}", flush=True)
        created.append({"num": num, "name": name, "id": account_id, "email": email})
    except Exception as e:
        print(f"  ❌ Failed: {e}", flush=True)
        failed.append({"num": num, "name": name, "email": email, "error": str(e)})

    time.sleep(5)

print(f"\n══════════════════════════════")
print(f"✅ Created : {len(created)}")
print(f"❌ Failed  : {len(failed)}")

if failed:
    print("\nFailed:")
    for a in failed:
        print(f"  {a['name']}: {a['error']}")

with open("scripts/created-sandbox-accounts.json", "w") as f:
    json.dump({"created": created, "failed": failed}, f, indent=2)
print("\nResults saved to scripts/created-sandbox-accounts.json")
