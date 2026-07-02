# Copyright Elite Academy. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
Bedrock Model Router — Complexity-based routing handler.

Routes Bedrock inference requests to the optimal model+region:
- Simple tasks → Amazon Nova Pro (cheapest, fastest)
- Complex tasks → Claude Sonnet (2-3 consolidated regions)

Complexity classification uses heuristics on prompt length, structure,
and task type indicators. Prompt caching with extended TTL is applied
for repeat/similar prompts.

Environment variables:
- CLAUDE_REGIONS            Comma-separated regions for Claude (e.g. "us-east-1,us-west-2,eu-west-1")
- NOVA_REGION              Region for Nova Pro (e.g. "us-east-1")
- CACHE_TABLE_NAME         DynamoDB table for prompt cache
- CACHE_TTL_HOURS          Cache TTL in hours (default: 24)
- COMPLEXITY_THRESHOLD     Token/indicator threshold for complex classification (default: 500)
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

CLAUDE_REGIONS = os.environ.get("CLAUDE_REGIONS", "us-east-1,us-west-2,eu-west-1").split(",")
NOVA_REGION = os.environ.get("NOVA_REGION", "us-east-1")
CACHE_TABLE_NAME = os.environ.get("CACHE_TABLE_NAME", "")
CACHE_TTL_HOURS = int(os.environ.get("CACHE_TTL_HOURS", "24"))
COMPLEXITY_THRESHOLD = int(os.environ.get("COMPLEXITY_THRESHOLD", "500"))

CLAUDE_MODEL_ID = "us.anthropic.claude-sonnet-4-6"
NOVA_MODEL_ID = "amazon.nova-pro-v1:0"

# Indicators that suggest complex reasoning is needed
COMPLEX_INDICATORS = [
    "analyze", "compare", "evaluate", "synthesize", "design",
    "architect", "debug", "refactor", "optimize", "explain why",
    "trade-off", "pros and cons", "step by step", "reasoning",
    "multi-step", "code review", "security audit",
]

# Region rotation index (simple round-robin for load distribution)
_region_idx = 0


def lambda_handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    """
    Event shape:
    {
      "prompt": "...",
      "system_prompt": "...",  # optional
      "max_tokens": 1024,       # optional
      "temperature": 0.7,       # optional
      "user_id": "...",         # optional, for cache scoping
      "force_model": "claude|nova"  # optional override
    }
    """
    prompt = event.get("prompt", "")
    system_prompt = event.get("system_prompt", "")
    max_tokens = event.get("max_tokens", 1024)
    temperature = event.get("temperature", 0.7)
    force_model = event.get("force_model")

    # Check cache first
    cache_key = _compute_cache_key(prompt, system_prompt)
    cached = _get_cached_response(cache_key)
    if cached:
        LOG.info("cache_hit key=%s", cache_key[:16])
        return {"source": "cache", "response": cached, "model": "cached", "region": "cached"}

    # Classify complexity
    complexity = _classify_complexity(prompt, system_prompt)
    LOG.info("complexity=%s prompt_len=%d", complexity, len(prompt))

    # Route to model
    if force_model == "claude":
        complexity = "complex"
    elif force_model == "nova":
        complexity = "simple"

    if complexity == "complex":
        model_id = CLAUDE_MODEL_ID
        region = _next_claude_region()
    else:
        model_id = NOVA_MODEL_ID
        region = NOVA_REGION

    # Invoke model
    response = _invoke_model(
        region=region,
        model_id=model_id,
        prompt=prompt,
        system_prompt=system_prompt,
        max_tokens=max_tokens,
        temperature=temperature,
    )

    # Cache response
    _cache_response(cache_key, response)

    return {
        "source": "inference",
        "response": response,
        "model": model_id,
        "region": region,
        "complexity": complexity,
    }


def _classify_complexity(prompt: str, system_prompt: str) -> str:
    """Classify prompt as 'simple' or 'complex' using heuristics."""
    combined = f"{system_prompt} {prompt}".lower()
    score = 0

    # Length-based scoring
    token_estimate = len(combined.split())
    if token_estimate > COMPLEXITY_THRESHOLD:
        score += 2

    # Indicator-based scoring
    for indicator in COMPLEX_INDICATORS:
        if indicator in combined:
            score += 1

    # Multi-turn / structured prompts tend to be complex
    if combined.count("\n") > 10:
        score += 1

    # Code blocks suggest complex tasks
    if "```" in combined:
        score += 2

    return "complex" if score >= 3 else "simple"


def _next_claude_region() -> str:
    """Round-robin across Claude regions for load distribution."""
    global _region_idx
    region = CLAUDE_REGIONS[_region_idx % len(CLAUDE_REGIONS)]
    _region_idx += 1
    return region


def _invoke_model(
    region: str,
    model_id: str,
    prompt: str,
    system_prompt: str,
    max_tokens: int,
    temperature: float,
) -> str:
    """Invoke Bedrock model with the Converse API."""
    client = boto3.client("bedrock-runtime", region_name=region)

    messages = [{"role": "user", "content": [{"text": prompt}]}]
    kwargs: dict[str, Any] = {
        "modelId": model_id,
        "messages": messages,
        "inferenceConfig": {"maxTokens": max_tokens, "temperature": temperature},
    }
    if system_prompt:
        kwargs["system"] = [{"text": system_prompt}]

    try:
        resp = client.converse(**kwargs)
        output = resp["output"]["message"]["content"][0]["text"]
        LOG.info("model=%s region=%s input_tokens=%s output_tokens=%s",
                 model_id, region,
                 resp.get("usage", {}).get("inputTokens"),
                 resp.get("usage", {}).get("outputTokens"))
        return output
    except ClientError as exc:
        LOG.error("invoke failed model=%s region=%s error=%s", model_id, region, exc)
        # Fallback: try next Claude region if this one fails
        if model_id == CLAUDE_MODEL_ID and len(CLAUDE_REGIONS) > 1:
            fallback_region = _next_claude_region()
            LOG.info("retrying with fallback region=%s", fallback_region)
            client = boto3.client("bedrock-runtime", region_name=fallback_region)
            resp = client.converse(**kwargs)
            return resp["output"]["message"]["content"][0]["text"]
        raise


def _compute_cache_key(prompt: str, system_prompt: str) -> str:
    """SHA-256 hash of prompt + system_prompt for cache lookup."""
    raw = f"{system_prompt}||{prompt}"
    return hashlib.sha256(raw.encode()).hexdigest()


def _get_cached_response(cache_key: str) -> str | None:
    """Check DynamoDB cache for a valid (non-expired) entry."""
    if not CACHE_TABLE_NAME:
        return None
    try:
        table = boto3.resource("dynamodb").Table(CACHE_TABLE_NAME)
        item = table.get_item(Key={"cache_key": cache_key}).get("Item")
        if item and item.get("expires_at", 0) > int(time.time()):
            return item["response"]
    except ClientError:
        LOG.warning("cache read failed", exc_info=True)
    return None


def _cache_response(cache_key: str, response: str) -> None:
    """Store response in DynamoDB cache with TTL."""
    if not CACHE_TABLE_NAME:
        return
    try:
        table = boto3.resource("dynamodb").Table(CACHE_TABLE_NAME)
        table.put_item(Item={
            "cache_key": cache_key,
            "response": response,
            "created_at": int(time.time()),
            "expires_at": int(time.time()) + (CACHE_TTL_HOURS * 3600),
        })
    except ClientError:
        LOG.warning("cache write failed", exc_info=True)
