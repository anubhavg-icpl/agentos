import glob
import json
import os
import time

import pytest

from agentos_services import dlp as D
from agentos_services.dlp import ALL_DETECTORS, Dlp
from conftest import request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

AWS = "AKIAIOSFODNN7EXAMPLE"
GH = "ghp_" + "aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5"
OPENAI = "sk-" + "Zq8Xw3Lm9Vt2Kc7Rb5Nd1Hy6Jf4Gs0TaUe3RiOp"
ENTROPY = "q8Zr3Kx9Wm2Lp7Vt5Nb1Yc6Hd4Jf0Gs8TaUe3Ri"
PEM = ("-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n"
       "KUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQ==\n-----END RSA PRIVATE KEY-----")


def types(text, names=ALL_DETECTORS):
    return sorted({n for _, _, n in Dlp({"mode": "log"}).find(text, names)})


# ── detectors ──────────────────────────────────────────────────────────────
def test_luhn():
    assert D.luhn_ok("4111111111111111")
    assert D.luhn_ok("5500005555555559")
    assert D.luhn_ok("378282246310005")
    assert not D.luhn_ok("4111111111111112")
    assert not D.luhn_ok("")
    assert not D.luhn_ok("41111111x1111111")


def test_credit_card_needs_luhn_and_issuer_prefix():
    assert types("card 4111 1111 1111 1111 exp 12/30") == ["credit_card"]
    assert types("card 4111-1111-1111-1111") == ["credit_card"]
    assert types("amex 378282246310005") == ["credit_card"]
    assert types("card 4111 1111 1111 1112") == []              # fails Luhn
    assert types("ts 1700000000000 ms") == []                    # 13 digits, no issuer prefix
    assert types("order 0000000000000000") == []                 # Luhn-valid but one repeated digit
    assert types("1234567812345670") == []                       # Luhn-valid, no issuer prefix


def test_iban_mod97():
    assert types("pay to DE89 3704 0044 0532 0130 00 today") == ["iban"]
    assert types("GB82WEST12345698765432") == ["iban"]
    assert types("DE89 3704 0044 0532 0130 01") == []            # checksum off by one
    assert types("XX89 3704 0044 0532 0130 00") == []            # unknown country


def test_secret_detectors():
    assert types("key=%s" % AWS) == ["aws_access_key"]
    assert types("token %s" % GH) == ["github_token"]
    assert types("OPENAI=%s" % OPENAI) == ["api_key"]
    assert types("x\n%s\ny" % PEM) == ["private_key"]
    assert types("Authorization: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r") == ["jwt"]
    assert types('aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"') == ["aws_secret_key"]
    assert types("slack xoxb-123456789012-abcdefghijkl") == ["slack_token"]
    assert types('db_password = "Tr0ub4dor&3xKq9Zp"') == ["credential_assignment"]


def test_high_entropy_token():
    assert types("secret blob %s end" % ENTROPY) == ["high_entropy"]
    # shapes that are long and random-looking but are not secrets
    assert types("commit 3572262b1c9a4d0e8f7a6b5c4d3e2f1a0b9c8d7e") == []
    assert types("id 123e4567-e89b-12d3-a456-426614174000") == []
    assert types("sha512-" + "Zq8Xw3Lm9Vt2Kc7Rb5Nd1Hy6Jf4Gs0TaUe3RiOpAb1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2Yz3==") == []
    assert types("getUserAccountBalanceFromTheDatabaseConnection2024Version") == []
    assert types("/usr/lib/python3.11/site-packages/agentos_services/gateway/handlers") == []
    assert types("src/components/billing/InvoiceTableRowActionsMenu2Item") == []


def test_pii_detectors():
    assert types("mail alice.smith+tag@example-corp.co.uk now") == ["email"]
    assert types("call +1 415 555 2671 or (415) 555-2671 or 415-555-2671") == ["phone"]
    assert types("+44 20 7946 0958") == ["phone"]
    # not PII: ssh remotes, systemd instances, reserved domains, versions, dates, IPs, ids
    assert types("git@github.com:org/repo.git") == []
    assert types("getty@tty1.service and noreply@example.com and bob@host.local") == []
    assert types("version 1.2.3 on 2024-01-15 at 10:00:01 from 192.168.100.200:8080") == []
    assert types("build 20240115-1234567 pid 1234567890") == []


