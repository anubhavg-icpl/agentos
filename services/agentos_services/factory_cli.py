"""agentos-factory: command line for the software factory (docs/factory.md)."""

import argparse
import json
import os
import sys
import time

from .unixapi import call

DEFAULT_SOCKET = "/run/agentos-factory/factory.sock"


def _req(args, method, url, body=None):
    try:
        status, obj = call(args.socket, method, url, body)
    except OSError as exc:
        print("agentos-factory: cannot reach %s: %s" % (args.socket, exc), file=sys.stderr)
        raise SystemExit(2)
    if status >= 400:
        print("agentos-factory: %s" % obj.get("error", "HTTP %d" % status), file=sys.stderr)
        raise SystemExit(1)
    return obj


def _ts(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t)) if t else "-"


def fmt_item(it):
    out = ["%s  %s  [%s]  line=%s  round=%s  size=%s  cost=$%.2f" % (
        it["id"], it["title"], it["state"], it["line"], it["round"], it.get("size") or "-", it.get("cost_usd") or 0)]
    if it.get("error"):
        out.append("  error: %s" % it["error"])
    if it.get("pr_url"):
        out.append("  PR: %s" % it["pr_url"])
    out.append("  created %s by %s" % (_ts(it["created_at"]), it.get("submitted_by")))
    if it.get("acceptance"):
        out.append("  acceptance criteria (%s):" % it.get("criteria_source"))
        out += ["    %d. %s" % (i, c) for i, c in enumerate(it["acceptance"], 1)]
    out.append("  tasks:")
    for k, ids in it.get("tasks", {}).items():
        if ids:
            out.append("    %-8s %s" % (k, ", ".join(ids)))
    ev = it.get("evidence", {})
    if ev.get("plan"):
        out.append("  plan: size=%s scope=%s" % (ev["plan"].get("size"), ", ".join(ev["plan"].get("scope") or []) or "-"))
        out += ["    " + ln for ln in (ev["plan"].get("summary") or "").splitlines()[:30]]
    for v in ev.get("verify", []):
        out.append("  verify round %s: %s" % (v["round"], v["status"]))
    for r in ev.get("review", []):
        out.append("  review round %s: %s" % (r["round"], r.get("verdict") or "skipped"))
        out += ["    %s: %s" % (f["severity"], f["text"]) for f in r.get("findings", [])]
    for q in ev.get("qa", []):
        out.append("  qa round %s: %s" % (q["round"], q["verdict"]))
        out += ["    criterion %s: %s %s" % (c["n"], c["result"], c["reason"]) for c in q["criteria"]]
    for d in it.get("decisions", []):
        out.append("  decision %s: %s by %s %s" % (_ts(d["at"]), d["action"], d["by"], d.get("note") or ""))
    out.append("  history:")
    out += ["    %s %s -> %s %s" % (_ts(h["at"]), h["from"] or "-", h["to"], h.get("note") or "") for h in it.get("history", [])]
    return "\n".join(out)


def main(argv=None):
    p = argparse.ArgumentParser(prog="agentos-factory", description="AgentOS software factory")
    p.add_argument("--socket", default=os.environ.get("AGENTOS_FACTORY_SOCKET", DEFAULT_SOCKET))
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit", help="create a work item")
    s.add_argument("--line", required=True)
    s.add_argument("--title", required=True)
    s.add_argument("--body-file")
    s.add_argument("--criteria", action="append", default=[], help="acceptance criterion (repeatable)")
    s.add_argument("--priority", type=int, default=0)
    s = sub.add_parser("list", help="list items")
    s.add_argument("--line")
    s.add_argument("--state")
    for name in ("show", "export", "approve", "reject", "cancel", "retry", "done", "close"):
        s = sub.add_parser(name)
        s.add_argument("id")
        if name in ("approve", "reject", "cancel", "retry", "done", "close"):
            s.add_argument("--note", default="")
    sub.add_parser("lines", help="lines and their WIP")
    for name in ("pause", "resume"):
        sub.add_parser(name).add_argument("line")
    s = sub.add_parser("watch", help="follow items")
    s.add_argument("--line")
    s.add_argument("--interval", type=float, default=3.0)
    args = p.parse_args(argv)

    if args.cmd == "submit":
        body = {"line": args.line, "title": args.title, "source": {"kind": "cli"}, "priority": args.priority}
        if args.body_file:
            with open(args.body_file) as f:
                body["body"] = f.read()
        if args.criteria:
            body["acceptance"] = args.criteria
        obj = _req(args, "POST", "/items", body)
        print(obj["item"]["id"])
    elif args.cmd == "list":
        q = "&".join("%s=%s" % (k, v) for k, v in (("line", args.line), ("state", args.state)) if v)
        for it in _req(args, "GET", "/items" + ("?" + q if q else ""))["items"]:
            print("%-8s %-24s %-10s r%-2s $%-7.2f %s" % (it["id"], it["state"], it["line"], it["round"],
                                                          it.get("cost_usd") or 0, it["title"]))
    elif args.cmd == "show":
        print(fmt_item(_req(args, "GET", "/items/" + args.id)))
    elif args.cmd == "export":
        print(json.dumps(_req(args, "GET", "/items/%s/export" % args.id), indent=2, sort_keys=True))
    elif args.cmd in ("approve", "reject", "cancel", "retry", "done", "close"):
        it = _req(args, "POST", "/items/%s/%s" % (args.id, args.cmd), {"note": args.note})["item"]
        print("%s: %s" % (it["id"], it["state"]))
    elif args.cmd == "lines":
        for ln in _req(args, "GET", "/lines")["lines"]:
            print("%-14s %-22s %-14s in flight %d/%d, open PRs %d/%d%s" % (
                ln["name"], ln["repo"], ln["mode"], ln["active"], ln["max_in_flight"], ln["open_prs"],
                ln["max_open_prs"], "  PAUSED" if ln["paused"] else ""))
    elif args.cmd in ("pause", "resume"):
        ln = _req(args, "POST", "/lines/%s/%s" % (args.line, args.cmd), {})
        print("%s: %s" % (ln["name"], "paused" if ln["paused"] else "running"))
    elif args.cmd == "watch":
        seen = {}
        try:
            while True:
                q = "?line=" + args.line if args.line else ""
                for it in _req(args, "GET", "/items" + q)["items"]:
                    if seen.get(it["id"]) != it["state"]:
                        seen[it["id"]] = it["state"]
                        print("%s %s %s -> %s %s" % (time.strftime("%H:%M:%S"), it["id"], it["line"], it["state"], it["title"]))
                        sys.stdout.flush()
                time.sleep(args.interval)
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
