"""Data loss prevention for the model gateway.

A filter stage over request bodies (and, optionally, non-streaming response
bodies) that looks for secrets and personal data before they leave the
machine for a model provider.

Modes (gateway.dlp.mode, overridable per agent id prefix):

  off    nothing is scanned
  log    scan; record the detections in the audit log, forward unchanged
  mask   replace every match with [REDACTED:<type>]; JSON bodies are
         re-serialised, so the provider receives valid JSON
  block  refuse the request with 403 (error type dlp_blocked) naming the
         detector types, never the matched values

Only detector *types and counts* are ever reported (log lines, audit events,
error messages). The matched text is never stored.

Detectors are precompiled regexes, some with a validator (Luhn for card
numbers, mod 97 for IBANs, entropy and character-mix checks for generic
secrets). JSON is scanned string by string, so a match cannot straddle two
fields. Strings that are base64 image or document payloads are not scanned.

Streaming: a request body is always read completely before it is forwarded,
so requests are always scanned. A response is only scanned when it is not a
stream (no text/event-stream); streamed responses pass through unmodified
because masking would mean buffering the whole stream (see docs/dlp.md).
"""

import bisect
import json
import math
import re
import threading
import time
from collections import Counter

MODES = ("off", "log", "mask", "block")

# Detector name -> kind. The order is the priority when matches overlap.
SECRET_DETECTORS = (
    "private_key", "aws_access_key", "aws_secret_key", "github_token", "slack_token", "api_key", "jwt",
    "provider_key", "credential_assignment", "high_entropy",
)
PII_DETECTORS = ("email", "credit_card", "iban", "phone")
ALL_DETECTORS = SECRET_DETECTORS + PII_DETECTORS

DEFAULT_MAX_SCAN_BYTES = 16 * 1024 * 1024


def luhn_ok(digits):
    """Luhn checksum of a string of digits."""
    total, alt = 0, False
    for ch in reversed(digits):
        d = ord(ch) - 48
        if not 0 <= d <= 9:
            return False
        if alt:
            d *= 2
            if d > 9:
                d -= 9
        total += d
        alt = not alt
    return len(digits) > 0 and total % 10 == 0


# Registered IBAN lengths (SWIFT registry) for the countries in common use
IBAN_LENGTHS = {
    "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BR": 29,
    "BY": 28, "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28, "EE": 20, "EG": 29,
    "ES": 24, "FI": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28,
    "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20,
    "LB": 28, "LC": 32, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "MC": 27, "MD": 24, "ME": 22, "MK": 19,
    "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29,
    "RO": 24, "RS": 22, "SA": 24, "SC": 31, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "TN": 24, "TR": 26,
    "UA": 29, "VA": 22, "VG": 24, "XK": 20,
}


def iban_ok(text):
    """ISO 13616: country length and the mod-97 check."""
    iban = re.sub(r"\s+", "", text).upper()
    want = IBAN_LENGTHS.get(iban[:2])
    if want is None or len(iban) != want or not iban.isalnum():
        return False
    moved = iban[4:] + iban[:4]
    number = "".join(str(int(c, 36)) for c in moved)
    return int(number) % 97 == 1


def entropy(token):
    """Shannon entropy in bits per character."""
    n = len(token)
    return -sum(c / n * math.log2(c / n) for c in Counter(token).values())


_CARD_PREFIX = re.compile(r"^(?:4|5[1-5]|2(?:2[2-9]|[3-6]\d|7[01]|720)|3[47]|3(?:0[0-5]|[68])|35|6011|65|64[4-9]|62)")


def _card_ok(text):
    digits = re.sub(r"[ \-]", "", text)
    return 13 <= len(digits) <= 19 and bool(_CARD_PREFIX.match(digits)) and luhn_ok(digits) \
        and len(set(digits)) > 1


_HEX_ONLY = re.compile(r"^[0-9a-fA-F]+$")
_SRI = re.compile(r"^(?:sha(?:1|256|384|512)|md5)[-:]", re.I)


_WORDS = re.compile(r"[a-z]{4,}")


def _entropy_ok(token):
    """Generic high-entropy secret: long, mixed case plus digits, not a hash,
    UUID, SRI digest or a word-like identifier."""
    if _HEX_ONLY.match(token) or _SRI.match(token):
        return False
    has_lower = any(c.islower() for c in token)
    has_upper = any(c.isupper() for c in token)
    has_digit = any(c.isdigit() for c in token)
    if not (has_lower and has_upper and has_digit):
        return False
    if token.count("/") > 3 and "=" not in token and "+" not in token:
        return False          # looks like a path
    if sum(len(w) for w in _WORDS.findall(token)) > 0.45 * len(token):
        return False          # mostly long lowercase runs: a camelCase identifier, not random
    return entropy(token) >= 4.25


