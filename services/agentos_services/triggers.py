"""AgentOS event triggers: GitHub webhooks become orchestrator tasks.

    GitHub ──POST /webhook──▶ reverse proxy / tunnel ──▶ agentos-triggers (127.0.0.1)
                                                              │ verify HMAC, dedupe, match rules
                                                              ▼
                                         orchestrator socket: POST /tasks  (origin = gh:<repo>#<n>)
                                         or, for a rule with `factory = "<line>"`,
                                         factory socket: POST /items (a work item for that line)

Security model (docs/triggers.md has the long version):

  * every request must carry a valid X-Hub-Signature-256 (HMAC-SHA256 of the
    raw body with the shared secret, compared in constant time) before
    anything else is looked at; the body size is capped before it is read;
  * X-GitHub-Delivery is remembered (Redis, or memory with a TTL): a replayed
    delivery is acknowledged and ignored;
  * only the events and repositories named by a rule can do anything, only
    senders whose author_association is trusted, and never bots;
  * text from the event (issue title and body, comments, check output) is
    untrusted. It is substituted into the rule's prompt template in one
    pass, stripped of control characters and length-capped. It only ever
    ends up as the prompt, which the orchestrator passes as one argv
    element; it never reaches a shell, a file name, a workspace or an agent
    name, which all come from the rule;
  * the service has no privileges beyond the orchestrator socket: the
    orchestrator validates, sandboxes and budgets what is submitted.

Orchestrator fields. Rules map onto the orchestrator's submit API. Fields
newer orchestrators understand (`dedupe_key`, `gate`, `workflow`, `publish`)
are tried first; an orchestrator that rejects them (HTTP 400, tasks.py
validates unknown keys) is served the plain fields instead, with the
semantics emulated here: dedupe_key by remembering the task per key while it
is unfinished, and publish by a request marker the root task runner reads.
A rule with gate = true is never submitted without a gate: it fails closed.
`submit_style` pins one behaviour instead of "auto".
"""

import argparse
import collections
import hashlib
import hmac
import http.server
import json
import logging
import re
import signal
import sys
import threading
import time

from . import config as configmod
from . import tasks as T
from .unixapi import call

log = logging.getLogger("agentos.triggers")

EVENTS = ("issues", "issue_comment", "check_run", "pull_request_review_comment")
PLACEHOLDERS = ("issue.title", "issue.body", "issue.number", "comment.body", "comment.author",
                "check.output", "check.name", "repo")
_PLACEHOLDER = re.compile(r"\{(%s)\}" % "|".join(re.escape(p) for p in PLACEHOLDERS))
_REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$")
_DELIVERY = re.compile(r"^[A-Za-z0-9-]{8,64}$")
_RULE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

DEFAULTS = {
    "triggers": {
        "listen": "127.0.0.1",
        "port": 8787,
        "secret_file": "",
        "max_body_bytes": 1024 * 1024,
        "read_timeout_sec": 15,
        "dedupe_ttl_sec": 24 * 3600,
        "dedupe_max": 10000,
        "trusted_associations": ["OWNER", "MEMBER", "COLLABORATOR"],
        "submit_style": "auto",  # auto | workflow | fields | compat
        "max_title_chars": 300,
        "max_text_chars": 6000,
        "max_prompt_bytes": 60000,
        "rules": {},
    },
}
SUBMIT_STYLES = ("auto", "workflow", "fields", "compat")


class ConfigError(ValueError):
    pass


def settings(cfg):
    section = json.loads(json.dumps(DEFAULTS["triggers"]))
    return configmod._merge(section, cfg.get("triggers", {}))


