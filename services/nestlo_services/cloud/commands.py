"""The Nestlo Cloud command language (the exe.dev command set).

The same commands run over SSH (`ssh lobby@host ls --json`) and over HTTPS
(`POST /exec` with the command as the body). Every command answers a JSON
object; `--json` prints it raw, otherwise it is rendered as text. `<cmd>
--help` describes a command (flags and examples) without running it.

Access model:
  - a VM's owner has full ("root") access
  - team admins and billing owners have root access to their team's VMs
  - `share add <vm> <email|team> [--role web|root]` grants web access (the
    HTTPS proxy) or root access (also the shell, `ssh` and `tunnel`)
  - a public VM serves its HTTPS proxy to anyone
"""

import datetime
import json
import random
import re
import shlex
import socket

from . import plans as P
from . import tokens as TK
from .state import (DOMAIN_RE, NAME_RE, ROLES, SHARE_ROLES, TAG_RE, StateError, new_id, norm_email,
                    valid_vm_name)

ADJ = ("amber", "brisk", "calm", "deft", "eager", "fond", "glad", "hazy", "keen", "lucid", "merry",
       "nimble", "plucky", "quiet", "rapid", "sunny", "tidy", "vivid", "witty", "zesty")
NOUN = ("otter", "falcon", "maple", "comet", "harbor", "lantern", "meadow", "pebble", "quartz",
        "raven", "sparrow", "tundra", "willow", "yarrow", "badger", "cedar", "delta", "ember")
INTEGRATION_TYPES = ("http-proxy", "github", "llm", "peer")
HEADER_RE = re.compile(r"^([A-Za-z0-9-]{1,64}):\s?(.{0,4096})$")
RANGES = {"24h": 1, "7d": 7, "30d": 30, "cycle": None}


class CommandError(Exception):
    def __init__(self, message, status=422):
        super().__init__(message)
        self.status = status
        self.message = message


class Ctx:
    """Who runs a command and how.

    via: "ssh" or "http"; perms: the token permissions for "http";
    key: the fingerprint of the SSH key or token-signing key."""

    def __init__(self, user, via="ssh", key=None, perms=None, stdin=None):
        self.user = user
        self.via = via
        self.key = key
        self.perms = perms
        self.stdin = stdin


class Spec:
    def __init__(self, name, fn, help, args=(), flags=None, examples=(), admin=False, ssh_only=False,
                 rest=False):
        self.name, self.fn, self.help = name, fn, help
        self.args = list(args)          # [(name, required)]
        self.flags = dict(flags or {})  # "--name": "str" | "bool" | "list"
        self.examples = list(examples)
        self.admin = admin
        self.ssh_only = ssh_only
        self.rest = rest                # the last positional takes the remaining words

    def describe(self):
        return {"command": self.name, "help": self.help,
                "args": [{"name": n, "required": r} for n, r in self.args],
                "flags": {f: t for f, t in sorted(self.flags.items())},
                "examples": self.examples, "admin_only": self.admin, "ssh_only": self.ssh_only}


def parse(spec, words):
    """words after the command name -> (positional dict, flag dict)."""
    pos, flags, i = [], {}, 0
    while i < len(words):
        w = words[i]
        if w == "--":
            pos.extend(words[i + 1:])
            break
        if w.startswith("--") and len(w) > 2:
            name, eq, value = w.partition("=")
            kind = spec.flags.get(name)
            if kind is None:
                raise CommandError("%s: unknown flag %s (see `%s --help`)" % (spec.name, name, spec.name), 400)
            if kind == "bool":
                flags[name] = True if not eq else value.lower() in ("1", "true", "yes", "on")
            else:
                if not eq:
                    i += 1
                    if i >= len(words):
                        raise CommandError("%s: %s needs a value" % (spec.name, name), 400)
                    value = words[i]
                if kind == "list":
                    flags.setdefault(name, []).append(value)
                else:
                    flags[name] = value
        elif w.startswith("-") and len(w) == 2 and ("-" + w) in spec.flags and spec.flags["-" + w] == "bool":
            flags["-" + w] = True
        else:
            pos.append(w)
        i += 1
    names = [n for n, _ in spec.args]
    if spec.rest and len(pos) > len(names):
        pos = pos[:len(names) - 1] + [" ".join(pos[len(names) - 1:])]
    if len(pos) > len(names) and not (spec.args and spec.args[-1][0].endswith("...")):
        raise CommandError("%s: too many arguments (see `%s --help`)" % (spec.name, spec.name), 400)
    out = {}
    for idx, (n, required) in enumerate(spec.args):
        if n.endswith("..."):
            out[n[:-3]] = pos[idx:]
            if required and not out[n[:-3]]:
                raise CommandError("%s: missing <%s>" % (spec.name, n[:-3]), 400)
            break
        if idx < len(pos):
            out[n] = pos[idx]
        elif required:
            raise CommandError("%s: missing <%s> (see `%s --help`)" % (spec.name, n, spec.name), 400)
        else:
            out[n] = None
    return out, flags