def test_overlaps_resolve_by_priority():
    # a private key block contains base64 that would also look high-entropy
    d = Dlp({"mode": "mask"})
    out = d.mask_text("before\n%s\nafter" % PEM, ALL_DETECTORS, {})
    assert out == "before\n[REDACTED:private_key]\nafter"


def test_no_false_positives_on_normal_code():
    code = '''
import hashlib, json, os, re
from dataclasses import dataclass

TOKEN_HEADER = "x-agentos-token"
CACHE_KEY = "agentos:%s:%s"
API_URL = "https://api.example.com/v1/items?page=2&per_page=100"

@dataclass
class Settings:
    password_file: str = "/run/secrets/db-password"
    token_ttl: int = 3600

def digest(path):
    h = hashlib.sha256(open(path, "rb").read()).hexdigest()
    assert h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    return h

def render(user):
    return f"Hello {user.name}, your order #12345678 shipped on 2024-03-09 (tracking 1Z999AA10123456784)"
'''
    assert types(code) == []
    nix = '''
{ pkgs, ... }: {
  services.foo.settings = { passwordFile = "/run/secrets/foo"; apiKeyFile = config.sops.secrets.key.path; };
  environment.etc."foo.conf".text = "listen 127.0.0.1:8080\\nworkers 4";
  hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}
'''
    assert types(nix) == []
    lock = json.dumps({"packages": {"node_modules/x": {"version": "1.0.0", "integrity": "sha512-" + "Zq8Xw3Lm9Vt2Kc7Rb5Nd1Hy6Jf4Gs0TaUe3RiOpAb1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2Yz3=="}}})
    assert types(lock) == []


def test_no_false_positives_on_this_repository():
    """The detectors stay quiet over AgentOS's own source, docs and Nix modules."""
    repo = os.path.dirname(ROOT)
    d = Dlp({"mode": "log"})
    hits = []
    for pattern in ("services/agentos_services/*.py", "modules/*/default.nix", "nixos/**/*.nix", "docs/*.md"):
        for path in glob.glob(os.path.join(repo, pattern), recursive=True):
            if path.endswith(("dlp.py", "dlp.md", "audit.md")):
                continue                     # these name the secret formats on purpose
            with open(path, errors="replace") as f:
                text = f.read()
            for s, e, name in d.find(text, ALL_DETECTORS):
                hits.append((os.path.relpath(path, repo), name))     # never print the value
    assert hits == []


def test_provider_keys_are_detected_literally():
    d = Dlp({"mode": "mask"}, key_source=lambda: ["acme-live-0123456789", "", "short"])
    out = d.scan_body(d.default, b'{"messages":[{"content":"use acme-live-0123456789 and short"}]}', None, "application/json")
    assert out.counts == {"provider_key": 1}                    # "short" is below the minimum length
    assert b"acme-live" not in out.body and b"[REDACTED:provider_key]" in out.body


def test_base64_payloads_are_not_scanned():
    d = Dlp({"mode": "mask"})
    blob = ("Zq8Xw3Lm9Vt2Kc7Rb5Nd1Hy6Jf4Gs0TaUe3RiOp" * 40)
    body = json.dumps({"messages": [{"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": blob}},
        {"type": "text", "text": "what is this"}]}]}).encode()
    out = d.scan_body(d.default, body, None, "application/json")
    assert out.action == "none" and out.body == body


# ── modes and policy ───────────────────────────────────────────────────────
def body_with(text):
    return json.dumps({"model": "m", "messages": [{"role": "user", "content": text}]}).encode()


def test_modes():
    text = "card 4111 1111 1111 1111 mail bob@corp.io key %s" % AWS
    raw = body_with(text)
    for mode, action in (("log", "logged"), ("mask", "masked"), ("block", "blocked")):
        d = Dlp({"mode": mode})
        out = d.scan_body(d.default, raw, None, "application/json")
        assert out.action == action
        assert out.counts == {"credit_card": 1, "email": 1, "aws_access_key": 1}, out.counts
        if mode == "mask":
            msg = json.loads(out.body)["messages"][0]["content"]
            assert msg == "card [REDACTED:credit_card] mail [REDACTED:email] key [REDACTED:aws_access_key]"
            assert json.loads(out.body)["model"] == "m"
        else:
            assert out.body == raw                               # forwarded byte for byte
    d = Dlp({"mode": "off"})
    assert d.scan_body(d.default, raw, None, "application/json").action == "none"
    assert not d.enabled


