"""Request fingerprints for loop detection.

An agent stuck in a loop keeps sending the same conversation tail. The
fingerprint is a hash of the last few messages (Anthropic Messages, OpenAI
Chat Completions) or input items (OpenAI Responses), so a growing
conversation never matches itself, but a repeated identical turn does.
Volatile fields that do not change what is asked are ignored: cache_control
markers, per-call ids (tool_use ids, call ids, message ids), and ids,
timestamps and clock times inside text, so a loop whose tool output embeds
"2025-01-02T03:04:05Z" or a fresh request id still repeats its fingerprint.

Two loop shapes are recognised from the fingerprints of recent requests:
the same request K times in a row (store.loop_hit) and two requests
alternating A, B, A, B, ... (alternation_run).
"""

import hashlib
import json
import re

IGNORED_KEYS = {"cache_control"}
# Keys whose value is a generated identifier or a time, never the question
VOLATILE_KEYS = {"tool_use_id", "tool_call_id", "call_id", "request_id", "timestamp", "created", "created_at"}

_VOLATILE_TEXT = [
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?"), "<ts>"),
    (re.compile(r"\b(?:toolu|call|msg|req|resp|chatcmpl|run|fc|rs)[_-][A-Za-z0-9]{8,}\b"), "<id>"),
    (re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"), "<time>"),
    (re.compile(r"\b1[5-9]\d{8}(?:\d{3})?\b"), "<epoch>"),
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "<hex>"),
]


def scrub(text):
    """Replace ids and timestamps inside a string with placeholders."""
    for pattern, repl in _VOLATILE_TEXT:
        text = pattern.sub(repl, text)
    return text


def _normalise(obj):
    if isinstance(obj, dict):
        return {k: ("<volatile>" if k in VOLATILE_KEYS and not isinstance(v, (dict, list)) else _normalise(v))
                for k, v in sorted(obj.items()) if k not in IGNORED_KEYS}
    if isinstance(obj, list):
        return [_normalise(v) for v in obj]
    if isinstance(obj, str):
        return scrub(obj.strip())
    return obj


def fingerprint(payload, last_n=4):
    """Hash of the tail of a request body, or None if it has no conversation."""
    if not isinstance(payload, dict):
        return None
    items = payload.get("messages")
    if not isinstance(items, list):
        items = payload.get("contents") if isinstance(payload.get("contents"), list) else payload.get("input")
        if isinstance(items, str):
            items = [items]
    if not isinstance(items, list) or not items:
        return None
    tail = _normalise(items[-max(1, int(last_n)):])
    data = json.dumps(tail, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(data.encode()).hexdigest()


def alternation_run(fingerprints):
    """Length of the trailing A, B, A, B, ... run (two different values), or 0.

    `fingerprints` is the recent history, oldest first. A run needs at least
    two entries; ABAB is 4, AAB is 2, and a plain repeat AAAA is not an alternation (0).
    """
    if len(fingerprints) < 2 or fingerprints[-1] == fingerprints[-2]:
        return 0
    run = 2
    for i in range(len(fingerprints) - 3, -1, -1):
        if fingerprints[i] != fingerprints[i + 2]:
            break
        run += 1
    return run