_PLACEHOLDER = re.compile(r"(?i)example|placeholder|changeme|change_me|your[-_ ]|xxxx|<|\$\{|\{\{|%[sd]|dummy|redacted|\*{3}")


_KEBAB = re.compile(r"[a-z]+(?:[-_.][a-z]+)+")
_RESERVED_DOMAIN = re.compile(
    r"(?i)(?:\.(?:local|localhost|invalid|example|test|internal|lan|service|socket|target|timer|mount|slice|path|scope)"
    r"|(?:^|\.)example\.(?:com|org|net))$")


def _email_ok(text):
    """Not a systemd instance name (getty@tty1.service) or an address in a reserved domain."""
    return not _RESERVED_DOMAIN.search(text.rsplit("@", 1)[-1])


def _assignment_ok(value):
    if len(value) < 12 or _PLACEHOLDER.search(value) or re.fullmatch(r"[A-Z0-9_]+", value):
        return False
    if value[0] in "/$~" or value.startswith(("./", "../")) or _KEBAB.fullmatch(value):
        return False                    # a path, a variable reference or a kebab-case name
    if re.fullmatch(r"[a-z_]+(\.[a-z_]+)*", value):      # a dotted identifier, not a secret
        return False
    return entropy(value) >= 3.0


class Detector:
    """A precompiled pattern. `needles` are literal strings of which at least
    one must occur in the text (lower-cased when `fold`) before the regex runs:
    a cheap prefilter that keeps scanning large bodies fast."""
    __slots__ = ("name", "kind", "regex", "check", "group", "needles", "fold")

    def __init__(self, name, kind, pattern, check=None, group=0, flags=0, needles=(), fold=False):
        self.name = name
        self.kind = kind
        self.regex = re.compile(pattern, flags)
        self.check = check
        self.group = group
        self.needles = needles
        self.fold = fold

    def may_match(self, text, lowered):
        if not self.needles:
            return True
        hay = lowered if self.fold else text
        return any(n in hay for n in self.needles)

    def spans(self, text):
        for m in self.regex.finditer(text):
            value = m.group(self.group)
            if value is None or (self.check and not self.check(value)):
                continue
            yield m.start(self.group), m.end(self.group)


_B = r"(?<![A-Za-z0-9])"          # token boundaries that treat letters and digits as word characters
_E = r"(?![A-Za-z0-9])"
_TOKEN_CHARS = r"A-Za-z0-9+/_\-"

DETECTORS = {d.name: d for d in (
    Detector("private_key", "secret",
             r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|\Z)",
             needles=("PRIVATE KEY",)),
    Detector("aws_access_key", "secret", _B + r"(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}" + _E,
             needles=("AKIA", "ASIA", "AGPA", "AIDA", "AROA", "ANPA", "ANVA", "AIPA")),
    Detector("aws_secret_key", "secret",
             r"(?i)aws.{0,20}?(?:secret|sk).{0,20}?[=:\"'\s]\s*[\"']?([A-Za-z0-9/+=]{40})" + _E, group=1,
             needles=("aws",), fold=True),
    Detector("github_token", "secret",
             _B + r"(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})" + _E,
             needles=("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")),
    Detector("slack_token", "secret", _B + r"xox[abposr]-[A-Za-z0-9\-]{10,72}" + _E, needles=("xox",)),
    Detector("api_key", "secret",
             _B + r"(?:sk-ant-[A-Za-z0-9_\-]{20,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{32,}"
                  r"|(?:sk|rk|pk)_live_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_\-]{35}|glpat-[A-Za-z0-9_\-]{20}"
                  r"|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,})" + _E,
             needles=("sk-", "sk_", "rk_", "pk_", "AIza", "glpat-", "npm_", "SG.")),
    Detector("jwt", "secret", _B + r"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}",
             needles=("eyJ",)),
    # provider_key is built per Dlp instance from the configured key files
    Detector("credential_assignment", "secret",
             r"(?i)\b[\w.\-]{0,40}(?:secret|passw(?:or)?d|passwd|pwd|token|api[_\-]?key|auth[_\-]?key|private[_\-]?key)"
             r"[\w.\-]{0,40}[\"']?\s*[:=]\s*[\"']([^\"'\s\\]{12,128})[\"']",
             check=_assignment_ok, group=1, needles=("secret", "pass", "pwd", "token", "key"), fold=True),
    Detector("high_entropy", "secret",
             r"(?<![" + _TOKEN_CHARS + r"=])[" + _TOKEN_CHARS + r"]{32,200}={0,2}(?![" + _TOKEN_CHARS + r"=])",
             check=_entropy_ok),
    Detector("email", "pii",
             r"(?<![A-Za-z0-9._%+\-])(?!git@)[A-Za-z0-9][A-Za-z0-9._%+\-]{0,63}@(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,24}" + _E,
             check=_email_ok, needles=("@",)),
    Detector("credit_card", "pii", r"(?<![\d.\-])(?:\d[ \-]?){12,18}\d(?![\d\-]|\.\d)", check=_card_ok),
    Detector("iban", "pii", _B + r"[A-Z]{2}\d{2}(?: ?[A-Za-z0-9]{4}){2,7}(?: ?[A-Za-z0-9]{1,3})?" + _E, check=iban_ok),
    # Deliberately strict: an international "+" number or a North American 3-3-4 number
    Detector("phone", "pii",
             r"(?<![\w.+\-])(?:\+\d{1,3}[ .\-]?(?:\(\d{1,4}\)[ .\-]?)?\d{1,4}(?:[ .\-]\d{2,4}){2,4}"
             r"|(?:\(\d{3}\) ?|\d{3}[ .\-])\d{3}[ .\-]\d{4})(?![\w\-]|\.\d)",
             check=lambda t: 9 <= len(re.sub(r"\D", "", t)) <= 15),
)}