# ── rules ────────────────────────────────────────────────────────────────
def compile_rules(raw):
    """Validate the [triggers.rules.<name>] tables; returns {name: rule dict}."""
    rules = {}
    for name, r in (raw or {}).items():
        if not _RULE_NAME.match(name or ""):
            raise ConfigError("invalid rule name %r" % name)
        if not isinstance(r, dict):
            raise ConfigError("rule %s must be a table" % name)
        event = r.get("event")
        if event not in EVENTS:
            raise ConfigError("rule %s: event must be one of %s" % (name, ", ".join(EVENTS)))
        actions = r.get("action") or []
        if isinstance(actions, str):
            actions = [actions]
        if not actions or not all(isinstance(a, str) and a for a in actions):
            raise ConfigError("rule %s: action must be a non-empty list" % name)
        repo = r.get("repo")
        if not isinstance(repo, str) or not _REPO.match(repo):
            raise ConfigError("rule %s: repo must look like owner/name" % name)
        factory = r.get("factory") or None
        if factory is not None:
            # A factory rule hands the issue to a factory line: the line decides
            # agents, workspace and prompts, so the rule carries none of them
            if event != "issues":
                raise ConfigError("rule %s: factory rules only apply to issues events" % name)
            if not isinstance(factory, str) or not _RULE_NAME.match(factory):
                raise ConfigError("rule %s: factory must be a line name" % name)
        else:
            for key in ("agent", "workspace", "prompt"):
                if not isinstance(r.get(key), str) or not r[key]:
                    raise ConfigError("rule %s: %s is required" % (name, key))
            for ph in re.findall(r"\{([^{}]*)\}", r["prompt"]):
                if ph not in PLACEHOLDERS:
                    raise ConfigError("rule %s: unknown placeholder {%s}" % (name, ph))
        prefix = r.get("command_prefix")
        if prefix and event not in ("issue_comment", "pull_request_review_comment"):
            raise ConfigError("rule %s: command_prefix only applies to comment events" % name)
        out = {
            "name": name, "event": event, "action": list(actions), "repo": repo.lower(),
            "label": r.get("label") or None, "command_prefix": prefix or None,
            "agent": r.get("agent") or "", "workspace": r.get("workspace") or "", "prompt": r.get("prompt") or "",
            "factory": factory,
            "publish": bool(r.get("publish", False)), "gate": bool(r.get("gate", False)),
            "conclusion": list(r.get("conclusion") or []), "trust_labeler": bool(r.get("trust_labeler", True)),
            "budget_usd": r.get("budget_usd"), "timeout_sec": r.get("timeout_sec"),
        }
        rules[name] = out
    return rules


# ── untrusted text ───────────────────────────────────────────────────────
def sanitize(value, limit):
    """Untrusted text as data: printable characters only, capped, inert braces."""
    if value is None:
        return ""
    if not isinstance(value, str):
        value = str(value)
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    text = "".join(c for c in value if c.isprintable() or c in "\n\t")
    if len(text) > limit:
        text = text[:limit].rstrip() + "\n[truncated]"
    # The orchestrator expands {prev_result} in prompts of dependent tasks
    return text.replace("{prev_result}", "{ prev_result}")


def render_prompt(template, values, max_bytes):
    """One-pass substitution: substituted text is never scanned again."""
    out = _PLACEHOLDER.sub(lambda m: values.get(m.group(1), ""), template)
    raw = out.encode()
    if len(raw) > max_bytes:
        out = raw[:max_bytes].decode(errors="ignore")
    if out.startswith("-"):
        out = " " + out  # the orchestrator refuses prompts that look like options
    return out


# ── event matching ───────────────────────────────────────────────────────
def _get(obj, *path):
    for key in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


def _labels(issue):
    return {l.get("name") for l in (_get(issue, "labels") or []) if isinstance(l, dict)}


def _check_pr(payload):
    """The same-repository pull request a check run belongs to, if any."""
    for pr in _get(payload, "check_run", "pull_requests") or []:
        if not isinstance(pr, dict) or not isinstance(pr.get("number"), int):
            continue
        head, base = _get(pr, "head", "repo", "id"), _get(pr, "base", "repo", "id")
        if head is not None and head == base:
            return pr["number"]
    return None


