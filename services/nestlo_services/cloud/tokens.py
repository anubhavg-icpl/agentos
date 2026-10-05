"""API tokens signed with SSH keys (the exe.dev exe0 format, renamed).

A token is

    nestlo0.<base64url(permissions JSON)>.<base64url(SSHSIG blob)>

where the SSHSIG blob is what `ssh-keygen -Y sign -n <namespace>` prints
between its armour lines. Anyone holding a private key whose public half is
registered (`ssh-key add`) can mint tokens offline:

    PERMISSIONS='{"cmds":["ls","new"],"exp":1798761600}'
    PAYLOAD=$(printf %s "$PERMISSIONS" | base64 | tr -d '\\n=' | tr '+/' '-_')
    SIG=$(printf %s "$PERMISSIONS" | ssh-keygen -Y sign -f KEY -n v0@DOMAIN)
    SIGBLOB=$(echo "$SIG" | sed '1d;$d' | tr -d '\\n=' | tr '+/' '-_')
    TOKEN="nestlo0.$PAYLOAD.$SIGBLOB"

The namespace scopes a token: v0@<lobby domain> for POST /exec, and
v0@<vm>.<domain> for one VM's HTTPS endpoint. Revoking the key revokes every
token it signed. `nestlo1.` tokens are short opaque handles for an
`nestlo0.` token, which is re-validated on every use.

Signatures are verified here (Ed25519, ECDSA P-256/384/521 and RSA with
SHA-2), so no process is spawned per request.
"""

import base64
import hashlib
import json
import struct
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

PREFIX0, PREFIX1 = "nestlo0.", "nestlo1."
# exe.dev token prefixes are accepted as aliases so migrated scripts keep working
ALIASES0, ALIASES1 = ("nestlo0.", "exe0."), ("nestlo1.", "exe1.")
MAX_TOKEN = 8192
TS_MIN, TS_MAX = 946684800, 4102444800
TOP_KEYS = {"exp", "nbf", "cmds", "ctx"}
DEFAULT_CMDS = ["help", "ls", "new", "whoami", "ssh-key list", "share show", "token-exchange",
                "team", "team members"]


class TokenError(Exception):
    """status is the HTTP status the API answers with (401 or 403)."""

    def __init__(self, message, status=401):
        super().__init__(message)
        self.status = status
        self.message = message


# ── encoding helpers ───────────────────────────────────────────────────

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(text):
    text = text.strip()
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (ValueError, TypeError):
        raise TokenError("token is not valid base64url")


def _string(data, off):
    if off + 4 > len(data):
        raise TokenError("truncated signature")
    (n,) = struct.unpack(">I", data[off:off + 4])
    off += 4
    if off + n > len(data):
        raise TokenError("truncated signature")
    return data[off:off + n], off + n


def _pack(*parts):
    return b"".join(struct.pack(">I", len(p)) + p for p in parts)


def _mpint(data, off):
    raw, off = _string(data, off)
    return int.from_bytes(raw, "big"), off


# ── SSH public keys ────────────────────────────────────────────────────

KEY_TYPES = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
             "ssh-rsa", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com")


def parse_public_key(line):
    """'<type> <base64> [comment]' -> (type, blob bytes, comment). Raises ValueError."""
    parts = str(line).strip().split(None, 2)
    if len(parts) < 2 or parts[0] not in KEY_TYPES:
        raise ValueError("not an SSH public key (expected e.g. 'ssh-ed25519 AAAA...')")
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except (ValueError, TypeError):
        raise ValueError("SSH public key is not valid base64")
    kind, _ = _string(blob, 0)
    if kind.decode(errors="replace") != parts[0]:
        raise ValueError("SSH public key type does not match its data")
    return parts[0], blob, parts[2] if len(parts) > 2 else ""


def fingerprint(blob):
    """OpenSSH SHA256 fingerprint of a public key blob."""
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def _load_key(blob):
    kind = _string(blob, 0)[0].decode()
    if kind.startswith("sk-"):
        raise TokenError("security-key (sk-) SSH keys cannot sign API tokens")
    return serialization.load_ssh_public_key(kind.encode() + b" " + base64.b64encode(blob))


# ── SSHSIG ─────────────────────────────────────────────────────────────

MAGIC = b"SSHSIG"
_HASHES = {"sha256": hashlib.sha256, "sha512": hashlib.sha512}


def parse_sshsig(sig):
    """SSHSIG blob -> dict(pubkey, namespace, hash_alg, sig_type, sig)."""
    if not sig.startswith(MAGIC):
        raise TokenError("signature is not an SSH signature")
    off = len(MAGIC)
    if off + 4 > len(sig):
        raise TokenError("truncated signature")
    (version,) = struct.unpack(">I", sig[off:off + 4])
    off += 4
    if version != 1:
        raise TokenError("unsupported SSH signature version %d" % version)
    pubkey, off = _string(sig, off)
    namespace, off = _string(sig, off)
    _reserved, off = _string(sig, off)
    hash_alg, off = _string(sig, off)
    inner, off = _string(sig, off)
    sig_type, ioff = _string(inner, 0)
    sig_bytes, _ = _string(inner, ioff)
    return {"pubkey": pubkey, "namespace": namespace.decode(errors="replace"),
            "hash_alg": hash_alg.decode(errors="replace"), "sig_type": sig_type.decode(errors="replace"),
            "sig": sig_bytes}


def _signed_data(namespace, hash_alg, message):
    h = _HASHES[hash_alg](message).digest()
    return MAGIC + _pack(namespace.encode(), b"", hash_alg.encode(), h)