class Cloud:
    """Runs commands against the state and the VM helper.

    vmd: object with create/start/stop/destroy/resize/copy/stat/sync/status
    (backend.VmdClient, or a fake in tests)."""

    def __init__(self, cfg, state, vmd, audit=None, box=None, clock=None, gateway=None):
        self.cfg = cfg
        self.st = state
        self.vmd = vmd
        self.audit = audit
        self.box = box
        self.clock = clock or state.clock
        self.gateway = gateway
        self.specs = {}
        self._register()

    # ── configuration helpers ──────────────────────────────────────────
    @property
    def domain(self):
        return self.cfg["domain"]

    def scheme(self):
        return "http" if self.cfg.get("tls") == "off" else "https"

    def vm_url(self, vm, port=None):
        host = vm["name"] + ("-%d" % port if port else "") + "." + self.domain
        return "%s://%s/" % (self.scheme(), host)

    def emit(self, etype, ctx, **data):
        if self.audit is not None:
            try:
                self.audit.emit(etype, ctx.user["email"] if ctx and ctx.user else "system", **data)
            except Exception:
                pass

    def limits_of(self, owner):
        """(plan limits, owner key for pools) of a user or their team."""
        team = self.st.team(owner.get("team")) if owner.get("team") else None
        src = team or owner
        overrides = (self.cfg.get("plan_overrides") or {}).get(src["plan"], {})
        lim = P.limits(src["plan"], overrides, src.get("pool_cpu"), src.get("pool_memory_mb"))
        return lim, ("team-" + team["id"]) if team else ("user-" + owner["id"])

    def pool_vms(self, owner):
        """VMs that share the owner's pool: the team's VMs for team members."""
        if owner.get("team"):
            team = self.st.team(owner["team"])
            out = []
            for uid in (team or {}).get("members", {}):
                out.extend(v for v in self.st.vms_of(uid) if v.get("team") == owner["team"])
            return out
        return [v for v in self.st.vms_of(owner["id"]) if not v.get("team")]

    # ── access ─────────────────────────────────────────────────────────
    def access(self, user, vm):
        """'root', 'web' or None for `user` on `vm`."""
        if user is None:
            return None
        if vm["owner"] == user["id"]:
            return "root"
        if vm.get("team") and user.get("team") == vm["team"]:
            team = self.st.team(vm["team"])
            role = (team or {}).get("members", {}).get(user["id"])
            if role in ("admin", "billing_owner"):
                return "root"
            if vm.get("team_share"):
                return vm["team_share"]
        role = vm.get("shares", {}).get(user["email"].lower())
        return role

    def find_vm(self, ctx, name, need="root"):
        vm = self.st.vm_by_name(name)
        acc = self.access(ctx.user, vm) if vm else None
        if vm is None or acc is None:
            raise CommandError("no VM named %r" % name, 404)
        if need == "owner" and not (vm["owner"] == ctx.user["id"] or self._team_admin(ctx.user, vm)):
            raise CommandError("only the owner of %s (or a team admin) can do that" % name, 403)
        if need == "root" and acc != "root":
            raise CommandError("you have web access to %s, not root access" % name, 403)
        return vm

    def _team_admin(self, user, vm):
        if not vm.get("team") or user.get("team") != vm["team"]:
            return False
        team = self.st.team(vm["team"])
        return (team or {}).get("members", {}).get(user["id"]) in ("admin", "billing_owner")

    # ── VM views ───────────────────────────────────────────────────────
    def view(self, vm, user=None, long=False):
        status = vm.get("status") or ("running" if vm.get("desired") == "running" else "stopped")
        out = {
            "vm_name": vm["name"], "https_url": self.vm_url(vm), "ssh_dest": vm["name"] + "." + self.domain,
            "status": status, "region": vm.get("region") or self.cfg.get("region", "local"),
            "region_display": self.cfg.get("region_display") or self.cfg.get("region", "local"),
        }
        if user is not None:
            out["access"] = self.access(user, vm)
        if long:
            owner = self.st.user(vm["owner"]) or {}
            out.update({
                "owner": owner.get("email"), "image": vm["image"], "cpu": vm["cpu"],
                "memory": P.fmt_mb(vm["memory_mb"]), "disk": "%d GB" % vm["disk_gb"], "tags": vm.get("tags", []),
                "comment": vm.get("comment", ""), "port": vm.get("port"), "public": vm.get("public", False),
                "standalone": vm.get("standalone", False), "created": vm["created"], "ip": vm.get("ip"),
                "domains": vm.get("domains", []), "team": vm.get("team"),
                "ssh_command": self.ssh_command(vm),
            })
        return out

    def ssh_command(self, vm):
        return "ssh -t %s@%s ssh %s" % (self.cfg.get("lobby_user", "lobby"), self.cfg.get("ssh_host", self.domain),
                                       vm["name"])

    # ── dispatch ───────────────────────────────────────────────────────
    def resolve(self, words):
        """Longest registered command name at the start of `words`."""
        for n in (3, 2, 1):
            if len(words) >= n and " ".join(words[:n]) in self.specs:
                return self.specs[" ".join(words[:n])], words[n:]
        return None, words

    def run_line(self, ctx, line):
        try:
            words = shlex.split(line)
        except ValueError as exc:
            raise CommandError("cannot parse the command: %s" % exc, 400)
        return self.run(ctx, words)

    def run(self, ctx, words):
        """Run a command; returns (spec name, result dict). Raises CommandError."""
        words = list(words)
        if not words:
            words = ["help"]
        for i, w in enumerate(words):
            if w == "--json":
                words.pop(i)
                break
        spec, rest = self.resolve(words)
        if spec is None:
            raise CommandError("unknown command %r; run `help` for the list" % words[0], 404)
        if "--help" in rest or "-h" in rest:
            return spec.name, spec.describe()
        if ctx.via == "http":
            if spec.ssh_only:
                raise CommandError("%s needs a terminal; run it over SSH" % spec.name, 400)
            if not TK.allows(ctx.perms or {}, spec.name):
                raise CommandError("this token does not allow %r" % spec.name, 403)
        if spec.admin and not (ctx.user or {}).get("admin"):
            raise CommandError("%s is for administrators" % spec.name, 403)
        args, flags = parse(spec, rest)
        try:
            return spec.name, spec.fn(ctx, args, flags)
        except (StateError, P.QuotaError) as exc:
            raise CommandError(getattr(exc, "message", str(exc)), getattr(exc, "status", 422))

    def _register(self):
        S = Spec
        cmds = [
            S("help", self.c_help, "List commands, or describe one", [("command...", False)]),
            S("doc", self.c_doc, "Where the documentation is", [("slug", False)]),
            S("whoami", self.c_whoami, "Show the current user"),
            S("ls", self.c_ls, "List your VMs (and VMs shared with you with --shared)", [("pattern", False)],
              {"-l": "bool", "--l": "bool", "--shared": "bool", "--tag": "str"}, ["ls", "ls -l", "ls 'web-*' --json"]),
            S("new", self.c_new, "Create a VM", [],
              {"--name": "str", "--image": "str", "--cpu": "str", "--memory": "str", "--disk": "str",
               "--env": "list", "--tag": "list", "--comment": "str", "--command": "str", "--setup-script": "str",
               "--prompt": "str", "--integration": "list", "--standalone": "bool", "--no-email": "bool",
               "--registry-auth": "str", "--port": "str"},
              ["new", "new --name web --cpu 4 --memory 16GB --tag prod",
               "new --image ubuntu:24.04 --env FOO=bar", "new --prompt 'build a todo app on port 8000'"]),
            S("rm", self.c_rm, "Delete VMs", [("vm...", True)]),
            S("restart", self.c_restart, "Restart a VM", [("vm", True)]),
            S("stop", self.c_stop, "Stop a VM (its disk is kept)", [("vm", True)]),
            S("start", self.c_start, "Start a stopped VM", [("vm", True)]),
            S("rename", self.c_rename, "Rename a VM", [("vm", True), ("new_name", True)]),
            S("tag", self.c_tag, "Add (or with -d remove) tags", [("vm", True), ("tags...", True)], {"-d": "bool", "--d": "bool"}),
            S("comment", self.c_comment, "Set or clear a VM's comment", [("vm", True), ("text", False)], rest=True),
            S("stat", self.c_stat, "Show a VM's metrics", [("vm", True)], {"--range": "str"}),
            S("cp", self.c_cp, "Copy a VM (disk and settings)", [("vm", True), ("new_name", False)],
              {"--copy-tags": "str", "--cpu": "str", "--memory": "str", "--disk": "str"}),
            S("resize", self.c_resize, "Resize a VM (the disk only grows)", [("vm", True)],
              {"--cpu": "str", "--memory": "str", "--disk": "str"}),
            S("share", self.c_share_help, "Share a VM's HTTPS proxy: show port set-public set-private add remove add-link remove-link"),
            S("share show", self.c_share_show, "Show who can reach a VM", [("vm", True)], {"--qr": "bool"}),
            S("share port", self.c_share_port, "Show or set the port the proxy forwards to", [("vm", True), ("port", False)]),
            S("share set-public", self.c_share_public, "Serve the VM's HTTPS proxy to anyone", [("vm", True)]),
            S("share set-private", self.c_share_private, "Serve it only to users it is shared with", [("vm", True)]),
            S("share add", self.c_share_add, "Share with an email address or your team", [("vm", True), ("target", True)],
              {"--message": "str", "--role": "str", "--qr": "bool"}, ["share add web alice@example.com",
                                                                     "share add web team --role root"]),
            S("share remove", self.c_share_remove, "Stop sharing", [("vm", True), ("target", True)]),
            S("share add-link", self.c_share_add_link, "Create a share link", [("vm", True)], {"--role": "str", "--qr": "bool"}),
            S("share add-share-link", self.c_share_add_link, "Alias of share add-link", [("vm", True)], {"--role": "str"}),
            S("share remove-link", self.c_share_remove_link, "Revoke a share link", [("vm", True), ("token", True)]),
            S("share remove-share-link", self.c_share_remove_link, "Alias of share remove-link", [("vm", True), ("token", True)]),
            S("share receive-email", self.c_receive_email, "Not available on Nestlo Cloud", [("vm", True), ("state", False)]),
            S("domain", self.c_domain_help, "Custom domains: add ls rm"),
            S("domain add", self.c_domain_add, "Serve a VM on your own domain (point a CNAME at <vm>.<domain> first)",
              [("vm", True), ("domain", True)], {"--wildcard": "bool"}),
            S("domain ls", self.c_domain_ls, "List custom domains", [("vm", False)], {"-a": "bool", "--a": "bool"}),
            S("domain rm", self.c_domain_rm, "Remove a custom domain", [("vm", True), ("domain", True)]),
            S("ssh-key", self.c_key_list, "SSH keys: list add remove rename generate-api-key"),
            S("ssh-key list", self.c_key_list, "List your SSH keys"),
            S("ssh-key add", self.c_key_add, "Register an SSH public key", [("public_key", True)], {"--tag": "str", "--name": "str"},
              rest=True),
            S("ssh-key remove", self.c_key_remove, "Remove a key (by name or fingerprint)", [("key", True)]),
            S("ssh-key rename", self.c_key_rename, "Rename a key", [("key", True), ("new_name", True)]),
            S("ssh-key generate-api-key", self.c_key_api, "Mint an API token (for POST /exec, or one VM with --vm)",
              [], {"--label": "str", "--vm": "str", "--cmds": "str", "--exp": "str"},
              ["ssh-key generate-api-key --exp=30d", "ssh-key generate-api-key --vm=web --label=deploy",
               "ssh-key generate-api-key --cmds=ls,new,rm --exp=1d"]),
            S("token-exchange", self.c_token_exchange, "Exchange an nestlo0 token for a short nestlo1 token",
              [("token", True)], {"--vm": "str"}),
            S("exe0-to-exe1", self.c_token_exchange, "Alias of token-exchange", [("token", True)], {"--vm": "str"}),
            S("set-region", self.c_set_region, "Set the region for new VMs", [("region", True)]),
            S("integrations", self.c_int_list, "Integrations: list add edit remove attach detach rename"),
            S("integrations list", self.c_int_list, "List integrations"),
            S("integrations add", self.c_int_add, "Add an integration", [("type", True)],
              {"--name": "str", "--team": "bool", "--target": "str", "--header": "list", "--bearer": "str",
               "--repository": "list", "--read-only": "bool", "--peer": "bool", "--vm": "str", "--port": "str",
               "--attach": "list", "--comment": "str", "--act-as-user": "bool"},
              ["integrations add http-proxy --name stripe --target https://api.stripe.com --bearer sk_live_...",
               "integrations add github --name gh --repository acme/web --bearer ghp_... --attach vm:web",
               "integrations add peer --name db --vm db --port 5432 --attach tag:app"]),
            S("integrations edit", self.c_int_edit, "Change an integration", [("name", True)],
              {"--team": "bool", "--target": "str", "--header": "list", "--clear-header": "bool", "--bearer": "str",
               "--repository": "list", "--read-only": "bool", "--comment": "str", "--port": "str", "--act-as-user": "bool"}),
            S("integrations remove", self.c_int_remove, "Remove an integration", [("name", True)], {"--team": "bool"}),
            S("integrations attach", self.c_int_attach, "Attach to vm:<name>, tag:<tag> or auto:all", [("name", True), ("spec", True)],
              {"--team": "bool"}),
            S("integrations detach", self.c_int_detach, "Detach", [("name", True), ("spec", True)], {"--team": "bool"}),
            S("integrations rename", self.c_int_rename, "Rename", [("name", True), ("new_name", True)], {"--team": "bool"}),
            S("team", self.c_team, "Show your team"),
            S("team create", self.c_team_create, "Create a team (you become its billing owner)", [("name", True)], rest=True),
            S("team members", self.c_team_members, "List team members"),
            S("team add", self.c_team_add, "Add a member", [("email", True)], {"--role": "str"}),
            S("team remove", self.c_team_remove, "Remove a member", [("email", True)]),
            S("team role", self.c_team_role, "Change a member's role (user, admin, billing_owner)", [("email", True), ("role", True)]),
            S("team rename", self.c_team_rename, "Rename the team", [("name", True)], rest=True),
            S("team transfer", self.c_team_transfer, "Give a VM to another member", [("vm", True), ("email", True)]),
            S("team settings", self.c_team_settings, "Show team settings"),
            S("team settings vm-sharing", self.c_team_sharing, "Who may share team VMs: admins-only or all-members",
              [("value", True)]),
            S("team vm ls", self.c_team_vms, "List the team's VMs", [], {"-l": "bool", "--l": "bool"}),
            S("team auth", self.c_team_auth, "Show how team members log in"),
            S("team disable", self.c_team_disable, "Disband the team", [], {"--yes": "bool"}),
            S("invite", self.c_invite_show, "Invites: show create ls revoke"),
            S("invite show", self.c_invite_show, "Your invites"),
            S("invite create", self.c_invite_create, "Create an invite code", [],
              {"--email": "str", "--days": "str", "--team": "bool", "--role": "str", "--plan": "str"}),
            S("invite ls", self.c_invite_show, "List your invites"),
            S("invite revoke", self.c_invite_revoke, "Revoke an invite", [("code", True)]),
            S("billing", self.c_billing_plan, "Plan, usage and capacity"),
            S("billing plan", self.c_billing_plan, "Your plan and its limits"),
            S("billing usage", self.c_billing_usage, "Usage against your plan", [], {"--range": "str"}),
            S("billing capacity", self.c_billing_capacity, "Show or change your pool size", [],
              {"--cpu": "str", "--memory": "str"}),
            S("browser", self.c_browser, "A one-time link that logs this browser in"),
            S("shelley", self.c_agent_ui, "The in-VM agent web UI of a VM", [("vm", True)]),
            S("ssh", self.c_ssh_hint, "Open a shell in a VM (over SSH only)", [("vm", True), ("command...", False)], ssh_only=True),
            S("tunnel", self.c_ssh_hint, "Forward stdio to a VM port (ProxyCommand; over SSH only)",
              [("vm", True), ("port", False)], ssh_only=True),
            S("admin users", self.c_admin_users, "All users", admin=True),
            S("admin user add", self.c_admin_user_add, "Create a user", [("email", True)],
              {"--plan": "str", "--admin": "bool", "--key": "str"}, admin=True),
            S("admin user plan", self.c_admin_user_plan, "Change a user's plan", [("email", True), ("plan", True)], admin=True),
            S("admin user disable", self.c_admin_user_disable, "Disable a user (keeps their VMs)", [("email", True)], admin=True),
            S("admin user enable", self.c_admin_user_enable, "Enable a user", [("email", True)], admin=True),
            S("admin vms", self.c_admin_vms, "All VMs", admin=True),
        ]
        for s in cmds:
            self.specs[s.name] = s

    # ── help / whoami ──────────────────────────────────────────────────
    def c_help(self, ctx, a, f):
        words = a.get("command") or []
        if words:
            spec, rest = self.resolve(words)
            if spec is None or rest:
                raise CommandError("no command %r" % " ".join(words), 404)
            return spec.describe()
        return {"commands": [{"command": s.name, "help": s.help} for s in self.specs.values()
                             if (not s.admin or (ctx.user or {}).get("admin"))],
                "message": "Run `<command> --help` for flags and examples. Add --json for JSON output."}

    def c_doc(self, ctx, a, f):
        return {"docs": self.cfg.get("docs_url") or "/run/current-system/sw/share/doc/nestlo/cloud.md",
                "message": "Nestlo Cloud documentation: docs/cloud.md"}

    def c_whoami(self, ctx, a, f):
        u = ctx.user
        lim, _ = self.limits_of(u)
        return {"id": u["id"], "email": u["email"], "name": u["name"], "plan": lim["plan"], "admin": u["admin"],
                "team": (self.st.team(u.get("team")) or {}).get("name"), "region": u.get("region") or self.cfg.get("region"),
                "keys": len(self.st.keys_of(u["id"])), "via": ctx.via, "key": ctx.key}

    # ── VMs ────────────────────────────────────────────────────────────
    def c_ls(self, ctx, a, f):
        mine = self.st.vms_of(ctx.user["id"])
        vms = list(mine)
        if f.get("--shared"):
            have = {v["id"] for v in vms}
            vms.extend(v for v in self.st.vms() if v["id"] not in have and self.access(ctx.user, v))
        if a.get("pattern"):
            import fnmatch
            vms = [v for v in vms if fnmatch.fnmatch(v["name"], a["pattern"])]
        if f.get("--tag"):
            vms = [v for v in vms if f["--tag"] in v.get("tags", [])]
        long = f.get("-l") or f.get("--l")
        return {"vms": [self.view(v, ctx.user, long) for v in vms]}

    def _random_name(self):
        rnd = random.SystemRandom()
        for _ in range(50):
            name = "%s-%s" % (rnd.choice(ADJ), rnd.choice(NOUN))
            if not self.st.vm_by_name(name):
                return name
        return "vm-" + new_id(3)

    def _env(self, items):
        env = {}
        for item in items or []:
            k, eq, v = item.partition("=")
            if not eq or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", k):
                raise CommandError("--env needs NAME=value, got %r" % item, 400)
            env[k] = v
        return env

    def _tags(self, items):
        for t in items:
            if not TAG_RE.match(t):
                raise CommandError("bad tag %r (lower-case letters, digits, . _ -)" % t, 400)
        return sorted(set(items))

    def _image(self, name):
        name = name or self.cfg.get("default_image", "nestlo")
        images = self.cfg.get("images") or {}
        if name in images:
            return name
        if not self.cfg.get("allow_oci_images", True):
            raise CommandError("unknown image %r (images: %s)" % (name, ", ".join(sorted(images))), 400)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}", name) or ".." in name:
            raise CommandError("bad image reference %r" % name, 400)
        return name

    def _port(self, value):
        try:
            port = int(value)
        except (TypeError, ValueError):
            raise CommandError("port must be a number", 400)
        if not 1 <= port <= 65535:
            raise CommandError("port must be between 1 and 65535", 400)
        return port

    def c_new(self, ctx, a, f):
        owner = ctx.user
        name = f.get("--name") or self._random_name()
        if not valid_vm_name(name):
            raise CommandError("bad VM name %r: lower-case letters, digits and single hyphens, starting with a "
                               "letter, at most 42 characters" % name, 400)
        standalone = bool(f.get("--standalone"))
        cpu = P.parse_cpu(f["--cpu"]) if f.get("--cpu") else P.DEFAULT_VM["cpu"]
        mem = P.parse_size_mb(f["--memory"]) if f.get("--memory") else P.DEFAULT_VM["memory_mb"]
        disk = P.parse_disk_gb(f["--disk"]) if f.get("--disk") else int(self.cfg.get("default_disk_gb", P.DEFAULT_VM["disk_gb"]))
        lim, pool = self.limits_of(owner)
        if not f.get("--memory") and not standalone:
            mem = min(mem, lim["pool_memory_mb"])
        if not f.get("--cpu") and not standalone:
            cpu = min(cpu, lim["pool_cpu"])
        P.check_new_vm(lim, self.pool_vms(owner) if not standalone else self.st.vms_of(owner["id"]),
                       cpu, mem, disk, standalone)
        env = self._env(f.get("--env"))
        image = self._image(f.get("--image"))
        setup = f.get("--setup-script")
        if setup == "/dev/stdin":
            setup = ctx.stdin
        prompt = f.get("--prompt")
        if prompt == "/dev/stdin":
            prompt = ctx.stdin
        for label, text in (("--setup-script", setup), ("--prompt", prompt), ("--command", f.get("--command"))):
            if text is not None and len(text) > 60000:
                raise CommandError("%s is longer than 60000 characters" % label, 400)
        vid = new_id(4)
        vm = {
            "id": vid, "name": name, "owner": owner["id"], "team": owner.get("team"), "pool": None if standalone else pool,
            "image": image, "cpu": cpu, "memory_mb": mem, "disk_gb": disk, "tags": self._tags(f.get("--tag") or []),
            "comment": f.get("--comment") or "", "created": int(self.clock()), "desired": "running",
            "status": "creating", "port": self._port(f["--port"]) if f.get("--port") else int(self.cfg.get("default_port", 80)),
            "public": False, "shares": {}, "team_share": None, "links": {}, "domains": [],
            "standalone": standalone, "region": owner.get("region") or self.cfg.get("region"),
            "command": f.get("--command"), "integrations": [],
            "env": self._seal(json.dumps(env)) if env else None,
        }
        self.st.create_vm(vm)
        try:
            vm["ip"] = self.st.allocate_ip(vid, self.cfg["vm_network"])
            for iname in f.get("--integration") or []:
                self._attach(ctx, iname, "vm:" + name, team=False, save_vm=vm)
            self.st.save_vm(vm)
            self.vmd.create(self.spec_for(vm), setup=setup, prompt=prompt,
                            registry_auth=f.get("--registry-auth"))
        except Exception:
            self.st.release_ip(vm.get("ip"), vid)
            self.st.delete_vm(vm)
            raise
        vm["status"] = "running"
        self.st.save_vm(vm)
        self.emit("cloud.vm.create", ctx, vm=name, image=image, cpu=cpu, memory_mb=mem, disk_gb=disk,
                  standalone=standalone)
        out = self.view(vm, ctx.user, long=True)
        out["message"] = "Created %s: %s\nShell: %s" % (name, out["https_url"], out["ssh_command"])
        return out

    def spec_for(self, vm):
        """What the VM helper needs to run a VM (no secrets except env)."""
        owner = self.st.user(vm["owner"]) or {}
        lim, pool = self.limits_of(owner) if owner else (None, None)
        env = dict(self.llm_env(vm))
        env.update(json.loads(self._open(vm["env"])) if vm.get("env") else {})
        keys = self.root_keys(vm)
        return {
            "id": vm["id"], "name": vm["name"], "image": vm["image"], "cpu": vm["cpu"], "memory_mb": vm["memory_mb"],
            "disk_gb": vm["disk_gb"], "ip": vm.get("ip"), "env": env, "command": vm.get("command"),
            "pool": vm.get("pool"), "pool_cpu": lim["pool_cpu"] if lim and vm.get("pool") else None,
            "pool_memory_mb": lim["pool_memory_mb"] if lim and vm.get("pool") else None,
            "authorized_keys": keys, "hosts": self.integration_hosts(vm) + ["%s.%s" % (
                self.cfg.get("reflection_name", "reflection"), self.int_domain())],
            "owner_email": owner.get("email"),
        }

    def llm_env(self, vm):
        """Base URLs for agents in the VM when an llm integration is attached (no real keys)."""
        for integ in self.visible_integrations(self.st.user(vm["owner"]) or {"id": None}):
            if integ["type"] == "llm" and self.integration_for(vm, integ["name"]) is not None:
                base = "http://%s.%s" % (integ["name"], self.int_domain())
                return {"ANTHROPIC_BASE_URL": base + "/anthropic", "ANTHROPIC_API_KEY": "nestlo-cloud",
                        "OPENAI_BASE_URL": base + "/openai/v1", "OPENAI_API_KEY": "nestlo-cloud",
                        "NESTLO_LLM_URL": base}
        return {}

    def root_keys(self, vm):
        """Public keys of everyone with root access (written into the VM for its own sshd)."""
        out = []
        for u in self.st.users():
            if not u.get("disabled") and self.access(u, vm) == "root":
                out.extend(k["public"] for k in self.st.keys_of(u["id"]) if not k.get("api"))
        return sorted(set(out))

    def sync(self, vm):
        """Push access and integration changes to a running VM."""
        try:
            self.vmd.sync(self.spec_for(vm))
        except Exception:
            pass

    def c_rm(self, ctx, a, f):
        gone = []
        vms = [self.find_vm(ctx, n, "owner") for n in a["vm"]]
        for vm in vms:
            self.vmd.destroy(vm["id"])
            self.st.release_ip(vm.get("ip"), vm["id"])
            self.st.delete_vm(vm)
            gone.append(vm["name"])
            self.emit("cloud.vm.delete", ctx, vm=vm["name"])
        return {"deleted": gone, "message": "Deleted " + ", ".join(gone)}

    def c_restart(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        self.vmd.stop(vm["id"])
        self.vmd.start(self.spec_for(vm))
        vm["desired"], vm["status"] = "running", "running"
        self.st.save_vm(vm)
        self.emit("cloud.vm.restart", ctx, vm=vm["name"])
        return {"vm_name": vm["name"], "status": "running", "message": "Restarted %s" % vm["name"]}

    def c_stop(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        self.vmd.stop(vm["id"])
        vm["desired"], vm["status"] = "stopped", "stopped"
        self.st.save_vm(vm)
        self.emit("cloud.vm.stop", ctx, vm=vm["name"])
        return {"vm_name": vm["name"], "status": "stopped", "message": "Stopped %s" % vm["name"]}

    def c_start(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        self.vmd.start(self.spec_for(vm))
        vm["desired"], vm["status"] = "running", "running"
        self.st.save_vm(vm)
        return {"vm_name": vm["name"], "status": "running", "message": "Started %s" % vm["name"]}

    def c_rename(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        new = a["new_name"]
        if not valid_vm_name(new):
            raise CommandError("bad VM name %r" % new, 400)
        old = vm["name"]
        self.st.rename_vm(vm, new)
        self.sync(vm)
        self.emit("cloud.vm.rename", ctx, vm=old, new_name=new)
        return {"vm_name": new, "https_url": self.vm_url(vm), "message": "Renamed %s to %s" % (old, new)}

    def c_tag(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        tags = self._tags(a["tags"])
        if f.get("-d") or f.get("--d"):
            vm["tags"] = [t for t in vm.get("tags", []) if t not in tags]
        else:
            vm["tags"] = sorted(set(vm.get("tags", [])) | set(tags))
        self.st.save_vm(vm)
        self.sync(vm)
        return {"vm_name": vm["name"], "tags": vm["tags"]}

    def c_comment(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        text = (a.get("text") or "").strip()
        if len(text) > 200:
            raise CommandError("a comment is at most 200 characters", 400)
        vm["comment"] = text
        self.st.save_vm(vm)
        return {"vm_name": vm["name"], "comment": text}

    def _days(self, rng):
        rng = rng or "24h"
        if rng not in RANGES:
            raise CommandError("--range must be one of %s" % ", ".join(RANGES), 400)
        n = RANGES[rng]
        today = datetime.datetime.fromtimestamp(self.clock(), datetime.timezone.utc).date()
        if n is None:
            n = today.day
        return [(today - datetime.timedelta(days=i)).isoformat() for i in range(n)]

    def c_stat(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "web")
        live = self.vmd.stat(vm["id"]) or {}
        used = self.st.usage("vm-" + vm["id"], self._days(f.get("--range")))
        return {"vm_name": vm["name"], "status": live.get("status", vm.get("status")), "live": live,
                "usage": {"range": f.get("--range") or "24h", "vcpu_hours": round(used.get("vcpu_seconds", 0) / 3600, 3),
                          "cpu_hours_used": round(used.get("cpu_seconds", 0) / 3600, 3),
                          "net_rx_gb": round(used.get("rx_bytes", 0) / 1e9, 3), "net_tx_gb": round(used.get("tx_bytes", 0) / 1e9, 3)}}

    def c_cp(self, ctx, a, f):
        src = self.find_vm(ctx, a["vm"])
        owner = ctx.user
        name = a.get("new_name") or (src["name"] + "-copy")
        if not valid_vm_name(name):
            raise CommandError("bad VM name %r" % name, 400)
        cpu = P.parse_cpu(f["--cpu"]) if f.get("--cpu") else src["cpu"]
        mem = P.parse_size_mb(f["--memory"]) if f.get("--memory") else src["memory_mb"]
        disk = P.parse_disk_gb(f["--disk"]) if f.get("--disk") else src["disk_gb"]
        if disk < src["disk_gb"]:
            raise CommandError("a copy's disk cannot be smaller than the source's (%d GB)" % src["disk_gb"], 400)
        lim, pool = self.limits_of(owner)
        P.check_new_vm(lim, self.pool_vms(owner) if not src.get("standalone") else self.st.vms_of(owner["id"]),
                       cpu, mem, disk, src.get("standalone"))
        copy_tags = (f.get("--copy-tags") or "yes").lower() in ("yes", "true", "1")
        vid = new_id(4)
        vm = dict(src, id=vid, name=name, owner=owner["id"], team=owner.get("team"),
                  pool=None if src.get("standalone") else pool, cpu=cpu, memory_mb=mem, disk_gb=disk,
                  tags=list(src.get("tags", [])) if copy_tags else [], created=int(self.clock()),
                  public=False, shares={}, team_share=None, links={}, domains=[], status="creating", desired="running")
        self.st.create_vm(vm)
        try:
            vm["ip"] = self.st.allocate_ip(vid, self.cfg["vm_network"])
            self.st.save_vm(vm)
            self.vmd.copy(src["id"], self.spec_for(vm))
        except Exception:
            self.st.release_ip(vm.get("ip"), vid)
            self.st.delete_vm(vm)
            raise
        vm["status"] = "running"
        self.st.save_vm(vm)
        self.emit("cloud.vm.copy", ctx, vm=src["name"], new_name=name)
        out = self.view(vm, ctx.user, long=True)
        out["message"] = "Copied %s to %s: %s" % (src["name"], name, out["https_url"])
        return out

    def c_resize(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        if not any(f.get(k) for k in ("--cpu", "--memory", "--disk")):
            raise CommandError("resize needs at least one of --cpu, --memory, --disk", 400)
        owner = self.st.user(vm["owner"])
        lim, _ = self.limits_of(owner)
        cpu = P.parse_cpu(f["--cpu"]) if f.get("--cpu") else vm["cpu"]
        mem = P.parse_size_mb(f["--memory"]) if f.get("--memory") else vm["memory_mb"]
        disk = P.parse_disk_gb(f["--disk"]) if f.get("--disk") else vm["disk_gb"]
        if disk < vm["disk_gb"]:
            raise CommandError("a disk can only grow (now %d GB)" % vm["disk_gb"], 400)
        if vm.get("standalone"):
            if lim["standalone_cpu_max"] and cpu > lim["standalone_cpu_max"]:
                raise CommandError("a standalone VM can have at most %d vCPUs" % lim["standalone_cpu_max"])
        elif cpu > lim["pool_cpu"] or mem > lim["pool_memory_mb"]:
            raise CommandError("a VM cannot be larger than its pool (%d vCPUs, %s)" % (
                lim["pool_cpu"], P.fmt_mb(lim["pool_memory_mb"])))
        P.check_disk(lim, self.pool_vms(owner), disk, exclude=vm["id"])
        vm.update(cpu=cpu, memory_mb=mem, disk_gb=disk)
        self.st.save_vm(vm)
        self.vmd.resize(self.spec_for(vm))
        self.emit("cloud.vm.resize", ctx, vm=vm["name"], cpu=cpu, memory_mb=mem, disk_gb=disk)
        return {"vm_name": vm["name"], "cpu": cpu, "memory": P.fmt_mb(mem), "disk": "%d GB" % disk,
                "message": "Resized %s" % vm["name"]}

    # ── sharing ────────────────────────────────────────────────────────
    def c_share_help(self, ctx, a, f):
        return {"commands": [s.name for s in self.specs.values() if s.name.startswith("share ")]}

    def share_view(self, vm):
        return {"vm_name": vm["name"], "https_url": self.vm_url(vm), "port": vm.get("port"),
                "visibility": "public" if vm.get("public") else "private",
                "users": [{"email": e, "role": r} for e, r in sorted(vm.get("shares", {}).items())],
                "team": vm.get("team_share"),
                "links": [{"token": t, "url": self.link_url(vm, t), "role": d.get("role", "web")}
                          for t, d in sorted(vm.get("links", {}).items())],
                "domains": vm.get("domains", [])}

    def link_url(self, vm, tok):
        return "%s__nestlo/share/%s" % (self.vm_url(vm), tok)

    def c_share_show(self, ctx, a, f):
        return self.share_view(self.find_vm(ctx, a["vm"], "web"))

    def c_share_port(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        if a.get("port") is None:
            return {"vm_name": vm["name"], "port": vm.get("port")}
        vm["port"] = self._port(a["port"])
        self.st.save_vm(vm)
        self.emit("cloud.share.port", ctx, vm=vm["name"], port=vm["port"])
        return {"vm_name": vm["name"], "port": vm["port"],
                "message": "%s now forwards to port %d (%s)" % (self.vm_url(vm), vm["port"],
                                                               "public" if vm.get("public") else "private")}

    def c_share_public(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        vm["public"] = True
        self.st.save_vm(vm)
        self.emit("cloud.share.visibility", ctx, vm=vm["name"], public=True)
        return {"vm_name": vm["name"], "visibility": "public", "https_url": self.vm_url(vm),
                "message": "%s is public: anyone can open it" % self.vm_url(vm)}

    def c_share_private(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        vm["public"] = False
        self.st.save_vm(vm)
        self.emit("cloud.share.visibility", ctx, vm=vm["name"], public=False)
        return {"vm_name": vm["name"], "visibility": "private"}

    def _can_share(self, ctx, vm):
        lim, _ = self.limits_of(self.st.user(vm["owner"]))
        if not lim.get("sharing"):
            raise CommandError("sharing with users is not part of the %s plan (set-public still works)" % lim["plan"], 403)
        if vm.get("team"):
            team = self.st.team(vm["team"]) or {}
            if team.get("settings", {}).get("vm_sharing") == "admins-only" and not self._team_admin(ctx.user, vm) \
                    and not ctx.user.get("admin"):
                raise CommandError("only team admins may share team VMs (team settings vm-sharing)", 403)

    def _role(self, f):
        role = (f.get("--role") or "web").lower()
        if role not in SHARE_ROLES:
            raise CommandError("--role must be web or root", 400)
        return role

    def c_share_add(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        self._can_share(ctx, vm)
        role = self._role(f)
        target = a["target"].strip()
        if target == "team":
            if not vm.get("team"):
                raise CommandError("%s does not belong to a team" % vm["name"], 400)
            vm["team_share"] = role
            who = "your team"
        else:
            email = norm_email(target).lower()
            vm.setdefault("shares", {})[email] = role
            who = email
        self.st.save_vm(vm)
        if role == "root":
            self.sync(vm)
        self.emit("cloud.share.add", ctx, vm=vm["name"], target=who, role=role)
        return dict(self.share_view(vm), message="Shared %s with %s (%s access): %s%s" % (
            vm["name"], who, role, self.vm_url(vm), ("\nMessage: " + f["--message"]) if f.get("--message") else ""))

    def c_share_remove(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        target = a["target"].strip().lower()
        if target == "team":
            vm["team_share"] = None
        elif vm.get("shares", {}).pop(target, None) is None:
            raise CommandError("%s is not shared with %s" % (vm["name"], target), 404)
        self.st.save_vm(vm)
        self.sync(vm)
        self.emit("cloud.share.remove", ctx, vm=vm["name"], target=target)
        return self.share_view(vm)

    def c_share_add_link(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        self._can_share(ctx, vm)
        role = self._role(f)
        tok = self.st.add_link(vm, role)
        self.emit("cloud.share.link", ctx, vm=vm["name"], role=role)
        url = self.link_url(vm, tok)
        return {"vm_name": vm["name"], "token": tok, "url": url, "role": role,
                "message": "Anyone who logs in through this link gets %s access to %s:\n%s" % (role, vm["name"], url)}

    def c_share_remove_link(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        self.st.remove_link(vm, a["token"])
        return self.share_view(vm)

    def c_receive_email(self, ctx, a, f):
        raise CommandError("receiving email is not available on Nestlo Cloud; run a mail server in the VM and "
                           "add a custom domain instead", 501)

    # ── custom domains ─────────────────────────────────────────────────
    def c_domain_help(self, ctx, a, f):
        return {"commands": ["domain add", "domain ls", "domain rm"]}

    def c_domain_add(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        domain = a["domain"].strip().lower().rstrip(".")
        if f.get("--wildcard"):
            raise CommandError("wildcard certificates need DNS-01 validation; configure "
                               "nestlo.cloud.tls.dnsProvider and use a plain domain per name", 501)
        if not DOMAIN_RE.match(domain) or domain == self.domain or domain.endswith("." + self.domain):
            raise CommandError("bad domain %r" % domain, 400)
        lim, _ = self.limits_of(self.st.user(vm["owner"]))
        if not lim.get("custom_domains", True):
            raise CommandError("custom domains are not part of the %s plan" % lim["plan"], 403)
        if self.cfg.get("verify_dns", True):
            self.check_dns(domain, vm)
        self.st.claim_domain(domain, vm["id"])
        vm.setdefault("domains", []).append(domain)
        self.st.save_vm(vm)
        self.emit("cloud.domain.add", ctx, vm=vm["name"], domain=domain)
        return {"vm_name": vm["name"], "domain": domain, "url": "%s://%s/" % (self.scheme(), domain),
                "message": "%s now serves %s; the certificate is issued on the first request" % (domain, vm["name"])}

    def check_dns(self, domain, vm):
        """The domain must resolve to an address of this host (CNAME to <vm>.<domain> or A/ALIAS)."""
        want = set(self.cfg.get("public_addresses") or [])
        target = vm["name"] + "." + self.domain
        try:
            if not want:
                want = {i[4][0] for i in socket.getaddrinfo(target, 443, proto=socket.IPPROTO_TCP)}
            got = {i[4][0] for i in socket.getaddrinfo(domain, 443, proto=socket.IPPROTO_TCP)}
        except OSError:
            raise CommandError("%s does not resolve yet; point a CNAME at %s (or an A record at this host) first" % (
                domain, target), 422)
        if not got & want:
            raise CommandError("%s resolves to %s, not to this host (%s); point a CNAME at %s" % (
                domain, ", ".join(sorted(got)), ", ".join(sorted(want)), target), 422)

    def c_domain_ls(self, ctx, a, f):
        if f.get("-a") or f.get("--a"):
            vms = [v for v in self.st.vms() if self.access(ctx.user, v)]
        elif a.get("vm"):
            vms = [self.find_vm(ctx, a["vm"], "web")]
        else:
            raise CommandError("domain ls needs a <vm> or -a", 400)
        return {"domains": [{"vm_name": v["name"], "domain": d} for v in vms for d in v.get("domains", [])]}

    def c_domain_rm(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"], "owner")
        domain = a["domain"].strip().lower().rstrip(".")
        if domain not in vm.get("domains", []):
            raise CommandError("%s is not a domain of %s" % (domain, vm["name"]), 404)
        vm["domains"].remove(domain)
        self.st.release_domain(domain, vm["id"])
        self.st.save_vm(vm)
        self.emit("cloud.domain.remove", ctx, vm=vm["name"], domain=domain)
        return {"vm_name": vm["name"], "domains": vm["domains"]}

    # ── SSH keys and tokens ────────────────────────────────────────────
    def _key_view(self, k):
        return {"name": k["name"], "fingerprint": k["fp"], "type": k["public"].split()[0], "tag": k.get("tag"),
                "api": k.get("api", False), "created": k["created"]}

    def c_key_list(self, ctx, a, f):
        return {"keys": [self._key_view(k) for k in self.st.keys_of(ctx.user["id"])]}

    def c_key_add(self, ctx, a, f):
        try:
            kind, blob, comment = TK.parse_public_key(a["public_key"])
        except ValueError as exc:
            raise CommandError(str(exc), 400)
        if f.get("--tag") and not TAG_RE.match(f["--tag"]):
            raise CommandError("bad tag %r" % f["--tag"], 400)
        fp = TK.fingerprint(blob)
        name = f.get("--name") or comment or "key-" + fp[7:15]
        public = "%s %s" % (kind, a["public_key"].split()[1])
        doc = self.st.add_key(ctx.user["id"], fp, public, name[:64], tag=f.get("--tag"))
        self.emit("cloud.key.add", ctx, fingerprint=fp)
        self._resync_user(ctx.user)
        return dict(self._key_view(doc), message="Added %s (%s)" % (doc["name"], fp))

    def _find_key(self, ctx, ref):
        for k in self.st.keys_of(ctx.user["id"]):
            if ref in (k["fp"], k["name"]):
                return k
        raise CommandError("no key %r (see `ssh-key list`)" % ref, 404)

    def c_key_remove(self, ctx, a, f):
        k = self._find_key(ctx, a["key"])
        if ctx.via == "ssh" and k["fp"] == ctx.key:
            raise CommandError("you are connected with this key; remove it from another key or session", 409)
        self.st.remove_key(ctx.user["id"], k["fp"])
        self.emit("cloud.key.remove", ctx, fingerprint=k["fp"])
        self._resync_user(ctx.user)
        return {"removed": k["fp"], "message": "Removed %s; every token it signed is revoked" % k["name"]}

    def c_key_rename(self, ctx, a, f):
        k = self._find_key(ctx, a["key"])
        k["name"] = a["new_name"][:64]
        self.st.save_key(k)
        return self._key_view(k)

    def _resync_user(self, user):
        for vm in self.st.vms():
            if self.access(user, vm) == "root":
                self.sync(vm)

    def parse_exp(self, text):
        now = int(self.clock())
        m = re.fullmatch(r"(\d+)([mhdw])", text or "")
        if m:
            return now + int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400, "w": 604800}[m.group(2)]
        if re.fullmatch(r"\d{9,10}", text or ""):
            return int(text)
        raise CommandError("--exp must be a duration like 30d, 12h, 1w or a Unix time", 400)

    def c_key_api(self, ctx, a, f):
        from cryptography.hazmat.primitives.asymmetric import ed25519
        perms = {}
        if f.get("--exp"):
            perms["exp"] = self.parse_exp(f["--exp"])
        else:
            perms["exp"] = int(self.clock()) + int(self.cfg.get("default_token_days", 90)) * 86400
        if f.get("--cmds"):
            perms["cmds"] = [c.strip() for c in f["--cmds"].split(",") if c.strip()]
            unknown = [c for c in perms["cmds"] if c not in self.specs]
            if unknown:
                raise CommandError("unknown command(s) in --cmds: %s" % ", ".join(unknown), 400)
        namespace = "v0@" + self.domain
        if f.get("--vm"):
            vm = self.find_vm(ctx, f["--vm"], "web")
            namespace = "v0@%s.%s" % (vm["name"], self.domain)
            perms.pop("cmds", None)
        label = (f.get("--label") or "api")[:40]
        key = ed25519.Ed25519PrivateKey.generate()
        line = TK.public_line(key)
        _, blob, _ = TK.parse_public_key(line)
        fp = TK.fingerprint(blob)
        self.st.add_key(ctx.user["id"], fp, line, "api:" + label, api=True)
        token = TK.make_token(key, perms, namespace)
        del key
        self.emit("cloud.token.create", ctx, fingerprint=fp, scope=namespace, label=label)
        return {"token": token, "fingerprint": fp, "namespace": namespace, "expires": perms.get("exp"),
                "cmds": perms.get("cmds", TK.DEFAULT_CMDS if not f.get("--vm") else None),
                "message": "Token (shown once; revoke with `ssh-key remove api:%s`):\n%s" % (label, token)}

    def c_token_exchange(self, ctx, a, f):
        tok = a["token"]
        vm = None
        namespace = "v0@" + self.domain
        if f.get("--vm"):
            vmd = self.find_vm(ctx, f["--vm"], "web")
            vm = vmd["name"]
            namespace = "v0@%s.%s" % (vm, self.domain)
        try:
            perms, fp = TK.decode(tok, namespace, now=self.clock())
        except TK.TokenError as exc:
            raise CommandError(exc.message, 400)
        k = self.st.key(fp)
        if not k or k["uid"] != ctx.user["id"]:
            raise CommandError("that token was not signed by one of your keys", 403)
        ttl = max(60, perms["exp"] - int(self.clock())) if "exp" in perms else None
        handle = self.st.put_short_token(tok, vm=vm, ttl=ttl)
        return {"token": handle, "vm": vm, "message": handle}

    def c_set_region(self, ctx, a, f):
        regions = self.cfg.get("regions") or [self.cfg.get("region", "local")]
        if a["region"] not in regions:
            raise CommandError("unknown region %r (regions: %s)" % (a["region"], ", ".join(regions)), 400)
        ctx.user["region"] = a["region"]
        self.st.save_user(ctx.user)
        return {"region": a["region"]}

    # ── integrations ───────────────────────────────────────────────────
    def _seal(self, text):
        return self.box.encrypt(text.encode()).decode() if self.box else text

    def _open(self, text):
        return self.box.decrypt(text.encode()).decode() if self.box else text

    def _scope(self, ctx, team):
        if team:
            if not ctx.user.get("team"):
                raise CommandError("you are not in a team", 400)
            t = self.st.team(ctx.user["team"])
            if t["members"].get(ctx.user["id"]) not in ("admin", "billing_owner"):
                raise CommandError("only team admins manage team integrations", 403)
            return "team:" + t["id"]
        return ctx.user["id"]

    def _int_view(self, i):
        return {"name": i["name"], "type": i["type"], "scope": "team" if i["scope"].startswith("team:") else
                ("system" if i["scope"] == "system" else "user"), "target": i.get("target"),
                "url": "http://%s.%s/" % (i["name"], self.int_domain()),
                "headers": sorted(i.get("headers", {})), "has_bearer": bool(i.get("bearer")),
                "repositories": i.get("repositories", []), "read_only": i.get("read_only", False),
                "attach": i.get("attach", []), "comment": i.get("comment", ""),
                "peer": i.get("peer")}

    def int_domain(self):
        return self.cfg.get("integrations_domain") or "int." + self.domain

    def visible_integrations(self, user):
        scopes = {user["id"], "system"}
        if user.get("team"):
            scopes.add("team:" + user["team"])
        return [i for i in self.st.integrations() if i["scope"] in scopes]

    def c_int_list(self, ctx, a, f):
        return {"integrations": [self._int_view(i) for i in self.visible_integrations(ctx.user)],
                "types": list(INTEGRATION_TYPES)}

    def _headers(self, items):
        out = {}
        for h in items or []:
            m = HEADER_RE.match(h)
            if not m or m.group(1).lower() in ("host", "content-length", "connection", "transfer-encoding"):
                raise CommandError("bad --header %r (use 'Name: value')" % h, 400)
            out[m.group(1)] = self._seal(m.group(2))
        return out

    def _target(self, value):
        if not value or not re.fullmatch(r"https?://[A-Za-z0-9.-]+(:\d{1,5})?(/[^\s]*)?", value):
            raise CommandError("--target must be an http(s) URL", 400)
        return value.rstrip("/")

    def c_int_add(self, ctx, a, f):
        itype = a["type"]
        if itype not in INTEGRATION_TYPES:
            raise CommandError("integration type must be one of: %s" % ", ".join(INTEGRATION_TYPES), 400)
        name = f.get("--name") or ""
        if not NAME_RE.match(name) or name == self.cfg.get("reflection_name", "reflection"):
            raise CommandError("--name is required: lower-case letters, digits and hyphens", 400)
        scope = self._scope(ctx, f.get("--team"))
        integ = {"name": name, "type": itype, "scope": scope, "created_by": ctx.user["email"],
                 "created": int(self.clock()), "attach": [], "comment": f.get("--comment") or "",
                 "headers": self._headers(f.get("--header")), "act_as_user": bool(f.get("--act-as-user"))}
        if f.get("--bearer"):
            integ["bearer"] = self._seal(f["--bearer"])
        if itype == "http-proxy":
            integ["target"] = self._target(f.get("--target"))
        elif itype == "github":
            repos = f.get("--repository") or []
            for r in repos:
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}|[A-Za-z0-9][A-Za-z0-9._-]{0,99}/\*", r):
                    raise CommandError("bad --repository %r (owner/name or owner/*)" % r, 400)
            if not repos:
                raise CommandError("a github integration needs at least one --repository owner/name", 400)
            if not f.get("--bearer"):
                raise CommandError("a github integration needs --bearer <token> (a fine-grained PAT or app token)", 400)
            integ.update(repositories=repos, read_only=bool(f.get("--read-only")),
                         target=self.cfg.get("github_url", "https://github.com"))
        elif itype == "llm":
            if not self.cfg.get("gateway_url"):
                raise CommandError("the model gateway is not enabled on this host (nestlo.networking)", 501)
            integ["target"] = "gateway"
        elif itype == "peer":
            peer = self.find_vm(ctx, f.get("--vm") or "", "root") if f.get("--vm") else None
            if peer is None:
                raise CommandError("a peer integration needs --vm <name> (and --port)", 400)
            integ["peer"] = {"vm": peer["id"], "port": self._port(f.get("--port") or "80")}
        self.st.put_integration(integ, new=True)
        for spec in f.get("--attach") or []:
            self._attach(ctx, name, spec, team=f.get("--team"))
        self.emit("cloud.integration.add", ctx, name=name, type=itype, scope="team" if f.get("--team") else "user")
        integ = self.st.integration(scope, name)
        return dict(self._int_view(integ), message="Integration %s: VMs it is attached to reach it at %s" % (
            name, self._int_view(integ)["url"]))

    def _get_int(self, ctx, name, team):
        integ = self.st.integration(self._scope(ctx, team), name)
        if integ is None:
            raise CommandError("no integration %r%s" % (name, " in your team" if team else ""), 404)
        return integ

    def c_int_edit(self, ctx, a, f):
        integ = self._get_int(ctx, a["name"], f.get("--team"))
        if f.get("--target"):
            if integ["type"] != "http-proxy":
                raise CommandError("--target applies to http-proxy integrations", 400)
            integ["target"] = self._target(f["--target"])
        if f.get("--clear-header"):
            integ["headers"] = {}
        if f.get("--header"):
            integ.setdefault("headers", {}).update(self._headers(f["--header"]))
        if f.get("--bearer"):
            integ["bearer"] = self._seal(f["--bearer"])
        if f.get("--repository"):
            integ["repositories"] = f["--repository"]
        if "--read-only" in f:
            integ["read_only"] = bool(f["--read-only"])
        if f.get("--comment") is not None:
            integ["comment"] = f["--comment"]
        if f.get("--port") and integ["type"] == "peer":
            integ["peer"]["port"] = self._port(f["--port"])
        if "--act-as-user" in f:
            integ["act_as_user"] = bool(f["--act-as-user"])
        self.st.put_integration(integ)
        self.emit("cloud.integration.edit", ctx, name=integ["name"])
        return self._int_view(integ)

    def c_int_remove(self, ctx, a, f):
        integ = self._get_int(ctx, a["name"], f.get("--team"))
        self.st.delete_integration(integ)
        self.emit("cloud.integration.remove", ctx, name=integ["name"])
        self._resync_integration(integ)
        return {"removed": integ["name"]}

    def _check_spec(self, ctx, spec):
        kind, _, value = spec.partition(":")
        if kind == "vm":
            self.find_vm(ctx, value, "root")
        elif kind == "tag":
            if not TAG_RE.match(value):
                raise CommandError("bad tag in %r" % spec, 400)
        elif spec != "auto:all":
            raise CommandError("attach to vm:<name>, tag:<tag> or auto:all", 400)

    def _attach(self, ctx, name, spec, team=False, save_vm=None):
        if save_vm is not None:
            if not any(i["name"] == name for i in self.visible_integrations(ctx.user)):
                raise CommandError("no integration %r" % name, 404)
            if name not in save_vm.setdefault("integrations", []):
                save_vm["integrations"].append(name)
            return None
        integ = self._get_int(ctx, name, team)
        self._check_spec(ctx, spec)
        if spec not in integ["attach"]:
            integ["attach"].append(spec)
            self.st.put_integration(integ)
        self._resync_integration(integ)
        return integ

    def c_int_attach(self, ctx, a, f):
        integ = self._attach(ctx, a["name"], a["spec"], team=f.get("--team"))
        self.emit("cloud.integration.attach", ctx, name=integ["name"], spec=a["spec"])
        return self._int_view(integ)

    def c_int_detach(self, ctx, a, f):
        integ = self._get_int(ctx, a["name"], f.get("--team"))
        if a["spec"] not in integ["attach"]:
            raise CommandError("%s is not attached to %s" % (integ["name"], a["spec"]), 404)
        integ["attach"].remove(a["spec"])
        self.st.put_integration(integ)
        self._resync_integration(integ)
        return self._int_view(integ)

    def c_int_rename(self, ctx, a, f):
        integ = self._get_int(ctx, a["name"], f.get("--team"))
        new = a["new_name"]
        if not NAME_RE.match(new) or new == self.cfg.get("reflection_name", "reflection"):
            raise CommandError("bad name %r" % new, 400)
        old = dict(integ)
        integ["name"] = new
        self.st.put_integration(integ, new=True)
        self.st.delete_integration(old)
        self._resync_integration(integ)
        return self._int_view(integ)

    def _resync_integration(self, integ):
        for vm in self.st.vms():
            if vm.get("desired") == "running":
                self.sync(vm)

    def attached_integrations(self, vm):
        owner = self.st.user(vm["owner"])
        if owner is None:
            return []
        out = []
        for integ in self.visible_integrations(owner):
            team = integ["scope"].startswith("team:")
            if self.integration_for(vm, integ["name"], team=team) is integ or \
                    (self.integration_for(vm, integ["name"], team=team) or {}).get("scope") == integ["scope"]:
                out.append(integ)
        return sorted(out, key=lambda i: (i["name"], i["scope"]))

    def integration_for(self, vm, name, team=None):
        """The integration `name` as seen from `vm`, if attached to it.

        team=True: only the team's integration (<name>.team.<domain>);
        team=None/False: user scope shadows team scope shadows system scope."""
        owner = self.st.user(vm["owner"])
        if owner is None:
            return None
        found = None
        for integ in self.visible_integrations(owner):
            if integ["name"] != name:
                continue
            if team and not integ["scope"].startswith("team:"):
                continue
            # user scope shadows team scope shadows system scope
            rank = 0 if integ["scope"] == owner["id"] else (1 if integ["scope"].startswith("team:") else 2)
            if found is None or rank < found[0]:
                found = (rank, integ)
        if found is None:
            return None
        integ = found[1]
        if self.attached(integ, vm):
            return integ
        return None

    def attached(self, integ, vm):
        for spec in integ.get("attach", []):
            kind, _, value = spec.partition(":")
            if spec == "auto:all" or (kind == "vm" and value == vm["name"]) or (kind == "tag" and value in vm.get("tags", [])):
                return True
        return integ["name"] in vm.get("integrations", [])

    def integration_hosts(self, vm):
        """Integration host names a VM resolves to the integration proxy."""
        owner = self.st.user(vm["owner"])
        if owner is None:
            return []
        names = set()
        for i in self.visible_integrations(owner):
            if self.attached(i, vm):
                names.add("%s.%s.%s" % (i["name"], "team" if i["scope"].startswith("team:") else "int", self.domain)
                          if self.int_domain() == "int." + self.domain or i["scope"].startswith("team:")
                          else "%s.%s" % (i["name"], self.int_domain()))
        return sorted(names)

    # ── teams ──────────────────────────────────────────────────────────
    def _my_team(self, ctx, admin=False):
        team = self.st.team(ctx.user.get("team"))
        if team is None:
            raise CommandError("you are not in a team (`team create <name>`)", 404)
        if admin and team["members"].get(ctx.user["id"]) not in ("admin", "billing_owner"):
            raise CommandError("only team admins can do that", 403)
        return team

    def _team_view(self, team):
        members = []
        for uid, role in sorted(team["members"].items()):
            u = self.st.user(uid) or {}
            members.append({"email": u.get("email"), "role": role})
        lim, _ = self.limits_of(self.st.user(next(iter(team["members"]))) or {"plan": team["plan"]})
        return {"id": team["id"], "name": team["name"], "plan": team["plan"], "members": members,
                "settings": team["settings"], "pool_cpu": lim["pool_cpu"], "pool_memory": P.fmt_mb(lim["pool_memory_mb"])}

    def c_team(self, ctx, a, f):
        return self._team_view(self._my_team(ctx))

    def c_team_create(self, ctx, a, f):
        if ctx.user.get("team"):
            raise CommandError("you are already in a team", 409)
        if not self.cfg.get("users_create_teams", True) and not ctx.user.get("admin"):
            raise CommandError("only administrators create teams here", 403)
        team = self.st.create_team(a["name"][:64], ctx.user["id"], plan=self.cfg.get("team_plan", "work"))
        ctx.user["team"] = team["id"]
        self.emit("cloud.team.create", ctx, team=team["name"])
        return self._team_view(team)

    def c_team_members(self, ctx, a, f):
        return {"members": self._team_view(self._my_team(ctx))["members"]}

    def c_team_add(self, ctx, a, f):
        team = self._my_team(ctx, admin=True)
        role = f.get("--role") or "user"
        if role not in ROLES:
            raise CommandError("role must be one of %s" % ", ".join(ROLES), 400)
        user = self.st.user_by_email(a["email"])
        if user is None:
            inv = self.st.create_invite(ctx.user["id"], email=norm_email(a["email"]), team=team["id"], role=role)
            return {"invited": a["email"], "code": inv["code"],
                    "message": "%s has no account yet; they join with `ssh %s@%s redeem %s`" % (
                        a["email"], self.cfg.get("lobby_user", "lobby"), self.cfg.get("ssh_host", self.domain), inv["code"])}
        if user.get("team") and user["team"] != team["id"]:
            raise CommandError("%s is in another team" % user["email"], 409)
        team["members"][user["id"]] = role
        user["team"] = team["id"]
        self.st.save_user(user)
        self.st.save_team(team)
        self.emit("cloud.team.member", ctx, team=team["name"], member=user["email"], role=role)
        return self._team_view(team)

    def _member(self, team, email):
        user = self.st.user_by_email(email)
        if user is None or user["id"] not in team["members"]:
            raise CommandError("%s is not a member" % email, 404)
        return user

    def c_team_remove(self, ctx, a, f):
        team = self._my_team(ctx, admin=True)
        user = self._member(team, a["email"])
        if team["members"][user["id"]] == "billing_owner" and \
                sum(1 for r in team["members"].values() if r == "billing_owner") == 1:
            raise CommandError("the last billing owner cannot be removed; transfer the role first", 409)
        del team["members"][user["id"]]
        user["team"] = None
        self.st.save_user(user)
        self.st.save_team(team)
        self.emit("cloud.team.member", ctx, team=team["name"], member=user["email"], role=None)
        return self._team_view(team)

    def c_team_role(self, ctx, a, f):
        team = self._my_team(ctx, admin=True)
        if a["role"] not in ROLES:
            raise CommandError("role must be one of %s" % ", ".join(ROLES), 400)
        user = self._member(team, a["email"])
        if a["role"] == "billing_owner" and team["members"].get(ctx.user["id"]) != "billing_owner":
            raise CommandError("only a billing owner can make another billing owner", 403)
        team["members"][user["id"]] = a["role"]
        self.st.save_team(team)
        self.emit("cloud.team.member", ctx, team=team["name"], member=user["email"], role=a["role"])
        return self._team_view(team)

    def c_team_rename(self, ctx, a, f):
        team = self._my_team(ctx, admin=True)
        team["name"] = a["name"][:64]
        self.st.save_team(team)
        return self._team_view(team)

    def c_team_transfer(self, ctx, a, f):
        team = self._my_team(ctx)
        vm = self.find_vm(ctx, a["vm"], "owner")
        user = self._member(team, a["email"])
        self.st.transfer_vm(vm, user["id"])
        self.sync(vm)
        self.emit("cloud.vm.transfer", ctx, vm=vm["name"], to=user["email"])
        return {"vm_name": vm["name"], "owner": user["email"]}

    def c_team_settings(self, ctx, a, f):
        return {"settings": self._my_team(ctx)["settings"]}

    def c_team_sharing(self, ctx, a, f):
        team = self._my_team(ctx, admin=True)
        if a["value"] not in ("admins-only", "all-members"):
            raise CommandError("vm-sharing must be admins-only or all-members", 400)
        team["settings"]["vm_sharing"] = a["value"]
        self.st.save_team(team)
        return {"settings": team["settings"]}

    def c_team_vms(self, ctx, a, f):
        team = self._my_team(ctx)
        out = []
        for uid in team["members"]:
            for vm in self.st.vms_of(uid):
                if vm.get("team") == team["id"]:
                    v = self.view(vm, ctx.user, f.get("-l") or f.get("--l"))
                    v["owner"] = (self.st.user(uid) or {}).get("email")
                    out.append(v)
        return {"vms": out}

    def c_team_auth(self, ctx, a, f):
        team = self._my_team(ctx)
        oidc = self.cfg.get("oidc") or {}
        return {"team": team["name"], "login": "oidc" if oidc.get("issuer") else "ssh-key magic links",
                "issuer": oidc.get("issuer"),
                "message": "Login methods are set by the administrator (nestlo.cloud.oidc)"}

    def c_team_disable(self, ctx, a, f):
        team = self._my_team(ctx)
        if team["members"].get(ctx.user["id"]) != "billing_owner":
            raise CommandError("only a billing owner can disband the team", 403)
        if not f.get("--yes"):
            raise CommandError("this disbands %s; VMs stay with their owners. Re-run with --yes" % team["name"], 400)
        for uid in team["members"]:
            for vm in self.st.vms_of(uid):
                if vm.get("team") == team["id"]:
                    vm["team"], vm["team_share"] = None, None
                    vm["pool"] = None if vm.get("standalone") else "user-" + uid
                    self.st.save_vm(vm)
        self.st.delete_team(team["id"])
        ctx.user["team"] = None
        self.emit("cloud.team.disable", ctx, team=team["name"])
        return {"disbanded": team["name"]}

    # ── invites ────────────────────────────────────────────────────────
    def _redeem_cmd(self, code):
        return "ssh %s@%s redeem %s" % (self.cfg.get("lobby_user", "lobby"), self.cfg.get("ssh_host", self.domain), code)

    def c_invite_show(self, ctx, a, f):
        return {"invites": [dict(i, redeem=self._redeem_cmd(i["code"])) for i in self.st.invites_of(ctx.user["id"])]}

    def c_invite_create(self, ctx, a, f):
        if not self.cfg.get("users_invite", True) and not ctx.user.get("admin"):
            raise CommandError("only administrators invite users here", 403)
        days = int(f.get("--days") or 7)
        if not 1 <= days <= 90:
            raise CommandError("--days must be 1 to 90", 400)
        team = None
        role = f.get("--role") or "user"
        if f.get("--team"):
            team = self._my_team(ctx, admin=True)["id"]
        if role not in ROLES:
            raise CommandError("role must be one of %s" % ", ".join(ROLES), 400)
        plan = f.get("--plan")
        if plan and not ctx.user.get("admin"):
            raise CommandError("only administrators set a plan on an invite", 403)
        if plan and plan not in P.PRESETS:
            raise CommandError("unknown plan %r" % plan, 400)
        email = norm_email(f["--email"]) if f.get("--email") else None
        inv = self.st.create_invite(ctx.user["id"], email=email, team=team, role=role, days=days, plan=plan)
        self.emit("cloud.invite.create", ctx, team=bool(team), email=email)
        return dict(inv, redeem=self._redeem_cmd(inv["code"]),
                    message="Send this to the new user (with their SSH key loaded):\n  " + self._redeem_cmd(inv["code"]))

    def c_invite_revoke(self, ctx, a, f):
        inv = self.st.invite(a["code"])
        if not inv or (inv["by"] != ctx.user["id"] and not ctx.user.get("admin")):
            raise CommandError("no such invite", 404)
        self.st.r.delete(self.st._k("invite", a["code"]))
        return {"revoked": a["code"]}

    def redeem(self, code, fp, public):
        """Register a new user (or add a key) from an invite; returns the user."""
        inv = self.st.invite(code)
        if not inv or inv.get("used_by"):
            raise CommandError("this invite is not valid (expired, revoked or used)", 403)
        email = inv.get("email")
        if not email:
            raise CommandError("this invite has no email address; ask for one made with --email", 400)
        user = self.st.user_by_email(email)
        if user is None:
            plan = inv.get("plan") or self.cfg.get("default_plan", "work")
            user = self.st.create_user(email, plan=plan)
        self.st.add_key(user["id"], fp, public, "key-" + fp[7:15])
        if inv.get("team"):
            team = self.st.team(inv["team"])
            if team and not user.get("team"):
                team["members"][user["id"]] = inv.get("role") or "user"
                user["team"] = team["id"]
                self.st.save_team(team)
                self.st.save_user(user)
        inv["used_by"] = user["id"]
        self.st.save_invite(inv)
        self.emit("cloud.invite.redeem", Ctx(user), code=code[:6])
        return user

    # ── billing ────────────────────────────────────────────────────────
    def c_billing_plan(self, ctx, a, f):
        lim, pool = self.limits_of(ctx.user)
        return {"plan": lim["plan"], "pool": pool, "limits": {
            "pool_vms": lim["pool_vms"] or "unlimited", "pool_cpu": lim["pool_cpu"],
            "pool_memory": P.fmt_mb(lim["pool_memory_mb"]), "pool_cpu_max": lim["pool_cpu_max"] or "unlimited",
            "pool_memory_max": P.fmt_mb(lim["pool_memory_mb_max"]) if lim["pool_memory_mb_max"] else "unlimited",
            "disk": "%d GB" % lim["disk_gb"] if lim["disk_gb"] else "unlimited",
            "bandwidth": "%d GB" % lim["bandwidth_gb"] if lim["bandwidth_gb"] else "unlimited",
            "standalone_vms": lim["standalone_vms"] or "unlimited", "sharing": lim["sharing"]}}

    def c_billing_usage(self, ctx, a, f):
        lim, pool = self.limits_of(ctx.user)
        days = self._days(f.get("--range") or "cycle")
        used = self.st.usage(pool, days)
        vms = self.pool_vms(ctx.user) if ctx.user.get("team") else self.st.vms_of(ctx.user["id"])
        disk = sum(v["disk_gb"] for v in vms)
        running = [v for v in vms if v.get("desired") == "running"]
        return {"plan": lim["plan"], "range": f.get("--range") or "cycle", "pool": pool,
                "vms": len(vms), "running": len(running),
                "pool_cpu_allocated": sum(v["cpu"] for v in running if not v.get("standalone")),
                "pool_cpu": lim["pool_cpu"], "disk_gb": disk, "disk_gb_limit": lim["disk_gb"] or None,
                "vcpu_hours": round(used.get("vcpu_seconds", 0) / 3600, 2),
                "standalone_vcpu_hours": round(used.get("standalone_vcpu_seconds", 0) / 3600, 2),
                "network_gb": round((used.get("rx_bytes", 0) + used.get("tx_bytes", 0)) / 1e9, 3),
                "network_gb_limit": lim["bandwidth_gb"] or None}

    def c_billing_capacity(self, ctx, a, f):
        lim, pool = self.limits_of(ctx.user)
        if not f.get("--cpu") and not f.get("--memory"):
            return {"pool": pool, "pool_cpu": lim["pool_cpu"], "pool_memory": P.fmt_mb(lim["pool_memory_mb"])}
        owner = ctx.user
        if owner.get("team"):
            team = self.st.team(owner["team"])
            if team["members"].get(owner["id"]) != "billing_owner":
                raise CommandError("only a billing owner changes the team's pool", 403)
            owner = team
        cpu = P.parse_cpu(f["--cpu"]) if f.get("--cpu") else lim["pool_cpu"]
        mem = P.parse_size_mb(f["--memory"]) if f.get("--memory") else max(lim["pool_memory_mb"], cpu * 2 * P.GB)
        P.check_pool_size(lim, cpu, mem)
        owner["pool_cpu"], owner["pool_memory_mb"] = cpu, mem
        if owner is ctx.user:
            self.st.save_user(owner)
        else:
            self.st.save_team(owner)
        for vm in self.pool_vms(ctx.user):
            if vm.get("desired") == "running":
                self.sync(vm)
        self.emit("cloud.billing.capacity", ctx, pool=pool, cpu=cpu, memory_mb=mem)
        return {"pool": pool, "pool_cpu": cpu, "pool_memory": P.fmt_mb(mem)}

    # ── web and agent UI ───────────────────────────────────────────────
    def c_browser(self, ctx, a, f):
        code = self.st.put_once("magic", {"uid": ctx.user["id"]}, ttl=600)
        url = "%s://%s/__nestlo/magic/%s" % (self.scheme(), self.domain, code)
        return {"url": url, "expires_in": 600, "message": "Open within 10 minutes (works once):\n" + url}

    def c_agent_ui(self, ctx, a, f):
        vm = self.find_vm(ctx, a["vm"])
        port = int(self.cfg.get("agent_ui_port", 9999))
        return {"vm_name": vm["name"], "url": self.vm_url(vm, port),
                "message": "The agent UI of %s (if its image runs one on port %d): %s" % (vm["name"], port, self.vm_url(vm, port))}

    def c_ssh_hint(self, ctx, a, f):
        raise CommandError("needs a terminal", 400)

    # ── administration ─────────────────────────────────────────────────
    def c_admin_users(self, ctx, a, f):
        return {"users": [{"email": u["email"], "plan": u["plan"], "admin": u["admin"], "disabled": u.get("disabled"),
                           "vms": len(self.st.vms_of(u["id"])), "keys": len(self.st.keys_of(u["id"])),
                           "team": (self.st.team(u.get("team")) or {}).get("name")} for u in self.st.users()]}

    def c_admin_user_add(self, ctx, a, f):
        plan = f.get("--plan") or self.cfg.get("default_plan", "work")
        if plan not in P.PRESETS:
            raise CommandError("unknown plan %r" % plan, 400)
        user = self.st.create_user(a["email"], plan=plan, admin=bool(f.get("--admin")))
        if f.get("--key"):
            try:
                kind, blob, comment = TK.parse_public_key(f["--key"])
            except ValueError as exc:
                raise CommandError(str(exc), 400)
            self.st.add_key(user["id"], TK.fingerprint(blob), "%s %s" % (kind, f["--key"].split()[1]),
                            comment or "key-1")
        self.emit("cloud.user.create", ctx, email=user["email"], plan=plan)
        return {"email": user["email"], "id": user["id"], "plan": plan}

    def _user_or_404(self, email):
        user = self.st.user_by_email(email)
        if user is None:
            raise CommandError("no user %s" % email, 404)
        return user

    def c_admin_user_plan(self, ctx, a, f):
        if a["plan"] not in P.PRESETS:
            raise CommandError("unknown plan %r" % a["plan"], 400)
        user = self._user_or_404(a["email"])
        user["plan"] = a["plan"]
        self.st.save_user(user)
        return {"email": user["email"], "plan": user["plan"]}

    def c_admin_user_disable(self, ctx, a, f):
        user = self._user_or_404(a["email"])
        user["disabled"] = True
        self.st.save_user(user)
        self.emit("cloud.user.disable", ctx, email=user["email"])
        return {"email": user["email"], "disabled": True}

    def c_admin_user_enable(self, ctx, a, f):
        user = self._user_or_404(a["email"])
        user["disabled"] = False
        self.st.save_user(user)
        return {"email": user["email"], "disabled": False}

    def c_admin_vms(self, ctx, a, f):
        return {"vms": [dict(self.view(v, None, True)) for v in self.st.vms()]}


# ── text rendering ─────────────────────────────────────────────────────

def _table(rows, cols):
    if not rows:
        return "(none)"
    data = [[str(r.get(c, "") if r.get(c) is not None else "") for c in cols] for r in rows]
    widths = [max(len(c), *(len(d[i]) for d in data)) for i, c in enumerate(cols)]
    lines = ["  ".join(c.upper().ljust(w) for c, w in zip(cols, widths)).rstrip()]
    lines += ["  ".join(v.ljust(w) for v, w in zip(d, widths)).rstrip() for d in data]
    return "\n".join(lines)


def render(name, obj):
    """Human text for a command result."""
    if "message" in obj and name not in ("help",):
        return obj["message"]
    if name == "help" and "commands" in obj:
        width = max(len(c["command"]) for c in obj["commands"])
        lines = ["%s  %s" % (c["command"].ljust(width), c["help"]) for c in obj["commands"]]
        return "\n".join(lines + ["", obj.get("message", "")]).rstrip()
    if "vms" in obj:
        rows = obj["vms"]
        cols = ["vm_name", "status", "https_url"] + (["cpu", "memory", "disk", "tags"] if rows and "cpu" in rows[0] else [])
        if rows and "owner" in rows[0]:
            cols.append("owner")
        return _table([dict(r, tags=",".join(r.get("tags", []))) for r in rows], cols)
    if "keys" in obj and isinstance(obj["keys"], list):
        return _table(obj["keys"], ["name", "fingerprint", "type", "tag"])
    if "integrations" in obj:
        return _table([dict(i, attach=",".join(i["attach"])) for i in obj["integrations"]], ["name", "type", "scope", "url", "attach"])
    if "domains" in obj and isinstance(obj["domains"], list) and obj["domains"] and isinstance(obj["domains"][0], dict):
        return _table(obj["domains"], ["vm_name", "domain"])
    if "users" in obj and isinstance(obj["users"], list) and obj["users"] and "plan" in obj["users"][0]:
        return _table(obj["users"], ["email", "plan", "admin", "disabled", "vms", "keys", "team"])
    if "invites" in obj:
        return _table(obj["invites"], ["code", "email", "team", "role", "redeem"])
    if "members" in obj and isinstance(obj["members"], list):
        head = "%s (%s)\n" % (obj.get("name"), obj.get("plan")) if obj.get("name") else ""
        return head + _table(obj["members"], ["email", "role"])
    return "\n".join("%s: %s" % (k, json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in obj.items())
