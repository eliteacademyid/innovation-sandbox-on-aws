# ISB Bedrock Model Router — Student API Guide

## Endpoint

```
POST https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke
```

## Authentication

Add the API key in the `x-api-key` header:
```
x-api-key: <your-api-key>
```

*Your API key will be provided by the instructor.*

## Request Format

```json
{
  "prompt": "Your question or task here",
  "system_prompt": "Optional system instructions",
  "max_tokens": 1024,
  "temperature": 0.7,
  "force_model": null
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `prompt` | ✅ Yes | — | Your prompt/question |
| `system_prompt` | No | "" | System instructions (persona, format, constraints) |
| `max_tokens` | No | 1024 | Max response length |
| `temperature` | No | 0.7 | Creativity (0.0 = deterministic, 1.0 = creative) |
| `force_model` | No | null | Override routing: `"claude"` or `"nova"` |

## How Routing Works

The router automatically picks the best model based on your prompt complexity:

| Complexity | Model | Cost | Best For |
|-----------|-------|------|----------|
| **Simple** | Amazon Nova Pro | ~$0.001/call | Short questions, summaries, simple code |
| **Complex** | Claude Sonnet 4.6 | ~$0.01/call | Analysis, debugging, multi-step reasoning, code review |

What triggers "complex" classification:
- Long prompts (>500 words)
- Keywords: analyze, compare, debug, refactor, step by step, trade-off
- Code blocks (```)
- Many line breaks (structured prompts)

## Examples

### Python

```python
import requests

API_URL = "https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke"
API_KEY = "<your-api-key>"

def ask(prompt, system_prompt="", **kwargs):
    response = requests.post(
        API_URL,
        headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
        json={"prompt": prompt, "system_prompt": system_prompt, **kwargs}
    )
    data = response.json()
    return data["response"]

# Simple question → routed to Nova Pro (cheap & fast)
answer = ask("What is a neural network?")
print(answer)

# Complex task → routed to Claude Sonnet (smarter)
review = ask(
    "Analyze this code and suggest improvements:\n\n```python\ndef fib(n):\n    if n<=1: return n\n    return fib(n-1)+fib(n-2)\n```",
    system_prompt="You are a senior Python engineer. Be concise."
)
print(review)

# Force a specific model
answer = ask("Explain quantum computing", force_model="claude")
```

### curl

```bash
# Simple prompt
curl -X POST "https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke" \
  -H "Content-Type: application/json" \
  -H "x-api-key: <your-api-key>" \
  -d '{"prompt": "What is AWS Lambda?"}'

# With system prompt
curl -X POST "https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke" \
  -H "Content-Type: application/json" \
  -H "x-api-key: <your-api-key>" \
  -d '{
    "prompt": "Build a REST API for a todo app",
    "system_prompt": "You are a backend engineer. Use Python Flask. Be concise.",
    "max_tokens": 2048
  }'
```

### JavaScript/Node.js

```javascript
const API_URL = "https://p8wxuvhiic.execute-api.ap-southeast-1.amazonaws.com/v1/invoke";
const API_KEY = "<your-api-key>";

async function ask(prompt, options = {}) {
  const response = await fetch(API_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-api-key": API_KEY },
    body: JSON.stringify({ prompt, ...options }),
  });
  const data = await response.json();
  return data.response;
}

// Usage
const answer = await ask("Explain microservices architecture");
console.log(answer);
```

## Response Format

```json
{
  "source": "inference",
  "response": "The AI response text...",
  "model": "amazon.nova-pro-v1:0",
  "region": "us-east-1",
  "complexity": "simple"
}
```

| Field | Description |
|-------|-------------|
| `source` | `"inference"` (fresh) or `"cache"` (repeated prompt) |
| `response` | The AI-generated text |
| `model` | Which model was used |
| `region` | AWS region used |
| `complexity` | `"simple"` or `"complex"` |

## Rate Limits

| Limit | Value |
|-------|-------|
| Requests per second | 10 |
| Daily quota | 1,000 requests |
| Max prompt size | ~100KB |
| Response timeout | 120 seconds |

## Tips

1. **Save costs** — let the router pick the model (don't always force Claude)
2. **Use system prompts** — they guide the model's behavior without increasing complexity classification
3. **Caching** — identical prompts return cached responses instantly (no API cost)
4. **Temperature 0** — for consistent, reproducible outputs (great for code generation)
5. **Temperature 0.7-1.0** — for creative writing, brainstorming

## Errors

| Status | Meaning |
|--------|---------|
| 200 | Success |
| 400 | Invalid JSON body |
| 403 | Missing or invalid API key |
| 429 | Rate limit exceeded (wait 1 second) |
| 500 | Internal error (retry once) |
