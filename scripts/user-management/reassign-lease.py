import boto3, json, urllib.request, urllib.error, time
from datetime import datetime

USERS = [
    {"email": "tulasi.appalasamy@apu.edu.my", "firstName": "Tulasi"},
]

JWT            = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyIjp7ImRpc3BsYXlOYW1lIjoiYW5kcmlhbiBtYXVsYW5hIiwidXNlck5hbWUiOiJhbmRyaWFuQGVsaXRlYWNhZGVteS5pZCIsImVtYWlsIjoiYW5kcmlhbkBlbGl0ZWFjYWRlbXkuaWQiLCJyb2xlcyI6WyJBZG1pbiJdfSwiaWF0IjoxNzc3ODU3OTYzLCJleHAiOjE3Nzc4NjE1NjN9.Zaqlrj0hAbj6lm8KBumiJpsNtwzQfOg8iiyVfUX6bQ0"
API            = "https://sp1yg0dss7.execute-api.ap-southeast-3.amazonaws.com/prod"
LEASE_TEMPLATE = "4f20eae7-4ac4-4778-9318-976ef1189331"
ISB_PORTAL     = "https://aws-sandbox.eliteacademy.id"
LEASE_TABLE    = "InnovationSandbox-Data-LeaseTable473C6DF2-1434D64HU5AB"

ddb = boto3.Session(profile_name="eta-isb-andrian", region_name="ap-southeast-3").client("dynamodb")
ses = boto3.Session(profile_name="eta-andrian", region_name="ap-southeast-1").client("sesv2")

def fmt(iso):
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").strftime("%d %B %Y, %H:%M UTC")
    except:
        return iso

def api_call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(
        f"{API}{path}", data=data,
        headers={"Authorization": f"Bearer {JWT}", "Content-Type": "application/json"},
        method=method
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())

def get_leases(email):
    resp = ddb.scan(
        TableName=LEASE_TABLE,
        FilterExpression="userEmail = :e",
        ExpressionAttributeValues={":e": {"S": email}}
    )
    return resp["Items"]

def get_active_lease(email):
    resp = ddb.scan(
        TableName=LEASE_TABLE,
        FilterExpression="userEmail = :e AND #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":e": {"S": email}, ":s": {"S": "Active"}}
    )
    if not resp["Items"]:
        return None
    item = resp["Items"][0]
    return {
        "uuid": item["uuid"]["S"],
        "awsAccountId": item.get("awsAccountId", {}).get("S", "N/A"),
        "expirationDate": item.get("expirationDate", {}).get("S", "N/A"),
        "originalLeaseTemplateName": item.get("originalLeaseTemplateName", {}).get("S", "N/A"),
        "leaseDurationInHours": int(item.get("leaseDurationInHours", {}).get("N", "48")),
        "maxSpend": int(item.get("maxSpend", {}).get("N", "10")),
        "approvedBy": item.get("approvedBy", {}).get("S", "AUTO_APPROVED"),
        "budgetThresholds": [{"dollarsSpent": int(t["M"]["dollarsSpent"]["N"]), "action": t["M"]["action"]["S"]} for t in item.get("budgetThresholds", {}).get("L", [])],
        "durationThresholds": [{"hoursRemaining": int(t["M"]["hoursRemaining"]["N"]), "action": t["M"]["action"]["S"]} for t in item.get("durationThresholds", {}).get("L", [])]
    }

def send_email(to_email, first_name, lease):
    with open("scripts/email-template.html") as f:
        html = f.read()
    ba = next((t["dollarsSpent"] for t in lease["budgetThresholds"] if t["action"] == "ALERT"), "—")
    bf = next((t["dollarsSpent"] for t in lease["budgetThresholds"] if t["action"] == "FREEZE_ACCOUNT"), "—")
    da = next((t["hoursRemaining"] for t in lease["durationThresholds"] if t["action"] == "ALERT"), "—")
    df = next((t["hoursRemaining"] for t in lease["durationThresholds"] if t["action"] == "FREEZE_ACCOUNT"), "—")
    for k, v in [
        ("{{FIRST_NAME}}", first_name), ("{{EMAIL}}", to_email),
        ("{{ACCOUNT_ID}}", lease["awsAccountId"]), ("{{EXPIRY}}", fmt(lease["expirationDate"])),
        ("{{ISB_PORTAL}}", ISB_PORTAL), ("{{LEASE_TEMPLATE_NAME}}", lease["originalLeaseTemplateName"]),
        ("{{DURATION}}", str(lease["leaseDurationInHours"])), ("{{MAX_SPEND}}", str(lease["maxSpend"])),
        ("{{APPROVED_BY}}", lease["approvedBy"]), ("PORTAL_PLACEHOLDER", ISB_PORTAL),
        ("EMAIL_PLACEHOLDER", to_email), ("{{BUDGET_ALERT_USD}}", str(ba)),
        ("{{BUDGET_FREEZE_USD}}", str(bf)), ("{{DURATION_ALERT_HOURS}}", str(da)),
        ("{{DURATION_FREEZE_HOURS}}", str(df))
    ]:
        html = html.replace(k, v)
    resp = ses.send_email(
        FromEmailAddress="helpdesk@eliteacademy.id",
        Destination={"ToAddresses": [to_email]},
        Content={"Simple": {
            "Subject": {"Data": "Your AWS GenAI Sandbox is Ready - Cendekiawan ToT", "Charset": "UTF-8"},
            "Body": {"Html": {"Data": html, "Charset": "UTF-8"}}
        }}
    )
    return resp["MessageId"]

for user in USERS:
    email, first = user["email"], user["firstName"]
    print(f"\n─── {first} <{email}>")

    # Step 1: Terminate existing active lease if any
    existing = get_active_lease(email)
    if existing:
        lease_id = existing["uuid"]
        print(f"  🗑  Terminating lease {lease_id} (Account: {existing['awsAccountId']})")
        code, body = api_call("POST", f"/leases/{lease_id}/terminate")
        print(f"  {'✅' if code == 200 else '⚠️ '} Terminate: HTTP {code}")
        time.sleep(2)

    # Step 2: Create new lease
    print(f"  📦 Creating new lease...")
    code, body = api_call("POST", "/leases", {
        "leaseTemplateUuid": LEASE_TEMPLATE,
        "userEmail": email,
        "comments": "Cendekiawan ToT Program - Reassigned"
    })
    if code == 201:
        print(f"  ✅ Lease created | Account: {body['data'].get('awsAccountId', 'N/A')}")
    else:
        print(f"  ❌ Failed: HTTP {code} — {body}")
        continue

    # Step 3: Get lease details from DDB (has expiry)
    time.sleep(2)
    lease = get_active_lease(email)
    if not lease:
        print(f"  ⚠️  Could not fetch lease from DDB")
        continue

    print(f"  📅 Expires: {fmt(lease['expirationDate'])}")

    # Step 4: Send email
    msg_id = send_email(email, first, lease)
    print(f"  📧 Email sent | {msg_id}")

print("\n✅ Done!")