def extract(event, payload, opts):
    """(number, author_association, text values) of an event; number None if unusable."""
    t, body = int(opts["max_title_chars"]), int(opts["max_text_chars"])
    values = {"repo": sanitize(_get(payload, "repository", "full_name"), 200)}
    number, assoc = None, None
    if event in ("issues", "issue_comment"):
        issue = _get(payload, "issue") or {}
        number, assoc = issue.get("number"), issue.get("author_association")
        values["issue.title"] = sanitize(issue.get("title"), t)
        values["issue.body"] = sanitize(issue.get("body"), body)
        url = issue.get("html_url")
        values["issue.url"] = url[:300] if isinstance(url, str) and re.match(r"^https?://[^\s]+$", url) else ""
    if event in ("issue_comment", "pull_request_review_comment"):
        comment = _get(payload, "comment") or {}
        assoc = comment.get("author_association")
        values["comment.body"] = sanitize(comment.get("body"), body)
        values["comment.author"] = sanitize(_get(comment, "user", "login"), 100)
    if event == "pull_request_review_comment":
        pr = _get(payload, "pull_request") or {}
        number = pr.get("number")
        values["issue.title"] = sanitize(pr.get("title"), t)
        values["issue.body"] = sanitize(pr.get("body"), body)
    if event == "check_run":
        check = _get(payload, "check_run") or {}
        number = _check_pr(payload)
        out = check.get("output") or {}
        parts = [out.get("title"), out.get("summary"), out.get("text")]
        values["check.output"] = sanitize("\n\n".join(p for p in parts if isinstance(p, str) and p), body)
        values["check.name"] = sanitize(check.get("name"), 200)
    if isinstance(number, bool) or not isinstance(number, int) or number < 1:
        number = None
    values["issue.number"] = str(number) if number else ""
    return number, assoc, values


def match(rules, event, payload, opts):
    """Rules triggered by an event: [(rule, number, values)], plus skip reasons."""
    hits, skipped = [], []
    action = payload.get("action") if isinstance(payload, dict) else None
    repo = (_get(payload, "repository", "full_name") or "")
    repo = repo.lower() if isinstance(repo, str) else ""
    if event != "check_run" and _get(payload, "sender", "type") == "Bot":
        return hits, ["sender is a bot"]
    trusted = set(opts["trusted_associations"])
    number, assoc, values = extract(event, payload, opts)
    for rule in rules.values():
        why = None
        if rule["event"] != event:
            continue
        if rule["repo"] != repo:
            continue
        if action not in rule["action"]:
            why = "action %r" % action
        elif number is None:
            why = "no issue or pull request number"
        elif rule["label"] and not _label_ok(rule, event, action, payload):
            why = "label"
        elif event == "check_run" and rule["conclusion"] \
                and _get(payload, "check_run", "conclusion") not in rule["conclusion"]:
            why = "conclusion"
        elif event != "check_run" and assoc not in trusted \
                and not (event == "issues" and action == "labeled" and rule["label"] and rule["trust_labeler"]):
            # A label is applied by someone with triage rights: that is the approval
            why = "author_association %r is not trusted" % assoc
        v = dict(values)
        if why is None and rule["command_prefix"]:
            command = (v.get("comment.body") or "").lstrip()
            prefix = rule["command_prefix"]
            if not command.startswith(prefix) or (len(command) > len(prefix) and not command[len(prefix)].isspace()):
                why = "no %s command" % prefix
            else:
                v["comment.body"] = command[len(prefix):].strip()
        if why:
            skipped.append("%s: %s" % (rule["name"], why))
        else:
            hits.append((rule, number, v))
    return hits, skipped


def _label_ok(rule, event, action, payload):
    if event == "issues" and action == "labeled":
        return _get(payload, "label", "name") == rule["label"]
    return rule["label"] in _labels(_get(payload, "issue") or {})


# ── signatures ───────────────────────────────────────────────────────────
def sign(secret, body):
    return "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()


def verify_signature(secret, body, header):
    """Constant-time check of an X-Hub-Signature-256 header value."""
    if not secret or not isinstance(header, str) or not header.startswith("sha256="):
        return False
    return hmac.compare_digest(sign(secret, body).encode(), header.encode())


