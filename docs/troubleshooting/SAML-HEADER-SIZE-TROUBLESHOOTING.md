# Troubleshooting "RequestHeaderSectionTooLarge" Error

**Issue**: Users receive "RequestHeaderSectionTooLarge" error when accessing the CloudFront URL (https://d1nu7n93cpbse4.cloudfront.net)

**Error Details**:
- Error Code: `RequestHeaderSectionTooLarge`
- Message: "Your request header section exceeds the maximum allowed size"
- Max Size Allowed: 8192 bytes (8 KB)

---

## Root Cause

The HTTP request headers exceed CloudFront's 8KB limit. This commonly occurs with SAML authentication when:

1. **Too many SAML attributes** are included in the assertion
2. **Large group memberships** - Users belong to many groups, and all group names are sent in the SAML response
3. **Session cookies are too large** after SAML authentication

Since you're using **Google Workspace as an external IdP with SCIM**, the groups attribute is likely the culprit if users belong to many Google Workspace groups.

---

## Solution 1: Optimize SAML Attribute Mappings (RECOMMENDED)

### Step-by-Step Instructions

#### 1. Access IAM Identity Center Console

1. Log into the **AWS Console** for the **Elite Academy** account (862099794180)
2. Ensure you're in the **ap-southeast-3** region
3. Navigate to **IAM Identity Center** service
4. Click on **Applications** in the left sidebar

#### 2. Open the SAML Application

1. Find and click on **"ETA Innovation Sandbox App"** from the applications list
2. You should see the application details page

#### 3. Review Current Attribute Mappings

1. Click on the **"Attribute mappings"** tab
2. Review all the attributes currently being sent in the SAML assertion
3. Take note of which attributes are configured

#### 4. Optimize Attribute Mappings

The Innovation Sandbox only requires these **4 attributes**:

| Application Attribute | IAM Identity Center Attribute | Format |
|----------------------|------------------------------|--------|
| Subject | `${user:email}` | emailAddress |
| email | `${user:email}` | unspecified |
| name | `${user:name}` | unspecified |
| groups | `${user:groups}` | unspecified |

**Actions to take**:

1. Click **"Actions"** → **"Edit attribute mappings"**
2. **Remove any extra attributes** that aren't in the table above
3. For the **groups** attribute, you have two options:

   **Option A: Keep groups attribute (if users have few groups)**
   - If users only belong to 3-5 groups, keep it as-is
   
   **Option B: Remove or filter groups attribute (if users have many groups)**
   - If users belong to many Google Workspace groups (10+), consider:
     - **Removing the groups attribute entirely** (the app can still function with role-based access)
     - **Or** contact AWS Support to implement group filtering (only send groups matching `myisb_*` pattern)

4. Click **"Save changes"**

#### 5. Test the Application

1. Wait 2-3 minutes for the changes to propagate
2. Open a **new incognito/private browser window**
3. Navigate to: https://d1nu7n93cpbse4.cloudfront.net
4. Attempt to sign in
5. If successful, the error should be resolved

---

## Solution 2: Filter Groups in Google Workspace (RECOMMENDED IF MANY GROUPS)

If users belong to many Google Workspace groups, you can reduce the number of groups synced to IAM Identity Center:

### Step-by-Step Instructions

#### 1. Access Google Workspace Admin Console

1. Log into **Google Workspace Admin Console** (admin.google.com)
2. Navigate to **Apps** → **Web and mobile apps**
3. Find and click on **AWS IAM Identity Center** (or AWS SSO)

#### 2. Configure Group Provisioning

1. Click on **User access** or **SAML settings**
2. Look for **Group provisioning** or **Attribute mapping** settings
3. Configure to only sync groups that match a specific pattern:
   - Pattern: `myisb_*` (only sync groups starting with "myisb_")
   - Or manually select only the 3 required groups:
     - `myisb_IsbAdminsGroup`
     - `myisb_IsbManagersGroup`
     - `myisb_IsbUsersGroup`

#### 3. Force SCIM Sync

1. In Google Workspace Admin Console, trigger a manual sync
2. Or wait for the next automatic sync (usually within 15-30 minutes)

#### 4. Verify in IAM Identity Center

1. Go back to **IAM Identity Center** in AWS Console
2. Navigate to **Groups**
3. Verify that only the ISB-related groups are present
4. Check that users are members of the correct groups

#### 5. Test the Application

1. Wait 5 minutes for changes to propagate
2. Open a **new incognito/private browser window**
3. Navigate to: https://d1nu7n93cpbse4.cloudfront.net
4. Attempt to sign in

---

## Solution 3: Increase CloudFront Header Size Limit (ADVANCED)

**Warning**: This solution requires modifying the CDK infrastructure and redeploying the Compute stack.

### Overview

CloudFront has a default 8KB header size limit. We can use **Lambda@Edge** to:
1. Intercept the viewer request
2. Extract large headers (like cookies)
3. Store them in a cache or database
4. Replace with a smaller token
5. Retrieve the original headers on the origin request

### Implementation Steps

#### 1. Create Lambda@Edge Function

Create a new file: `source/infrastructure/lib/components/cloudfront/header-size-reducer.ts`

```typescript
import { Duration, Stack } from 'aws-cdk-lib';
import { Code, Function as LambdaFunction, Runtime } from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';
import * as path from 'path';

export interface HeaderSizeReducerProps {
  namespace: string;
}

export class HeaderSizeReducer extends Construct {
  public readonly viewerRequestFunction: LambdaFunction;
  public readonly originRequestFunction: LambdaFunction;

  constructor(scope: Construct, id: string, props: HeaderSizeReducerProps) {
    super(scope, id);

    // Lambda@Edge must be in us-east-1
    const edgeStack = Stack.of(this);
    
    // Viewer Request: Extract large headers and replace with token
    this.viewerRequestFunction = new LambdaFunction(this, 'ViewerRequestFunction', {
      runtime: Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: Code.fromInline(`
        exports.handler = async (event) => {
          const request = event.Records[0].cf.request;
          const headers = request.headers;
          
          // Check if Cookie header is too large
          if (headers.cookie) {
            const cookieSize = JSON.stringify(headers.cookie).length;
            if (cookieSize > 4096) { // If cookie > 4KB
              console.log('Large cookie detected:', cookieSize, 'bytes');
              // Store in DynamoDB or ElastiCache and replace with token
              // For now, just log and pass through
            }
          }
          
          return request;
        };
      `),
      timeout: Duration.seconds(5),
      memorySize: 128,
    });

    // Origin Request: Restore original headers from token
    this.originRequestFunction = new LambdaFunction(this, 'OriginRequestFunction', {
      runtime: Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: Code.fromInline(`
        exports.handler = async (event) => {
          const request = event.Records[0].cf.request;
          // Restore headers from token if needed
          return request;
        };
      `),
      timeout: Duration.seconds(5),
      memorySize: 128,
    });
  }
}
```

#### 2. Modify CloudFront Distribution

Update `source/infrastructure/lib/components/cloudfront/cloudfront-ui-api.ts`:

```typescript
// Add import at the top
import { EdgeFunction } from 'aws-cdk-lib/aws-cloudfront';
import { HeaderSizeReducer } from './header-size-reducer';

// Inside the CloudfrontUiApi constructor, before creating the distribution:

// Create Lambda@Edge functions for header size reduction
const headerSizeReducer = new HeaderSizeReducer(this, 'HeaderSizeReducer', {
  namespace: props.namespace,
});

// Then modify the distribution configuration:
const distribution = new Distribution(this, "IsbCloudFrontDistribution", {
  defaultBehavior: {
    origin: S3BucketOrigin.withOriginAccessControl(feBucket, {
      originId: "S3Origin",
      originAccessControl: oac,
    }),
    allowedMethods: AllowedMethods.ALLOW_ALL,
    viewerProtocolPolicy: ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
    responseHeadersPolicy: responseHeadersPolicy,
    cachePolicy: CachePolicy.CACHING_OPTIMIZED,
    functionAssociations: [
      {
        function: cfFunctionS3OriginPathRedirect,
        eventType: FunctionEventType.VIEWER_REQUEST,
      },
    ],
    // Add Lambda@Edge associations
    edgeLambdas: [
      {
        functionVersion: headerSizeReducer.viewerRequestFunction.currentVersion,
        eventType: LambdaEdgeEventType.VIEWER_REQUEST,
      },
    ],
  },
  // ... rest of configuration
});
```

#### 3. Deploy the Changes

```bash
# Navigate to infrastructure directory
cd "source/infrastructure"

# Synthesize the stack
npm run cdk synth InnovationSandbox-Compute

# Deploy the updated stack
npm run cdk deploy InnovationSandbox-Compute -- \
  --require-approval=never \
  --parameters OrgMgtAccountId=862099794180 \
  --parameters IdcAccountId=862099794180 \
  --parameters AcceptSolutionTermsOfUse=Accept \
  --profile eta-isb
```

**Note**: This is a simplified example. A production implementation would need:
- DynamoDB table or ElastiCache to store large headers
- Proper error handling
- Token generation and validation
- Security considerations

---

## Solution 4: Alternative - Use Cognito Instead of IAM Identity Center

If the above solutions don't work, consider migrating from IAM Identity Center SAML to **Amazon Cognito** with Google Workspace as an OIDC provider. Cognito handles large identity provider responses better.

**Pros**:
- Better handling of large identity provider responses
- More flexible attribute mapping
- Built-in session management

**Cons**:
- Requires significant infrastructure changes
- Need to modify the application authentication flow
- Additional costs for Cognito

---

## Verification Steps

After implementing any solution:

1. **Clear browser cache and cookies**
   - Chrome: Settings → Privacy and security → Clear browsing data
   - Arc: Settings → Privacy → Clear browsing data

2. **Test in incognito/private mode**
   - This ensures no cached cookies interfere

3. **Check browser developer tools**
   - Open DevTools (F12)
   - Go to Network tab
   - Attempt to access the site
   - Check the request headers size in the failed request

4. **Verify SAML response size**
   - Use a SAML tracer browser extension
   - Capture the SAML response
   - Check the size of the assertion

---

## Monitoring and Prevention

### Check Current Header Sizes

You can use this script to monitor header sizes:

```bash
# Check CloudFront access logs for header size issues
aws s3 ls s3://$(aws cloudformation describe-stacks \
  --stack-name InnovationSandbox-Compute \
  --query 'Stacks[0].Outputs[?OutputKey==`IsbFrontEndAccessLogsBucket`].OutputValue' \
  --output text \
  --profile eta-isb \
  --region ap-southeast-3)/isb-fe-logs/ \
  --profile eta-isb \
  --region ap-southeast-3
```

### Best Practices

1. **Limit group memberships** - Only add users to necessary groups
2. **Use group filtering** - Only sync ISB-related groups to IAM Identity Center
3. **Minimize SAML attributes** - Only send required attributes
4. **Regular audits** - Periodically review user group memberships
5. **Monitor CloudFront logs** - Set up alerts for 4xx errors

---

## Quick Reference

### Required SAML Attributes (Minimum)
- Subject: `${user:email}` (emailAddress format)
- email: `${user:email}` (unspecified format)
- name: `${user:name}` (unspecified format)
- groups: `${user:groups}` (unspecified format) - **OPTIONAL, can be removed**

### Key Configuration Values
- **CloudFront URL**: https://d1nu7n93cpbse4.cloudfront.net
- **SAML Application**: ETA Innovation Sandbox App
- **SAML Audience**: Isb-ETA-Audience
- **IAM Identity Center Account**: 862099794180 (Elite Academy)
- **Region**: ap-southeast-3

### Useful AWS CLI Commands

```bash
# List SAML applications
aws sso-admin list-applications \
  --instance-arn arn:aws:sso:::instance/ssoins-666616fcfb74eec7 \
  --profile elite-academy \
  --region ap-southeast-3

# List application assignments (groups/users)
aws sso-admin list-application-assignments \
  --application-arn arn:aws:sso::862099794180:application/ssoins-666616fcfb74eec7/apl-66664d3a4fcad754 \
  --profile elite-academy \
  --region ap-southeast-3

# List groups in Identity Store
aws identitystore list-groups \
  --identity-store-id d-c8671c93a3 \
  --profile elite-academy \
  --region ap-southeast-3

# Check CloudFront distribution configuration
aws cloudfront get-distribution \
  --id $(aws cloudformation describe-stacks \
    --stack-name InnovationSandbox-Compute \
    --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionUrl`].OutputValue' \
    --output text \
    --profile eta-isb \
    --region ap-southeast-3 | cut -d'/' -f3 | cut -d'.' -f1) \
  --profile eta-isb
```

---

## Next Steps

1. **Immediate**: Implement Solution 1 (Optimize SAML Attribute Mappings)
2. **If Solution 1 fails**: Implement Solution 2 (Filter Groups in Google Workspace)
3. **If both fail**: Consider Solution 3 (Lambda@Edge) or Solution 4 (Cognito)

---

## Support Resources

- [AWS IAM Identity Center Documentation](https://docs.aws.amazon.com/singlesignon/latest/userguide/)
- [CloudFront Quotas and Limits](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html)
- [Innovation Sandbox Post-Deployment Guide](https://docs.aws.amazon.com/solutions/latest/innovation-sandbox-on-aws/post-deployment-configuration-tasks.html)
- [Google Workspace SCIM Provisioning](https://support.google.com/a/answer/7365072)

---

**Document Version**: 1.0  
**Last Updated**: 2026-05-01  
**Author**: Kiro AI Assistant
