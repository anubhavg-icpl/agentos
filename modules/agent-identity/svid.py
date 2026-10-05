#!/usr/bin/env python3
"""nestlo-svid: SPIFFE helpers for Nestlo (modules/agent-identity, docs/agent-identity.md).

Library and CLI in one file. The library part is dependency-light (PyJWT with
cryptography) so the model gateway can import it to accept a JWT-SVID as the
agent credential:

    import svid
    ident = svid.verify(token, svid.load_jwks(cfg["bundle_file"]),
                        audience=cfg["audience"], trust_domain=cfg["trust_domain"])
    agent = svid.agent_id(ident["sub"], cfg["trust_domain"])    # None if not an agent SVID

CLI:
    nestlo-svid jwt AUDIENCE [--agent NAME]   fetch a JWT-SVID through the Workload API, print the token
    nestlo-svid x509 [--write DIR]            fetch the X.509-SVID (spire-agent api fetch x509)
    nestlo-svid verify [--token T] [--audience A]   verify a JWT-SVID (stdin if no --token); prints JSON
    nestlo-svid jwks-pem                      print the bundle's JWT signing keys as PEM public keys (JSON list)
"""

import argparse
import json
import os
import re
import subprocess
import sys

CONFIG = os.environ.get("NESTLO_SVID_CONFIG", "/etc/nestlo/agent-identity.json")
# Same rule as nestlo_services.config.valid_agent_id
_AGENT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
ALGORITHMS = ["ES256", "ES384", "ES512", "RS256", "RS384", "RS512", "PS256", "PS384", "PS512"]


class SvidError(Exception):
    pass


def load_config(path=CONFIG):
    with open(path) as f:
        return json.load(f)


def load_jwks(path):
    """The trust bundle in SPIFFE (JWKS) format: `spire-server bundle show -format spiffe`."""
    with open(path) as f:
        return json.load(f)


def _jwt_keys(jwks):
    # SPIFFE bundles hold X.509 authorities (use=x509-svid) and JWT authorities (use=jwt-svid)
    return [k for k in jwks.get("keys", []) if k.get("use") == "jwt-svid"]


def verify(token, jwks, audience, trust_domain, leeway=5):
    """Verify a JWT-SVID against the bundle; returns the claims.

    Checks the signature (key chosen by `kid`), exp, that `audience` is in aud,
    and that sub is a SPIFFE ID of `trust_domain`. Raises SvidError."""
    import jwt  # PyJWT

    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as exc:
        raise SvidError("malformed token: %s" % exc)
    alg = header.get("alg")
    if alg not in ALGORITHMS:          # never "none" or an HMAC alg
        raise SvidError("unsupported alg %r" % alg)
    keys = [k for k in _jwt_keys(jwks) if k.get("kid") == header.get("kid")]
    if not keys:
        raise SvidError("no JWT signing key with kid %r in the bundle" % header.get("kid"))
    try:
        claims = jwt.decode(token, jwt.PyJWK(keys[0]).key, algorithms=[alg], audience=audience,
                            leeway=leeway, options={"require": ["exp", "aud", "sub"]})
    except jwt.PyJWTError as exc:
        raise SvidError(str(exc))
    if not claims["sub"].startswith("spiffe://%s/" % trust_domain):
        raise SvidError("subject %r is not in trust domain %s" % (claims["sub"], trust_domain))
    return claims


def agent_id(spiffe_id, trust_domain, prefix="agent"):
    """spiffe://TD/agent/NAME -> NAME (a valid gateway agent id), else None."""
    head = "spiffe://%s/%s/" % (trust_domain, prefix)
    if not spiffe_id.startswith(head):
        return None
    name = spiffe_id[len(head):]
    return name if _AGENT_ID.match(name) else None


def jwks_to_pem(jwks):
    """PEM public keys of the bundle's JWT authorities (for OpenBao's jwt_validation_pubkeys)."""
    import jwt
    from cryptography.hazmat.primitives import serialization

    return [jwt.PyJWK(k).key.public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
        for k in _jwt_keys(jwks)]


# ── CLI ─────────────────────────────────────────────────────────────────────
def _spire_agent(*args):
    cfg = load_config()
    cmd = [os.environ.get("NESTLO_SPIRE_AGENT", cfg.get("spire_agent", "spire-agent")), "api", *args,
           "-socketPath", os.environ.get("SPIFFE_ENDPOINT_SOCKET", cfg["workload_socket"]).removeprefix("unix://")]
    return subprocess.run(cmd, capture_output=True, text=True)


def _find(obj, key):
    """First value of `key` anywhere in a JSON document (protojson casing differs between versions)."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            r = _find(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find(v, key)
            if r is not None:
                return r
    return None


def cmd_jwt(args):
    cfg = load_config()
    argv = ["fetch", "jwt", "-audience", args.audience, "-output", "json"]
    if args.agent:
        argv += ["-spiffeID", "spiffe://%s/agent/%s" % (cfg["trust_domain"], args.agent)]
    r = _spire_agent(*argv)
    if r.returncode != 0:
        sys.exit("nestlo-svid: %s" % (r.stderr.strip() or r.stdout.strip()))
    token = _find(json.loads(r.stdout), "svid")
    if not token:
        sys.exit("nestlo-svid: no JWT-SVID for this workload (no registration entry matches it?)")
    print(token)


def cmd_x509(args):
    argv = ["fetch", "x509"] + (["-write", args.write] if args.write else [])
    r = _spire_agent(*argv)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)


def cmd_verify(args):
    cfg = load_config()
    token = (args.token or sys.stdin.read()).strip()
    try:
        claims = verify(token, load_jwks(cfg["bundle_file"]), args.audience or cfg["audience"], cfg["trust_domain"])
    except (SvidError, OSError, ValueError) as exc:
        print(json.dumps({"valid": False, "error": str(exc)}))
        sys.exit(1)
    print(json.dumps({"valid": True, "spiffe_id": claims["sub"], "agent": agent_id(claims["sub"], cfg["trust_domain"]),
                      "aud": claims["aud"], "exp": claims["exp"]}))


def cmd_jwks_pem(args):
    cfg = load_config()
    print(json.dumps(jwks_to_pem(load_jwks(args.bundle or cfg["bundle_file"]))))


def main(argv=None):
    p = argparse.ArgumentParser(prog="nestlo-svid", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("jwt")
    j.add_argument("audience")
    j.add_argument("--agent")
    j.set_defaults(fn=cmd_jwt)
    x = sub.add_parser("x509")
    x.add_argument("--write")
    x.set_defaults(fn=cmd_x509)
    v = sub.add_parser("verify")
    v.add_argument("--token")
    v.add_argument("--audience")
    v.set_defaults(fn=cmd_verify)
    k = sub.add_parser("jwks-pem")
    k.add_argument("--bundle")
    k.set_defaults(fn=cmd_jwks_pem)
    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