# ── state: delivery ids, dedupe keys, publish markers ────────────────────
class MemoryState:
    """Bounded in-memory state with TTL (used by tests, or when Redis is down)."""

    def __init__(self, ttl=86400, max_entries=10000, clock=time.time):
        self.ttl, self.max, self.clock = ttl, max_entries, clock
        self.items = collections.OrderedDict()
        self.lock = threading.Lock()

    def _purge(self):
        now = self.clock()
        while self.items:
            key, (exp, _v) = next(iter(self.items.items()))
            if exp > now and len(self.items) <= self.max:
                break
            del self.items[key]

    def set_nx(self, key, value="1"):
        with self.lock:
            self._purge()
            if key in self.items:
                return False
            self.items[key] = (self.clock() + self.ttl, value)
            self._purge()
            return True

    def get(self, key):
        with self.lock:
            self._purge()
            hit = self.items.get(key)
            return hit[1] if hit else None

    def put(self, key, value, ttl=None):
        with self.lock:
            self.items[key] = (self.clock() + (ttl or self.ttl), value)
            self.items.move_to_end(key)
            self._purge()

    def delete(self, key):
        with self.lock:
            self.items.pop(key, None)


class RedisState:
    def __init__(self, client, ttl=86400, prefix="agentos:"):
        self.r, self.ttl, self.prefix = client, ttl, prefix

    def set_nx(self, key, value="1"):
        return bool(self.r.set(self.prefix + key, value, nx=True, ex=self.ttl))

    def get(self, key):
        return self.r.get(self.prefix + key)

    def put(self, key, value, ttl=None):
        self.r.set(self.prefix + key, value, ex=ttl or self.ttl)

    def delete(self, key):
        self.r.delete(self.prefix + key)


# ── submission to the orchestrator ───────────────────────────────────────
def orchestrator_client(socket_path):
    def submit(body):
        return call(socket_path, "POST", "/tasks", body)

    def task_status(task_id):
        status, obj = call(socket_path, "GET", "/tasks/" + task_id)
        return obj.get("status") if status == 200 else None
    return submit, task_status


def factory_client(socket_path):
    def submit(body):
        return call(socket_path, "POST", "/items", body)
    return submit


def task_ids(obj):
    return [t["id"] for t in (obj.get("tasks") or []) if isinstance(t, dict) and isinstance(t.get("id"), str)] \
        if isinstance(obj, dict) else []


class Transient(Exception):
    """The orchestrator could not be reached or failed; GitHub should retry."""


