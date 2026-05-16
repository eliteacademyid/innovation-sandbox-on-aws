#!/usr/bin/env python3
"""
Bulk Lease Assignment Script for Innovation Sandbox on AWS

Usage:
    python3 scripts/bulk-assign-leases.py <csv-file> <lease-template-uuid> <jwt-token>

CSV Format (with header):
    email,comments
    user1@example.com,Development environment
    user2@example.com,Testing environment
"""

import csv
import json
import sys
import time
from typing import Dict, List, Optional
import urllib.request
import urllib.error

# Configuration
API_ENDPOINT = "https://dd3kj1ggdvsy3.cloudfront.net/api"


def assign_lease(
    email: str,
    lease_template_uuid: str,
    jwt_token: str,
    comments: Optional[str] = None
) -> Dict:
    """Assign a lease to a user via the API."""
    
    payload = {
        "leaseTemplateUuid": lease_template_uuid,
        "userEmail": email
    }
    
    if comments:
        payload["comments"] = comments
    
    headers = {
        "Authorization": f"Bearer {jwt_token}",
        "Content-Type": "application/json"
    }
    
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        f"{API_ENDPOINT}/leases",
        data=data,
        headers=headers,
        method='POST'
    )
    
    try:
        with urllib.request.urlopen(req) as response:
            response_data = json.loads(response.read().decode('utf-8'))
            return {
                "success": True,
                "status_code": response.status,
                "data": response_data
            }
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8')
        try:
            error_data = json.loads(error_body)
        except json.JSONDecodeError:
            error_data = {"message": error_body}
        
        return {
            "success": False,
            "status_code": e.code,
            "error": error_data
        }
    except Exception as e:
        return {
            "success": False,
            "status_code": 0,
            "error": {"message": str(e)}
        }


def read_csv_file(csv_file: str) -> List[Dict[str, str]]:
    """Read users from CSV file."""
    users = []
    
    with open(csv_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        
        # Validate headers
        if 'email' not in reader.fieldnames:
            raise ValueError("CSV must have 'email' column")
        
        for row in reader:
            email = row.get('email', '').strip()
            if email:
                users.append({
                    'email': email,
                    'comments': row.get('comments', '').strip()
                })
    
    return users


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 scripts/bulk-assign-leases.py <csv-file> <lease-template-uuid> [jwt-token]")
        print()
        print("CSV file format (with header):")
        print("  email,comments")
        print("  user1@example.com,Development environment")
        print("  user2@example.com,Testing environment")
        print()
        print("Example:")
        print("  python3 scripts/bulk-assign-leases.py users.csv 12345678-90ab-cdef-1234-567890abcdef")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    lease_template_uuid = sys.argv[2]
    jwt_token = sys.argv[3] if len(sys.argv) > 3 else None
    
    # Get JWT token if not provided
    if not jwt_token:
        print("=" * 60)
        print("JWT Token Required")
        print("=" * 60)
        print()
        print("Steps to get your JWT token:")
        print("1. Open: https://d1nu7n93cpbse4.cloudfront.net")
        print("2. Sign in with your admin/manager account")
        print("3. Open browser DevTools (F12 or Cmd+Option+I)")
        print("4. Go to: Application → Local Storage")
        print("5. Find the 'token' key and copy its value")
        print()
        jwt_token = input("Paste your JWT token here: ").strip()
        
        if not jwt_token:
            print("❌ Error: JWT token is required")
            sys.exit(1)
    
    # Read users from CSV
    try:
        users = read_csv_file(csv_file)
    except FileNotFoundError:
        print(f"❌ Error: CSV file not found: {csv_file}")
        sys.exit(1)
    except ValueError as e:
        print(f"❌ Error: {e}")
        sys.exit(1)
    
    if not users:
        print("❌ Error: No users found in CSV file")
        sys.exit(1)
    
    # Display summary
    print()
    print("=" * 60)
    print("Bulk Lease Assignment")
    print("=" * 60)
    print(f"CSV File: {csv_file}")
    print(f"Lease Template UUID: {lease_template_uuid}")
    print(f"Total Users: {len(users)}")
    print(f"API Endpoint: {API_ENDPOINT}")
    print("=" * 60)
    print()
    
    # Confirm before proceeding
    confirm = input(f"Assign leases to {len(users)} users? (yes/no): ").strip().lower()
    if confirm not in ['yes', 'y']:
        print("Cancelled.")
        sys.exit(0)
    
    print()
    print("Starting bulk assignment...")
    print()
    
    # Process each user
    success_count = 0
    fail_count = 0
    results = []
    
    for idx, user in enumerate(users, 1):
        email = user['email']
        comments = user['comments']
        
        print(f"[{idx}/{len(users)}] Assigning lease to: {email}")
        
        result = assign_lease(email, lease_template_uuid, jwt_token, comments)
        
        if result['success']:
            lease_uuid = result['data'].get('data', {}).get('uuid', 'unknown')
            print(f"   ✅ Success - Lease UUID: {lease_uuid}")
            success_count += 1
            results.append({
                'email': email,
                'status': 'success',
                'lease_uuid': lease_uuid
            })
        else:
            error_msg = result['error'].get('data', {}).get('errors', [{}])[0].get('message', 
                       result['error'].get('message', 'Unknown error'))
            print(f"   ❌ Failed (HTTP {result['status_code']}): {error_msg}")
            fail_count += 1
            results.append({
                'email': email,
                'status': 'failed',
                'error': error_msg
            })
        
        # Small delay to avoid rate limiting
        time.sleep(0.5)
    
    # Summary
    print()
    print("=" * 60)
    print("Bulk Assignment Complete")
    print("=" * 60)
    print(f"Total: {len(users)}")
    print(f"Success: {success_count}")
    print(f"Failed: {fail_count}")
    print("=" * 60)
    
    # Save results to file
    results_file = f"bulk-assign-results-{int(time.time())}.json"
    with open(results_file, 'w') as f:
        json.dump({
            'lease_template_uuid': lease_template_uuid,
            'total': len(users),
            'success': success_count,
            'failed': fail_count,
            'results': results
        }, f, indent=2)
    
    print(f"\nResults saved to: {results_file}")


if __name__ == "__main__":
    main()
