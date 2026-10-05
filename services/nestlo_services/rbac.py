"""Role-based access control for the orchestrator socket.

The caller is identified by SO_PEERCRED (uid, gid and pid, set by the
kernel). Roles come from the [rbac] table of services.toml:

    [rbac]
    enable = true
    separate_approver = false
    [rbac.roles.admin]  groups = ["nestlo"]  users = []
    ...

viewer     list and show tasks, groups and the policy
submitter  viewer + submit tasks and workflows, cancel one's own
approver   viewer + approve and reject
admin      everything, including cancelling other users' tasks

uid 0 is always admin. Without an [rbac] table (or enable = false) nothing
is checked, as before: the socket's group permission is the only gate.
"""

import grp
import os
import pwd

ROLES = ("viewer", "submitter", "approver", "admin")

# action -> roles that may do it
ALLOWED = {
    "read": set(ROLES),
    "submit": {"submitter", "admin"},
    "cancel": {"submitter", "admin"},      # own tasks; others' need cancel_any
    "cancel_any": {"admin"},
    "decide": {"approver", "admin"},
}


class Denied(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


def _proc_groups(pid):
    """Supplementary gids of a process (covers systemd SupplementaryGroups)."""
    try:
        with open("/proc/%d/status" % int(pid)) as f:
            for line in f:
                if line.startswith("Groups:"):
                    return {int(g) for g in line.split()[1:]}
    except (OSError, ValueError, TypeError):
        pass
    return set()


def system_groups(peer):
    """(user name, set of group names) of a socket peer."""
    uid = peer.get("uid")
    try:
        name = pwd.getpwuid(uid).pw_name
    except (KeyError, TypeError):
        name = str(uid)
    gids = {peer.get("gid")} | _proc_groups(peer.get("pid"))
    try:
        gids |= set(os.getgrouplist(name, peer.get("gid")))
    except (OSError, KeyError, TypeError):
        pass
    names = set()
    for gid in gids:
        try:
            names.add(grp.getgrgid(gid).gr_name)
        except (KeyError, TypeError):
            continue
    return name, names


class Rbac:
    def __init__(self, cfg, group_lookup=system_groups):
        section = (cfg or {}).get("rbac") or {}
        self.enabled = bool(section.get("enable", False)) if section else False
        self.separate_approver = bool(section.get("separate_approver", False))
        self.roles = {r: {"groups": list(((section.get("roles") or {}).get(r) or {}).get("groups") or []),
                          "users": list(((section.get("roles") or {}).get(r) or {}).get("users") or [])}
                      for r in ROLES}
        self.group_lookup = group_lookup

    def identity(self, peer):
        """{name, uid, groups, roles} of the caller."""
        if not peer:
            return {"name": "unknown", "uid": None, "groups": [], "roles": []}
        name, groups = self.group_lookup(peer)
        if not self.enabled:
            roles = list(ROLES)           # nothing is checked
        elif peer.get("uid") == 0:
            roles = ["admin"]
        else:
            roles = [r for r in ROLES if name in self.roles[r]["users"] or groups & set(self.roles[r]["groups"])]
        return {"name": name, "uid": peer.get("uid"), "groups": sorted(groups), "roles": roles}

    def require(self, peer, action):
        """Identity of the caller if their roles allow `action`; Denied otherwise."""
        ident = self.identity(peer)
        if not self.enabled:
            return ident
        if not peer:
            raise Denied("cannot identify the caller; access denied")
        if not set(ident["roles"]) & ALLOWED[action]:
            need = sorted(ALLOWED[action], key=ROLES.index)
            raise Denied("role required: %s (%s has: %s)" % (
                " or ".join(need), ident["name"], ", ".join(ident["roles"]) or "none"))
        return ident

    def may_cancel(self, ident, task):
        """Cancelling a task: submitters their own, admins any."""
        if "admin" in ident["roles"] or not self.enabled:
            return True
        return task.get("submitted_by") is not None and task.get("submitted_by") == ident["name"]
