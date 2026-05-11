#!/bin/bash

# All-in-one script: Create users in IAM Identity Center and bulk assign leases
# Usage: ./scripts/user-management/create-users-and-assign-leases.sh <csv-file> <lease-template-uuid> [jwt-token]
# CSV format: email,firstName,lastName,role,comments
# Example CSV:
#   email,firstName,lastName,role,comments
#   alice@example.com,Alice,Smith,user,Development environment
#   bob@example.com,Bob,Jones,user,Testing environment

set -e

# Parse arguments
CSV_FILE=$1
LEASE_TEMPLATE_UUID=$2
JWT_TOKEN=$3

if [ -z "$CSV_FILE" ] || [ -z "$LEASE_TEMPLATE_UUID" ]; then
    echo "Usage: $0 <csv-file> <lease-template-uuid> [jwt-token]"
    echo ""
    echo "CSV file format (with header):"
    echo "  email,firstName,lastName,role,comments"
    echo "  alice@example.com,Alice,Smith,user,Development environment"
    echo "  bob@example.com,Bob,Jones,manager,Testing environment"
    echo ""
    echo "Example:"
    echo "  $0 users.csv 12345678-90ab-cdef-1234-567890abcdef"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo "❌ Error: CSV file not found: $CSV_FILE"
    exit 1
fi

echo "=========================================="
echo "Create Users and Assign Leases"
echo "=========================================="
echo "CSV File: $CSV_FILE"
echo "Lease Template UUID: $LEASE_TEMPLATE_UUID"
echo "=========================================="
echo ""

# Step 1: Create users in IAM Identity Center
echo "Step 1: Creating users in IAM Identity Center..."
echo ""

USER_COUNT=0
CREATED_COUNT=0
FAILED_COUNT=0

# Create temporary CSV for lease assignment
LEASE_CSV=$(mktemp)
echo "email,comments" > "$LEASE_CSV"

# Skip header and process each user
tail -n +2 "$CSV_FILE" | while IFS=',' read -r email firstName lastName role comments; do
    USER_COUNT=$((USER_COUNT + 1))
    
    # Trim whitespace
    email=$(echo "$email" | xargs)
    firstName=$(echo "$firstName" | xargs)
    lastName=$(echo "$lastName" | xargs)
    role=$(echo "$role" | xargs)
    comments=$(echo "$comments" | xargs)
    
    if [ -z "$email" ] || [ -z "$firstName" ] || [ -z "$lastName" ]; then
        echo "⚠️  Skipping incomplete entry on line $USER_COUNT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    
    # Default role to 'user' if not specified
    if [ -z "$role" ]; then
        role="user"
    fi
    
    echo "[$USER_COUNT] Creating user: $email ($firstName $lastName) - Role: $role"
    
    # Create user
    if ./scripts/user-management/create-test-user.sh "$email" "$firstName" "$lastName" "$role" > /dev/null 2>&1; then
        echo "   ✅ User created successfully"
        CREATED_COUNT=$((CREATED_COUNT + 1))
        
        # Add to lease assignment CSV
        echo "$email,$comments" >> "$LEASE_CSV"
    else
        # Check if user already exists
        if aws identitystore list-users \
            --identity-store-id "d-c8671c93a3" \
            --filters "AttributePath=UserName,AttributeValue=$email" \
            --profile eta-andrian \
            --region ap-southeast-3 \
            --output json 2>/dev/null | grep -q "$email"; then
            echo "   ℹ️  User already exists, will assign lease"
            CREATED_COUNT=$((CREATED_COUNT + 1))
            echo "$email,$comments" >> "$LEASE_CSV"
        else
            echo "   ❌ Failed to create user"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi
    
    # Small delay between user creations
    sleep 0.5
done

echo ""
echo "User creation complete:"
echo "  Total: $USER_COUNT"
echo "  Created/Existing: $CREATED_COUNT"
echo "  Failed: $FAILED_COUNT"
echo ""

# Step 2: Bulk assign leases
if [ $CREATED_COUNT -gt 0 ]; then
    echo "Step 2: Bulk assigning leases..."
    echo ""
    
    # Check if Python script exists
    if [ -f "scripts/bulk-assign-leases.py" ]; then
        if [ -z "$JWT_TOKEN" ]; then
            python3 scripts/bulk-assign-leases.py "$LEASE_CSV" "$LEASE_TEMPLATE_UUID"
        else
            python3 scripts/bulk-assign-leases.py "$LEASE_CSV" "$LEASE_TEMPLATE_UUID" "$JWT_TOKEN"
        fi
    else
        echo "❌ Error: bulk-assign-leases.py not found"
        echo "Lease assignment CSV saved to: $LEASE_CSV"
        echo "Run manually: python3 scripts/bulk-assign-leases.py $LEASE_CSV $LEASE_TEMPLATE_UUID"
        exit 1
    fi
else
    echo "⚠️  No users to assign leases to"
fi

# Cleanup
rm -f "$LEASE_CSV"

echo ""
echo "=========================================="
echo "✅ Process Complete"
echo "=========================================="
