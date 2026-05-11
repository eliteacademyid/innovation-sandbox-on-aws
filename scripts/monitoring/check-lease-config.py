#!/usr/bin/env python3
"""Check lease templates and leases configuration."""
import boto3, json, time, urllib.request, urllib.error
from collections import Counter
import jwt as pyjwt

hub = boto3.Session(profile_name="eta-isb-andrian", region_name="ap-southeast-1")
sm = hub.client("secretsmanager")
secret = sm.get_secret_value(SecretId="/InnovationSandbox/myisb/Auth/JwtSecret")["SecretString"]
token = pyjwt.encode({
    "user": {"displayName": "andrian maulana", "userName": "andrian@eliteacademy.id", "email": "andrian@eliteacademy.id", "roles": ["Admin"]},
    "iat": int(time.time()), "exp": int(time.time()) + 3600
}, secret, algorithm="HS256")

API = "https://ob90f1sd45.execute-api.ap-southeast-1.amazonaws.com/prod"

# Get lease templates
req = urllib.request.Request(f"{API}/leaseTemplates", headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(req) as r:
    data = json.loads(r.read())
    templates = data.get("data", {}).get("result", [])

print("=" * 70)
print("LEASE TEMPLATES")
print("=" * 70)
for t in templates:
    print(f"\n  Name: {t['name']}")
    print(f"  UUID: {t['uuid']}")
    print(f"  Budget: ${t['maxSpend']} | Duration: {t['leaseDurationInHours']}h ({t['leaseDurationInHours']//24} days)")
    print(f"  Budget Thresholds:")
    for bt in t["budgetThresholds"]:
        print(f"    - ${bt['dollarsSpent']} -> {bt['action']}")
    print(f"  Duration Thresholds:")
    for dt in t["durationThresholds"]:
        print(f"    - {dt['hoursRemaining']}h remaining -> {dt['action']}")
    print(f"  Requires Approval: {t.get('requiresApproval', False)}")
    print(f"  Visibility: {t.get('visibility', '?')}")

# Get all leases
req = urllib.request.Request(f"{API}/leases", headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(req) as r:
    data = json.loads(r.read())
    leases = data.get("data", {}).get("result", [])

print(f"\n{'=' * 70}")
print("LEASES SUMMARY")
print("=" * 70)
print(f"Total: {len(leases)}")

status_counts = Counter(l.get("status") for l in leases)
for s, c in sorted(status_counts.items()):
    print(f"  {s}: {c}")

# Check duration thresholds on leases
print(f"\n{'=' * 70}")
print("DURATION THRESHOLDS CHECK (looking for bad 700h/710h values)")
print("=" * 70)

bad_leases = []
for l in leases:
    if l.get("status") in ("Active", "Frozen"):
        dt = l.get("durationThresholds", [])
        for t in dt:
            if t.get("hoursRemaining", 0) > 100:
                bad_leases.append(l)
                break

if bad_leases:
    print(f"WARNING: {len(bad_leases)} leases with bad duration thresholds (>100h):")
    for l in bad_leases:
        print(f"  {l['userEmail']:40s} | {l['durationThresholds']}")
else:
    print("All active/frozen leases have correct duration thresholds (<=100h)")

# Show sample of active lease thresholds
print(f"\n{'=' * 70}")
print("SAMPLE ACTIVE LEASE THRESHOLDS")
print("=" * 70)
active = [l for l in leases if l.get("status") == "Active"]
for l in active[:3]:
    print(f"  {l['userEmail']}")
    print(f"    Budget: {l.get('budgetThresholds')}")
    print(f"    Duration: {l.get('durationThresholds')}")