class TriggerService:
    def __init__(self, cfg, secret, state, submit, task_status, publish_state=None, clock=time.time,
                 factory_submit=None):
        self.opts = settings(cfg)
        self.factory_submit = factory_submit
        self.secret = secret
        self.rules = compile_rules(self.opts["rules"])
        if self.opts["submit_style"] not in SUBMIT_STYLES:
            raise ConfigError("submit_style must be one of %s" % ", ".join(SUBMIT_STYLES))
        self.state = state
        self.publish_state = publish_state or state
        self.submit_fn = submit
        self.task_status = task_status
        self.max_body = int(self.opts["max_body_bytes"])

    # -- body construction ---------------------------------------------
    def bodies(self, rule, number, values, event):
        """The submit bodies to try, in order: [(style, body)]."""
        repo = rule["repo"]
        origin = "gh:%s#%d" % (repo, number)
        dedupe = "gh:" + hashlib.sha256(("%s#%d:%s" % (repo, number, event)).encode()).hexdigest()
        prompt = render_prompt(rule["prompt"], values, int(self.opts["max_prompt_bytes"]))
        base = {"agent": rule["agent"], "workspace": rule["workspace"], "prompt": prompt, "origin": origin}
        for key in ("budget_usd", "timeout_sec"):
            if rule.get(key) is not None:
                base[key] = rule[key]
        title = values.get("issue.title") or ("change for %s" % origin)
        block = {"repo": repo, "title": ("AgentOS: " + title.split("\n")[0])[:200],
                 "body": "Requested by a GitHub %s event on %s." % (event, origin)}
        style = self.opts["submit_style"]
        out = []
        # A two-node publish workflow is only sent when asked for explicitly:
        # the orchestrator takes a `publish` block on the task itself.
        if rule["publish"] and style == "workflow":
            run = dict(base)
            run.pop("origin")
            if rule["gate"]:
                run["gate"] = True
            run["id"] = "run"
            pub = {"id": "publish", "kind": "publish", "workspace": rule["workspace"], "depends_on": ["run"],
                   "publish": block}
            out.append(("workflow", {"origin": origin, "dedupe_key": dedupe, "workflow": [run, pub]}))
        if style in ("auto", "fields"):
            body = dict(base, dedupe_key=dedupe)
            if rule["gate"]:
                body["gate"] = True
            if rule["publish"]:
                body["publish"] = block
            out.append(("fields", body))
        if style in ("auto", "compat") and not rule["gate"]:
            out.append(("compat", dict(base)))
        if not out:
            raise ConfigError("rule %s needs a gate, which style %r cannot express" % (rule["name"], style))
        return out, dedupe, block

    def _live(self, task_id):
        try:
            return self.task_status(task_id) in ("queued", "running", "awaiting_approval")
        except OSError:
            return False

    def submit_factory(self, rule, number, values):
        """Hand an issue to a factory line (POST /items). Returns a result dict; raises Transient."""
        if self.factory_submit is None:
            return {"rule": rule["name"], "status": "rejected", "error": "no factory socket configured"}
        item = {
            "line": rule["factory"],
            "title": (values.get("issue.title") or "issue #%d" % number).split("\n")[0],
            "body": values.get("issue.body") or "",
            "source": {"kind": "github", "repo": rule["repo"], "number": number, "url": values.get("issue.url") or ""},
        }
        try:
            status, obj = self.factory_submit(item)
        except OSError as exc:
            raise Transient("factory unreachable: %s" % exc)
        obj = obj if isinstance(obj, dict) else {}
        if status in (200, 201):
            dup = status == 200 or bool(obj.get("duplicate") or obj.get("deduplicated"))
            return {"rule": rule["name"], "status": "duplicate" if dup else "submitted", "style": "factory",
                    "line": rule["factory"], "item": obj.get("id") or (obj.get("item") or {}).get("id")}
        if status == 409:
            return {"rule": rule["name"], "status": "duplicate", "line": rule["factory"]}
        if status >= 500:
            raise Transient("factory returned %d" % status)
        return {"rule": rule["name"], "status": "rejected", "error": str(obj.get("error") or "HTTP %d" % status)[:300]}

    def submit(self, rule, number, values, event):
        """Submit one match. Returns a result dict; raises Transient."""
        if rule.get("factory"):
            return self.submit_factory(rule, number, values)
        bodies, dedupe, block = self.bodies(rule, number, values, event)
        last = None
        for style, body in bodies:
            if style == "compat":
                prev = self.state.get("triggers:key:" + dedupe)
                if prev and self._live(prev):
                    return {"rule": rule["name"], "status": "duplicate", "task": prev}
            try:
                status, obj = self.submit_fn(body)
            except OSError as exc:
                raise Transient("orchestrator unreachable: %s" % exc)
            if status == 201:
                ids = task_ids(obj)
                if style == "compat" and ids:
                    self.state.put("triggers:key:" + dedupe, ids[0], ttl=7 * 24 * 3600)
                    if rule["publish"]:
                        self.publish_state.put("publish:" + ids[0], json.dumps(block), ttl=T.TASK_TTL)
                return {"rule": rule["name"], "status": "submitted", "style": style, "tasks": ids}
            if status == 409 or (status == 200 and isinstance(obj, dict) and (obj.get("duplicate") or obj.get("deduplicated"))):
                return {"rule": rule["name"], "status": "duplicate", "tasks": task_ids(obj)}
            if status >= 500:
                raise Transient("orchestrator returned %d" % status)
            last = (obj.get("error") if isinstance(obj, dict) else None) or "HTTP %d" % status
            log.info("rule %s: %s submit refused (%s)", rule["name"], style, last)
        return {"rule": rule["name"], "status": "rejected", "error": str(last)[:300]}

    # -- the webhook ----------------------------------------------------
    def handle(self, method, path, headers, read_body):
        """Returns (status, JSON object). `read_body(n)` reads the request body."""
        path = path.split("?", 1)[0]
        headers = _Headers(headers)
        if method == "GET" and path == "/health":
            return 200, {"status": "ok", "rules": len(self.rules)}
        if path != "/webhook":
            return 404, {"error": "not found"}
        if method != "POST":
            return 405, {"error": "method not allowed"}
        try:
            length = int(headers.get("Content-Length", ""))
        except ValueError:
            return 411, {"error": "Content-Length required"}
        if length < 0:
            return 400, {"error": "bad Content-Length"}
        if length > self.max_body:
            return 413, {"error": "payload too large"}
        body = read_body(length)
        if not verify_signature(self.secret, body, headers.get("X-Hub-Signature-256")):
            log.warning("rejected a webhook with a missing or invalid signature")
            return 401, {"error": "invalid signature"}
        event = headers.get("X-GitHub-Event", "")
        delivery = headers.get("X-GitHub-Delivery", "")
        if not _DELIVERY.match(delivery):
            return 400, {"error": "missing or malformed X-GitHub-Delivery"}
        if event == "ping":
            return 200, {"status": "pong"}
        try:
            payload = json.loads(body)
        except ValueError:
            return 400, {"error": "body is not JSON"}
        if not isinstance(payload, dict):
            return 400, {"error": "body is not an object"}
        if event not in EVENTS:
            return 200, {"status": "ignored", "reason": "event %s" % event[:40]}
        try:
            fresh = self.state.set_nx("triggers:delivery:" + delivery)
        except Exception:
            log.exception("state store unavailable")
            return 503, {"error": "state store unavailable"}
        if not fresh:
            return 200, {"status": "duplicate", "delivery": delivery}
        hits, skipped = match(self.rules, event, payload, self.opts)
        results = []
        try:
            for rule, number, values in hits:
                results.append(self.submit(rule, number, values, event))
        except Transient as exc:
            # Let GitHub's redelivery (or a manual one) through
            self.state.delete("triggers:delivery:" + delivery)
            log.error("delivery %s: %s", delivery, exc)
            return 502, {"error": "could not submit the task", "results": results}
        except ConfigError as exc:
            log.error("delivery %s: %s", delivery, exc)
            results.append({"status": "error", "error": str(exc)})
        for line in skipped:
            log.info("delivery %s: skipped %s", delivery, line)
        return 200, {"status": "ok" if hits else "ignored", "results": results, "skipped": skipped}