def test_counts_never_contain_values():
    d = Dlp({"mode": "block"})
    out = d.scan_body(d.default, body_with("%s %s" % (AWS, GH)), None, "application/json")
    assert AWS not in repr(out.counts) and GH not in repr(out.counts)
    assert out.types() == ["aws_access_key", "github_token"]


def test_detector_selection_and_unknown_names():
    d = Dlp({"mode": "block", "detectors": ["email"]})
    assert d.scan_body(d.default, body_with(AWS), None, "application/json").action == "none"
    assert d.scan_body(d.default, body_with("me@corp.io"), None, "application/json").action == "blocked"
    with pytest.raises(ValueError):
        Dlp({"mode": "block", "detectors": ["emial"]})
    with pytest.raises(ValueError):
        Dlp({"mode": "shout"})


def test_overrides_longest_prefix_wins():
    d = Dlp({"mode": "log", "overrides": {
        "ci-": {"mode": "block"}, "ci-sandbox": {"mode": "off"}, "prod": {"mode": "mask", "detectors": ["email"]}}})
    assert d.policy_for("dev-1").mode == "log"
    assert d.policy_for("ci-7").mode == "block"
    assert d.policy_for("ci-sandbox-2").mode == "off"
    assert d.policy_for("prod-a").detectors == ("email",)
    assert Dlp({"mode": "off", "overrides": {"x": {"mode": "block"}}}).enabled
    with pytest.raises(ValueError):
        Dlp({"overrides": {"x": {"mode": "nope"}}})


def test_plain_text_and_binary_bodies():
    d = Dlp({"mode": "mask"})
    out = d.scan_body(d.default, b"mail me: bob@corp.io", None, "text/plain")
    assert out.body == b"mail me: [REDACTED:email]"
    out = d.scan_body(d.default, b"\x89PNG bob@corp.io", None, "image/png")
    assert out.skipped and out.action == "none"
    big = Dlp({"mode": "mask", "max_scan_bytes": 10})
    assert big.too_big(big.default, b"x" * 11) and not Dlp({"mode": "log", "max_scan_bytes": 10}).too_big(
        Dlp({"mode": "log"}).default, b"x" * 11)


def test_scan_speed():
    text = open(os.path.join(ROOT, "agentos_services", "gateway.py")).read() * 20      # ~1 MB of code
    d = Dlp({"mode": "mask"})
    start = time.time()
    d.scan_body(d.default, json.dumps({"c": text}).encode(), None, "application/json")
    assert time.time() - start < 5.0


# ── in the gateway ─────────────────────────────────────────────────────────
class FakeAudit:
    enabled = True

    def __init__(self):
        self.events = []

    def emit(self, etype, actor=None, **data):
        self.events.append((etype, actor, data))

    def require(self):
        pass

    def stats(self):
        return {}


SECRET_PROMPT = "deploy with %s and email carol@corp.io" % AWS


def msg(text, **extra):
    return dict({"model": "claude-test", "max_tokens": 16, "messages": [{"role": "user", "content": text}]}, **extra)


def test_gateway_mask_mode_redacts_before_forwarding(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "mask"}})
    gw.audit = FakeAudit()
    status, _, _ = request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg(SECRET_PROMPT))
    assert status == 200
    sent = upstream.requests[-1]["body"]["messages"][0]["content"]
    assert sent == "deploy with [REDACTED:aws_access_key] and email [REDACTED:email]"
    detections = [e for e in gw.audit.events if e[0] == "dlp.detection"]
    assert len(detections) == 1
    _, actor, data = detections[0]
    assert actor == "a1" and data["action"] == "masked" and data["detections"] == {"aws_access_key": 1, "email": 1}
    assert AWS not in json.dumps(gw.audit.events) and "carol" not in json.dumps(gw.audit.events)
    # the request log notes the findings, not the values
    log = open(os.path.join(gw.cfg["gateway"]["log_dir"], "a1.log")).read()
    assert '"dlp"' in log and AWS not in log


def test_gateway_block_mode_refuses_with_403(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "block"}})
    gw.audit = FakeAudit()
    status, _, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg(SECRET_PROMPT))
    assert status == 403
    err = json.loads(raw)["error"]
    assert err["type"] == "dlp_blocked" and "aws_access_key" in err["message"] and AWS not in err["message"]
    assert upstream.requests == []
    assert [e[2]["action"] for e in gw.audit.events if e[0] == "dlp.detection"] == ["blocked"]
    # clean requests pass
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("fix the bug in parser.py"))[0] == 200