def verify_sshsig(sig_blob, message, namespace):
    """Check an SSHSIG over `message`; returns the signing public key blob."""
    s = parse_sshsig(sig_blob)
    if s["namespace"] != namespace:
        raise TokenError("token was signed for %r, not %r" % (s["namespace"], namespace))
    if s["hash_alg"] not in _HASHES:
        raise TokenError("unsupported signature hash %r" % s["hash_alg"])
    data = _signed_data(namespace, s["hash_alg"], message)
    key = _load_key(s["pubkey"])
    try:
        if isinstance(key, ed25519.Ed25519PublicKey):
            if s["sig_type"] != "ssh-ed25519":
                raise TokenError("signature type does not match the key")
            key.verify(s["sig"], data)
        elif isinstance(key, ec.EllipticCurvePublicKey):
            r, off = _mpint(s["sig"], 0)
            sv, _ = _mpint(s["sig"], off)
            algo = {256: hashes.SHA256(), 384: hashes.SHA384(), 521: hashes.SHA512()}[key.curve.key_size]
            key.verify(encode_dss_signature(r, sv), data, ec.ECDSA(algo))
        elif isinstance(key, rsa.RSAPublicKey):
            algo = {"rsa-sha2-256": hashes.SHA256(), "rsa-sha2-512": hashes.SHA512()}.get(s["sig_type"])
            if algo is None:
                raise TokenError("RSA signatures must use rsa-sha2-256 or rsa-sha2-512")
            key.verify(s["sig"], data, padding.PKCS1v15(), algo)
        else:
            raise TokenError("unsupported key type")
    except InvalidSignature:
        raise TokenError("signature verification failed")
    return s["pubkey"]


def sign_sshsig(private_key, message, namespace, hash_alg="sha512"):
    """SSHSIG blob for `message` (Ed25519 private keys only; used for server-minted tokens)."""
    if not isinstance(private_key, ed25519.Ed25519PrivateKey):
        raise TypeError("only Ed25519 keys are supported for signing")
    pub = private_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    pubblob = _pack(b"ssh-ed25519", pub)
    sig = private_key.sign(_signed_data(namespace, hash_alg, message))
    return (MAGIC + struct.pack(">I", 1)
            + _pack(pubblob, namespace.encode(), b"", hash_alg.encode(), _pack(b"ssh-ed25519", sig)))


def public_line(private_key, comment=""):
    pub = private_key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
    return pub.decode() + (" " + comment if comment else "")


def armor(sig_blob):
    """The text `ssh-keygen -Y sign` prints for a blob (for tests and tools)."""
    b = base64.b64encode(sig_blob).decode()
    lines = [b[i:i + 70] for i in range(0, len(b), 70)]
    return "-----BEGIN SSH SIGNATURE-----\n" + "\n".join(lines) + "\n-----END SSH SIGNATURE-----\n"


# ── permissions ────────────────────────────────────────────────────────

def _no_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise TokenError("duplicate key %r in token permissions" % k)
        out[k] = v
    return out


def _valid_ts(name, value):
    if isinstance(value, bool) or not isinstance(value, int) or not TS_MIN <= value <= TS_MAX:
        raise TokenError("%s must be an integer Unix time between 2000 and 2100" % name)


def parse_permissions(raw):
    """Validate the permissions JSON bytes of a token; returns the dict."""
    try:
        text = raw.decode()
    except UnicodeDecodeError:
        raise TokenError("token permissions are not UTF-8")
    if text != text.strip() or "\n" in text or "\0" in text:
        raise TokenError("token permissions must be compact JSON without whitespace around it or newlines")
    try:
        perms = json.loads(text, object_pairs_hook=_no_dupes)
    except ValueError as exc:
        raise TokenError("token permissions are not valid JSON: %s" % exc)
    if not isinstance(perms, dict):
        raise TokenError("token permissions must be a JSON object")
    extra = set(perms) - TOP_KEYS
    if extra:
        raise TokenError("unknown token permission field(s): %s" % ", ".join(sorted(extra)))
    for name in ("exp", "nbf"):
        if name in perms:
            _valid_ts(name, perms[name])
    cmds = perms.get("cmds")
    if cmds is not None and (not isinstance(cmds, list) or not all(isinstance(c, str) and c for c in cmds)):
        raise TokenError("cmds must be a list of command names")
    return perms


def make_token(private_key, perms, namespace):
    """Mint an nestlo0 token with a private Ed25519 key."""
    raw = json.dumps(perms, separators=(",", ":"), sort_keys=True).encode()
    parse_permissions(raw)
    return PREFIX0 + b64url(raw) + "." + b64url(sign_sshsig(private_key, raw, namespace))


def decode(token, namespace, now=None):
    """Verify an nestlo0 token's signature and times.

    Returns (permissions, signing key fingerprint). Whether that key is
    registered, and to whom, is the caller's business."""
    if len(token) > MAX_TOKEN:
        raise TokenError("token is longer than 8 KB")
    for prefix in ALIASES0:
        if token.startswith(prefix):
            body = token[len(prefix):]
            break
    else:
        raise TokenError("not an nestlo0 token")
    try:
        payload_b64, sig_b64 = body.split(".")
    except ValueError:
        raise TokenError("malformed token")
    raw = unb64url(payload_b64)
    perms = parse_permissions(raw)
    blob = verify_sshsig(unb64url(sig_b64), raw, namespace)
    now = time.time() if now is None else now
    if "exp" in perms and now >= perms["exp"]:
        raise TokenError("token expired")
    if "nbf" in perms and now < perms["nbf"]:
        raise TokenError("token is not valid yet")
    return perms, fingerprint(blob)


def allows(perms, command_name):
    """Whether a token's cmds grant permits `command_name` ('ls', 'ssh-key list', ...)."""
    cmds = perms.get("cmds")
    granted = DEFAULT_CMDS if cmds is None else cmds
    return command_name in granted