class Policy:
    """Effective DLP settings for one agent."""
    __slots__ = ("mode", "detectors", "scan_responses")

    def __init__(self, mode, detectors, scan_responses):
        self.mode = mode
        self.detectors = detectors              # tuple of detector names, in priority order
        self.scan_responses = scan_responses

    @property
    def active(self):
        return self.mode != "off" and bool(self.detectors)


class Outcome:
    """Result of scanning one body."""
    __slots__ = ("action", "counts", "body", "payload", "skipped")

    def __init__(self, action="none", counts=None, body=None, payload=None, skipped=None):
        self.action = action                    # none | logged | masked | blocked
        self.counts = counts or {}              # detector -> number of matches
        self.body = body
        self.payload = payload
        self.skipped = skipped                  # why nothing was scanned, if so

    def types(self):
        return sorted(self.counts)


def _redaction(name):
    return "[REDACTED:%s]" % name


def _is_blob(key, parent, value):
    """Base64 payloads (images, documents) and data: URLs are not text."""
    if len(value) > 1000 and value.startswith("data:"):
        return True
    return key == "data" and isinstance(parent, dict) and parent.get("type") == "base64"


class Dlp:
    def __init__(self, cfg=None, key_source=None, clock=time.time):
        cfg = cfg or {}
        self.cfg = cfg
        self.clock = clock
        self.default_mode = cfg.get("mode", "off")
        if self.default_mode not in MODES:
            raise ValueError("dlp.mode must be one of %s" % ", ".join(MODES))
        self.default_detectors = self._names(cfg.get("detectors", ["all"]))
        self.default_responses = bool(cfg.get("scan_responses", False))
        self.max_scan_bytes = int(cfg.get("max_scan_bytes") or DEFAULT_MAX_SCAN_BYTES)
        self.overrides = {}
        for prefix, ov in (cfg.get("overrides") or {}).items():
            mode = ov.get("mode", self.default_mode)
            if mode not in MODES:
                raise ValueError("dlp.overrides.%s.mode must be one of %s" % (prefix, ", ".join(MODES)))
            self.overrides[prefix] = Policy(
                mode,
                self._names(ov["detectors"]) if "detectors" in ov else self.default_detectors,
                bool(ov.get("scan_responses", self.default_responses)))
        self._prefixes = sorted(self.overrides, key=len, reverse=True)
        self.default = Policy(self.default_mode, self.default_detectors, self.default_responses)
        self._key_source = key_source
        self._keys_lock = threading.Lock()
        self._keys_at = None
        self._keys_regex = None

    @staticmethod
    def _names(names):
        names = list(names or [])
        if "all" in names:
            return ALL_DETECTORS
        unknown = [n for n in names if n not in ALL_DETECTORS]
        if unknown:
            raise ValueError("unknown DLP detector(s): %s (known: %s)" % (", ".join(unknown), ", ".join(ALL_DETECTORS)))
        return tuple(n for n in ALL_DETECTORS if n in names)         # canonical priority order

    @property
    def enabled(self):
        """False when no agent can have an active policy (the gateway skips DLP entirely)."""
        return self.default.active or any(p.active for p in self.overrides.values())

    def policy_for(self, agent):
        for prefix in self._prefixes:
            if agent.startswith(prefix):
                return self.overrides[prefix]
        return self.default

    # ── provider keys ──────────────────────────────────────────────────
    def _provider_regex(self):
        """Pattern for the configured provider keys, refreshed every 30 s."""
        if self._key_source is None:
            return None
        now = self.clock()
        with self._keys_lock:
            if self._keys_at is None or now - self._keys_at > 30:
                keys = sorted({k for k in (self._key_source() or []) if k and len(k) >= 8}, key=len, reverse=True)
                self._keys_regex = re.compile("|".join(re.escape(k) for k in keys)) if keys else False
                self._keys_at = now
            return self._keys_regex or None

    # ── scanning ───────────────────────────────────────────────────────
    def find(self, text, names):
        """[(start, end, type)] of non-overlapping matches in `text`."""
        found = []
        prio = {n: i for i, n in enumerate(names)}
        lowered = text.lower() if any(DETECTORS[n].fold for n in names if n in DETECTORS) else None
        for name in names:
            if name == "provider_key":
                regex = self._provider_regex()
                if regex is not None:
                    found.extend((m.start(), m.end(), name) for m in regex.finditer(text))
                continue
            det = DETECTORS[name]
            if det.may_match(text, lowered):
                found.extend((s, e, name) for s, e in det.spans(text))
        if len(found) > 1:
            # more specific detectors (earlier in `names`) win an overlap, then the longer match
            found.sort(key=lambda f: (prio[f[2]], -(f[1] - f[0]), f[0]))
            starts, kept = [], []
            for item in found:
                i = bisect.bisect_left(starts, item[0])
                if i > 0 and kept[i - 1][1] > item[0]:
                    continue
                if i < len(kept) and kept[i][0] < item[1]:
                    continue
                starts.insert(i, item[0])
                kept.insert(i, item)
            found = kept
        return found

    def mask_text(self, text, names, counts):
        """Redact `text`; matches are counted into `counts`. Returns the new text."""
        found = self.find(text, names)
        if not found:
            return text
        out, pos = [], 0
        for start, end, name in found:
            out.append(text[pos:start])
            out.append(_redaction(name))
            counts[name] = counts.get(name, 0) + 1
            pos = end
        out.append(text[pos:])
        return "".join(out)

    def _count_text(self, text, names, counts):
        for _, _, name in self.find(text, names):
            counts[name] = counts.get(name, 0) + 1

    def scan_value(self, obj, names, mask, counts):
        """Walk a parsed JSON value; with `mask`, strings are replaced in place.
        Returns the (possibly replaced) value."""
        if isinstance(obj, str):
            return self.mask_text(obj, names, counts) if mask else (self._count_text(obj, names, counts) or obj)
        stack = [obj]
        while stack:
            node = stack.pop()
            items = node.items() if isinstance(node, dict) else enumerate(node)
            for key, value in list(items):
                if isinstance(value, str):
                    if _is_blob(key, node, value) or len(value) < 5:
                        continue
                    if mask:
                        new = self.mask_text(value, names, counts)
                        if new is not value:
                            node[key] = new
                    else:
                        self._count_text(value, names, counts)
                elif isinstance(value, (dict, list)):
                    stack.append(value)
        return obj

    def scan_body(self, policy, body, payload, content_type, request=True):
        """Scan a request or response body under `policy`.

        `payload` is the parsed JSON of `body` when the caller has it. The
        Outcome carries the body to forward (new bytes after masking) and the
        payload that matches it.
        """
        if not policy.active or not body:
            return Outcome(body=body, payload=payload)
        if len(body) > self.max_scan_bytes:
            return Outcome(body=body, payload=payload, skipped="body larger than %d bytes" % self.max_scan_bytes)
        ctype = (content_type or "").lower()
        is_json = "json" in ctype or (not ctype and payload is not None)
        is_text = is_json or ctype.startswith("text/") or "xml" in ctype or "x-www-form-urlencoded" in ctype or not ctype
        if not is_text:
            return Outcome(body=body, payload=payload, skipped="binary content type")
        names = policy.detectors
        mask = policy.mode == "mask"
        counts = {}
        if is_json and payload is None:
            try:
                payload = json.loads(body)
            except ValueError:
                payload = None
        if payload is not None and isinstance(payload, (dict, list, str)):
            payload = self.scan_value(payload, names, mask, counts)
            new_body = json.dumps(payload).encode() if (mask and counts) else body
        else:
            try:
                text = body.decode("utf-8", "surrogateescape")
            except (UnicodeError, AttributeError):
                return Outcome(body=body, payload=payload, skipped="not text")
            if mask:
                text = self.mask_text(text, names, counts)
                new_body = text.encode("utf-8", "surrogateescape") if counts else body
            else:
                self._count_text(text, names, counts)
                new_body = body
        if not counts:
            return Outcome(body=body, payload=payload)
        if policy.mode == "mask":
            return Outcome("masked", counts, new_body, payload)
        if policy.mode == "block":
            return Outcome("blocked", counts, body, payload)
        return Outcome("logged", counts, body, payload)

    def too_big(self, policy, body):
        """True when a body cannot be scanned and the policy would have to modify or refuse it."""
        return policy.mode in ("mask", "block") and bool(body) and len(body) > self.max_scan_bytes
