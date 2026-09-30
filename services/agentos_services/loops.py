"""Request fingerprints for loop detection.

An agent stuck in a loop keeps sending the same conversation tail. The
fingerprint is a hash of the last few messages (Anthropic Messages, OpenAI
Chat Completions) or input items (OpenAI Responses), so a growing
conversation never matches itself, but a repeated identical turn does.
Volatile fields that do not change what is asked (cache_control markers) are
ignored.
"""

import hashlib
import json

IGNORED_KEYS = {"cache_control"}


def _normalise(obj):
    if isinstance(obj, dict):
        return {k: _normalise(v) for k, v in sorted(obj.items()) if k not in IGNORED_KEYS}
    if isinstance(obj, list):
        return [_normalise(v) for v in obj]
    if isinstance(obj, str):
        return obj.strip()
    return obj


def fingerprint(payload, last_n=4):
    """Hash of the tail of a request body, or None if it has no conversation."""
    if not isinstance(payload, dict):
        return None
    items = payload.get("messages")
    if not isinstance(items, list):
        items = payload.get("input")
        if isinstance(items, str):
            items = [items]
    if not isinstance(items, list) or not items:
        return None
    tail = _normalise(items[-max(1, int(last_n)):])
    data = json.dumps(tail, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(data.encode()).hexdigest()