def test_gateway_log_mode_forwards_unchanged(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "log"}})
    gw.audit = FakeAudit()
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg(SECRET_PROMPT))[0] == 200
    assert upstream.requests[-1]["body"]["messages"][0]["content"] == SECRET_PROMPT
    assert [e[2]["action"] for e in gw.audit.events if e[0] == "dlp.detection"] == ["logged"]


def test_gateway_per_agent_override(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "log", "overrides": {"strict-": {"mode": "block"}, "free-": {"mode": "off"}}}})
    assert request(gw, "POST", "/agent/strict-1/anthropic/v1/messages", msg(SECRET_PROMPT))[0] == 403
    assert request(gw, "POST", "/agent/dev-1/anthropic/v1/messages", msg(SECRET_PROMPT))[0] == 200
    gw.audit = FakeAudit()
    assert request(gw, "POST", "/agent/free-1/anthropic/v1/messages", msg(SECRET_PROMPT))[0] == 200
    assert gw.audit.events == [] or all(e[0] != "dlp.detection" for e in gw.audit.events)


def test_gateway_provider_key_is_caught(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "block", "detectors": ["provider_key"]}})
    # the configured Anthropic key ("sk-real-anthropic") must not be sent to the model
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("my key is sk-real-anthropic"))[0] == 403
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("no key here"))[0] == 200


def test_gateway_masks_json_responses_but_not_streams(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "mask", "scan_responses": True}})
    gw.audit = FakeAudit()
    status, headers, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages",
                                   msg("hi", mock_text_rev=("your key is %s" % AWS)[::-1]))
    assert status == 200
    body = json.loads(raw)
    assert body["content"][0]["text"] == "your key is [REDACTED:aws_access_key]"
    assert int(headers["Content-Length"]) == len(raw)
    assert any(e[0] == "dlp.detection" and e[2]["direction"] == "response" for e in gw.audit.events)
    # spend is still recorded for the unmodified response
    assert gw.store.spend("a1") > 0
    # a stream is passed through unscanned (documented limitation)
    status, _, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("hi", stream=True))
    assert status == 200 and b"hello" in raw


def test_gateway_blocks_responses_in_block_mode(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "block", "scan_responses": True}})
    status, _, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("hi", mock_text_rev=("key %s" % AWS)[::-1]))
    assert status == 502 and json.loads(raw)["error"]["type"] == "dlp_blocked"
    assert gw.store.spend("a1") > 0          # the provider already charged for it


def test_gateway_oversized_body_is_refused_when_it_cannot_be_checked(make_gateway, upstream):
    gw = make_gateway(gateway={"dlp": {"mode": "mask", "max_scan_bytes": 200}})
    status, _, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("x" * 500))
    assert status == 413 and json.loads(raw)["error"]["type"] == "dlp_scan_limit"
    assert upstream.requests == []


def test_gateway_without_dlp_is_untouched(make_gateway, upstream):
    gw = make_gateway()
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg(SECRET_PROMPT))[0] == 200
    assert upstream.requests[-1]["body"]["messages"][0]["content"] == SECRET_PROMPT


def test_recordings_keep_the_scanned_response(make_gateway, upstream, tmp_path):
    rec = tmp_path / "rec"
    gw = make_gateway(gateway={"dlp": {"mode": "mask", "scan_responses": True}},
                      recording={"enabled": True, "dir": str(rec)})
    assert request(gw, "POST", "/agent/a1/anthropic/v1/messages", msg("hi", mock_text_rev=("key %s" % AWS)[::-1]))[0] == 200
    saved = (rec / "a1" / "000001.json").read_text()
    assert AWS not in saved and "[REDACTED:aws_access_key]" in saved
    gw = make_gateway(gateway={"dlp": {"mode": "block", "scan_responses": True}},
                      recording={"enabled": True, "dir": str(tmp_path / "rec2")})
    assert request(gw, "POST", "/agent/a2/anthropic/v1/messages", msg("hi", mock_text_rev=("key %s" % AWS)[::-1]))[0] == 502
    blocked = json.loads((tmp_path / "rec2" / "a2" / "000001.json").read_text())
    assert blocked["response"]["status"] == 502 and AWS not in json.dumps(blocked)
