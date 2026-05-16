# Bedrock Model Region Availability Guide

## For Innovation Sandbox Users (APU Hackathon Teams)

### ⚠️ Important: Region Restrictions

Your sandbox account is restricted to the following AWS regions by Service Control Policy (SCP):

| Region Code | Region Name |
|-------------|-------------|
| `us-east-1` | US East (N. Virginia) |
| `ap-southeast-1` | Asia Pacific (Singapore) |
| `ap-southeast-3` | Asia Pacific (Jakarta) |
| `ap-southeast-5` | Asia Pacific (Malaysia) |

Any API call to a region **outside** this list will be denied with:
```
AccessDeniedException: ... with an explicit deny in a service control policy
```

---

### Claude Sonnet 4.5 (`anthropic.claude-sonnet-4-5-20250929-v1:0`)

This model is **NOT available In-Region** in `ap-southeast-3` (Jakarta), `ap-southeast-1` (Singapore), or `ap-southeast-5` (Malaysia).

**Available options within your allowed regions:**

| Method | Region | Model ID |
|--------|--------|----------|
| ✅ In-Region | `us-east-1` | `anthropic.claude-sonnet-4-5-20250929-v1:0` |
| ❌ In-Region | `ap-southeast-3` | Not available |
| ❌ In-Region | `ap-southeast-1` | Not available |
| ❌ In-Region | `ap-southeast-5` | Not available |

> **Note:** Global Cross-Region Inference (CRIS) profiles like `global.anthropic.claude-sonnet-4-5-20250929-v1:0` will NOT work because they route requests to regions blocked by the SCP (e.g., `us-west-2`, `eu-west-1`).

**✅ Solution: Use `us-east-1` directly**

```javascript
// JavaScript / Node.js
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

const client = new BedrockRuntimeClient({ region: "us-east-1" });

const response = await client.send(new InvokeModelCommand({
  modelId: "anthropic.claude-sonnet-4-5-20250929-v1:0",
  body: JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    messages: [{ role: "user", content: "Hello!" }],
    max_tokens: 1024
  })
}));
```

```python
# Python
import boto3
import json

client = boto3.client('bedrock-runtime', region_name='us-east-1')

response = client.invoke_model(
    modelId='anthropic.claude-sonnet-4-5-20250929-v1:0',
    body=json.dumps({
        'anthropic_version': 'bedrock-2023-05-31',
        'messages': [{'role': 'user', 'content': 'Hello!'}],
        'max_tokens': 1024
    })
)
```

---

### Claude Sonnet 4 (`anthropic.claude-sonnet-4-20250514-v1:0`)

This model IS available In-Region in your allowed regions:

| Method | Region | Available |
|--------|--------|-----------|
| ✅ In-Region | `us-east-1` | Yes (via Geo) |
| ✅ In-Region | `ap-southeast-1` | Yes |
| ✅ In-Region | `ap-southeast-3` | Yes |
| ✅ In-Region | `ap-southeast-5` | Yes |

```javascript
// Works from ap-southeast-3 (Jakarta)
const client = new BedrockRuntimeClient({ region: "ap-southeast-3" });

const response = await client.send(new InvokeModelCommand({
  modelId: "anthropic.claude-sonnet-4-20250514-v1:0",
  body: JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    messages: [{ role: "user", content: "Hello!" }],
    max_tokens: 1024
  })
}));
```

---

### Other Available Models by Region

#### `ap-southeast-3` (Jakarta) — In-Region Models
- `anthropic.claude-sonnet-4-20250514-v1:0` (Claude Sonnet 4)
- `anthropic.claude-3-5-sonnet-20241022-v2:0` (Claude 3.5 Sonnet v2)
- `anthropic.claude-3-haiku-20240307-v1:0` (Claude 3 Haiku)
- `amazon.titan-text-express-v1` (Titan Text Express)
- `amazon.titan-embed-text-v2:0` (Titan Embeddings)

#### `us-east-1` (N. Virginia) — Most Models Available
- All Claude models (Sonnet 4.5, Sonnet 4, Opus, Haiku)
- All Amazon Titan models
- Meta Llama models
- Mistral models
- Cohere models

---

### Quick Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `AccessDeniedException: explicit deny in a service control policy` | Calling a region not in the allowlist, OR using CRIS that routes to blocked regions | Use `us-east-1` directly for Claude Sonnet 4.5 |
| `ValidationException: model not found` | Model not available in that region | Switch to `us-east-1` or use a different model |
| `AccessDeniedException: not authorized to perform bedrock:InvokeModel` | IAM role missing Bedrock permissions | Check your role has `bedrock:InvokeModel` permission |

---

### Recommended Configuration

For maximum model availability within your sandbox constraints:

```javascript
// Best practice: use us-east-1 for Claude Sonnet 4.5
const bedrockClient = new BedrockRuntimeClient({ region: "us-east-1" });

// Alternative: use ap-southeast-3 for Claude Sonnet 4 (lower latency from SEA)
const bedrockClientLocal = new BedrockRuntimeClient({ region: "ap-southeast-3" });
```

### ⚠️ Do NOT Use Cross-Region Inference Profiles

The following will **fail** due to SCP restrictions:
```javascript
// ❌ WILL FAIL - Global CRIS routes to blocked regions
modelId: "global.anthropic.claude-sonnet-4-5-20250929-v1:0"

// ❌ WILL FAIL - US Geo routes to us-west-2 which is blocked
modelId: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
```

Always use the direct model ID with an explicit region instead.

---

### Need Help?

1. Make sure you've enabled model access in the Bedrock console for your region
2. Go to: https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess
3. Request access to the models you need
4. Wait for approval (usually instant for Anthropic models)