class _Headers:
    """Case-insensitive view of a header mapping."""

    def __init__(self, headers):
        self.h = {k.lower(): v for k, v in headers.items()}

    def get(self, key, default=None):
        return self.h.get(key.lower(), default)


# ── HTTP server ──────────────────────────────────────────────────────────
def make_server(service, listen, port):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "agentos-triggers"
        timeout = float(service.opts["read_timeout_sec"])

        def _serve(self):
            self.close_connection = True
            try:
                status, obj = service.handle(self.command, self.path, self.headers, self.rfile.read)
            except Exception:
                log.exception("error handling %s %s", self.command, self.path)
                status, obj = 500, {"error": "internal error"}
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_DELETE = _serve

        def log_message(self, fmt, *args):
            log.debug(fmt, *args)

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

    return Server((listen, port), Handler)


def read_secret(path):
    with open(path, "rb") as f:
        secret = f.read().strip()
    if len(secret) < 8:
        raise ConfigError("the webhook secret in %s is empty or too short" % path)
    return secret


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS GitHub webhook triggers")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--listen", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--secret-file", default=None)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    opts = settings(cfg)
    secret_file = args.secret_file or opts["secret_file"]
    if not secret_file:
        print("no webhook secret: set agentos.triggers.secretFile", file=sys.stderr)
        return 2
    try:
        secret = read_secret(secret_file)
        from .store import connect
        client = connect(cfg["redis"]["url"])
        client.ping()
        state = RedisState(client, ttl=int(opts["dedupe_ttl_sec"]))
    except (OSError, ConfigError) as exc:
        print("cannot start: %s" % exc, file=sys.stderr)
        return 2
    submit, task_status = orchestrator_client(T.settings(cfg, "orchestrator")["socket"])
    factory_socket = (cfg.get("factory") or {}).get("socket") or "/run/agentos-factory/factory.sock"
    try:
        service = TriggerService(cfg, secret, state, submit, task_status, factory_submit=factory_client(factory_socket))
    except ConfigError as exc:
        print("invalid trigger configuration: %s" % exc, file=sys.stderr)
        return 2
    server = make_server(service, args.listen or opts["listen"], args.port if args.port is not None else int(opts["port"]))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    log.info("listening on %s:%d with %d rule(s)", *server.server_address[:2], len(service.rules))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
