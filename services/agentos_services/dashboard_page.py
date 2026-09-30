"""The dashboard page: one self-contained HTML document, no external requests.

All dynamic text is inserted with textContent (request paths come from
agents), never as HTML.
"""

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AgentOS dashboard</title>
<style>
:root {
  --bg: #f6f7f9; --card: #ffffff; --fg: #1b1f24; --muted: #667085; --line: #e3e6eb;
  --accent: #2f6fed; --ok: #1a7f4b; --warn: #b7791f; --bad: #c0392b; --track: #e9ecf1;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #12151a; --card: #1a1e25; --fg: #e6e9ee; --muted: #8b95a5; --line: #2a303a;
    --accent: #6c9bff; --ok: #4cc38a; --warn: #e0a84a; --bad: #ef6b5b; --track: #2a303a;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between;
  padding: 14px 16px; border-bottom: 1px solid var(--line); background: var(--card); }
h1 { font-size: 17px; margin: 0; }
h2 { font-size: 13px; margin: 0 0 10px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); }
main { display: grid; gap: 16px; padding: 16px; max-width: 1200px; margin: 0 auto;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 420px), 1fr)); }
section { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; min-width: 0; }
section.wide { grid-column: 1 / -1; }
.pills { display: flex; flex-wrap: wrap; gap: 8px; }
.pill { padding: 2px 10px; border-radius: 999px; border: 1px solid var(--line); font-size: 12px; }
.pill.ok { color: var(--ok); border-color: var(--ok); }
.pill.bad { color: var(--bad); border-color: var(--bad); }
.scroll { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 500; font-size: 12px; white-space: nowrap; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
td.mono, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
.bar { position: relative; height: 8px; min-width: 80px; background: var(--track); border-radius: 4px; overflow: hidden; }
.bar > i { position: absolute; inset: 0 auto 0 0; background: var(--accent); }
.bar.warn > i { background: var(--warn); }
.bar.bad > i { background: var(--bad); }
.status-running { color: var(--ok); } .status-killed, .status-failed { color: var(--bad); }
.muted { color: var(--muted); }
.big { font-size: 26px; font-weight: 600; font-variant-numeric: tabular-nums; }
.days { display: flex; align-items: flex-end; gap: 6px; height: 120px; margin-top: 8px; }
.day { flex: 1; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; height: 100%; min-width: 0; }
.day > div { width: 100%; background: var(--accent); border-radius: 3px 3px 0 0; min-height: 1px; }
.day > span { font-size: 11px; color: var(--muted); margin-top: 4px; white-space: nowrap; }
.day > b { font-size: 11px; font-weight: 500; margin-bottom: 2px; }
select { background: var(--card); color: var(--fg); border: 1px solid var(--line); border-radius: 6px; padding: 4px 8px; }
#err { color: var(--bad); }
</style>
</head>
<body>
<header>
  <h1>AgentOS</h1>
  <div class="pills" id="health"></div>
  <div class="muted"><span id="err"></span> <span id="updated"></span></div>
</header>
<main>
  <section>
    <h2>Spend today</h2>
    <div class="big" id="total">-</div>
    <div class="muted" id="totalsub"></div>
    <div class="bar" id="totalbar" style="margin-top:8px"><i style="width:0"></i></div>
  </section>
  <section>
    <h2>Last 7 days</h2>
    <div class="days" id="days"></div>
  </section>
  <section class="wide">
    <h2>Agents</h2>
    <div class="scroll"><table id="agents">
      <thead><tr><th>Agent</th><th>Status</th><th>Workspace</th><th>Branch</th><th>Started</th><th>Budget</th><th class="num">Spend</th></tr></thead>
      <tbody></tbody>
    </table></div>
  </section>
  <section>
    <h2>Spend by agent (today)</h2>
    <div class="scroll"><table id="byagent">
      <thead><tr><th>Agent</th><th class="num">Requests</th><th class="num">Tokens in/out</th><th class="num">USD</th></tr></thead>
      <tbody></tbody>
    </table></div>
  </section>
  <section>
    <h2>Spend by model (today)</h2>
    <div class="scroll"><table id="bymodel">
      <thead><tr><th>Model</th><th class="num">USD</th></tr></thead>
      <tbody></tbody>
    </table></div>
  </section>
  <section class="wide">
    <h2>Recent gateway requests <select id="reqagent" aria-label="agent"></select></h2>
    <div class="scroll"><table id="reqs">
      <thead><tr><th>Time</th><th>Method</th><th>Path</th><th>Model</th><th>Status</th><th class="num">ms</th><th class="num">USD</th></tr></thead>
      <tbody></tbody>
    </table></div>
  </section>
</main>
<script>
"use strict";
const $ = (id) => document.getElementById(id);
const usd = (n) => "$" + (n || 0).toFixed(n && n < 1 ? 4 : 2);
const time = (t) => t ? new Date(t * 1000).toLocaleString() : "";

function cell(tr, text, cls) {
  const td = document.createElement("td");
  td.textContent = text == null ? "" : String(text);
  if (cls) td.className = cls;
  tr.appendChild(td);
  return td;
}
function bar(pct) {
  const d = document.createElement("div");
  const i = document.createElement("i");
  d.className = "bar" + (pct >= 100 ? " bad" : pct >= 80 ? " warn" : "");
  i.style.width = Math.max(0, Math.min(100, pct || 0)) + "%";
  d.appendChild(i);
  return d;
}
function fill(table, rows, build) {
  const body = table.tBodies[0];
  body.replaceChildren();
  if (!rows.length) {
    const tr = body.insertRow();
    const td = cell(tr, "nothing yet", "muted");
    td.colSpan = table.tHead.rows[0].cells.length;
  }
  rows.forEach((r) => build(body.insertRow(), r));
}
async function get(path) {
  const r = await fetch(path, { credentials: "same-origin", cache: "no-store" });
  if (!r.ok) throw new Error(path + ": HTTP " + r.status);
  return r.json();
}

function renderHealth(h) {
  const box = $("health");
  box.replaceChildren();
  Object.entries(h.services).forEach(([name, s]) => {
    const p = document.createElement("span");
    p.className = "pill " + (s.ok ? "ok" : "bad");
    p.textContent = name + (s.ok ? "" : " down");
    if (s.error) p.title = s.error;
    box.appendChild(p);
  });
}
function renderSpend(s) {
  $("total").textContent = usd(s.global_usd);
  $("totalsub").textContent = "of " + usd(s.global_limit_usd) + " global daily limit (" + s.date + " UTC)";
  const pct = s.global_limit_usd > 0 ? s.global_usd / s.global_limit_usd * 100 : 0;
  $("totalbar").replaceChildren(bar(pct).firstChild);
  $("totalbar").className = "bar" + (pct >= 100 ? " bad" : pct >= 80 ? " warn" : "");
  const agents = Object.entries(s.agents).sort((a, b) => b[1].usd - a[1].usd);
  fill($("byagent"), agents, (tr, [id, a]) => {
    const reqs = Object.values(a.requests).reduce((x, y) => x + y, 0);
    const t = a.tokens || {};
    cell(tr, id, "mono");
    cell(tr, reqs, "num");
    cell(tr, (t.input_tokens || 0) + " / " + (t.output_tokens || 0), "num");
    cell(tr, usd(a.usd), "num");
  });
  fill($("bymodel"), Object.entries(s.models).sort((a, b) => b[1] - a[1]), (tr, [m, v]) => {
    cell(tr, m, "mono");
    cell(tr, usd(v), "num");
  });
}
function renderHistory(h) {
  const days = h.days.slice().reverse();
  const max = Math.max(0.0001, ...days.map((d) => d.global_usd));
  const box = $("days");
  box.replaceChildren();
  days.forEach((d) => {
    const col = document.createElement("div");
    col.className = "day";
    const v = document.createElement("b");
    v.textContent = usd(d.global_usd);
    const b = document.createElement("div");
    b.style.height = Math.round(d.global_usd / max * 80) + "%";
    b.title = Object.entries(d.agents).map(([a, u]) => a + ": " + usd(u)).join("\n");
    const l = document.createElement("span");
    l.textContent = d.date.slice(5);
    col.append(v, b, l);
    box.appendChild(col);
  });
}
function renderAgents(a) {
  const rows = a.running.concat(a.history);
  fill($("agents"), rows, (tr, s) => {
    cell(tr, s.id, "mono");
    const st = cell(tr, s.status + (s.reason ? " (" + s.reason + ")" : ""));
    st.className = "status-" + s.status;
    cell(tr, s.workspace, "mono");
    cell(tr, s.branch, "mono");
    cell(tr, time(s.started_at));
    const b = document.createElement("td");
    b.appendChild(bar(s.budget_pct));
    tr.appendChild(b);
    cell(tr, usd(s.usd_today) + " / " + usd(s.limit_usd), "num");
  });
  const sel = $("reqagent");
  const known = new Set(Array.from(sel.options).map((o) => o.value));
  rows.forEach((s) => {
    if (!known.has(s.id)) {
      known.add(s.id);
      const o = document.createElement("option");
      o.value = o.textContent = s.id;
      sel.appendChild(o);
    }
  });
}
async function renderRequests() {
  const id = $("reqagent").value;
  if (!id) return fill($("reqs"), [], () => {});
  const r = await get("/api/requests?limit=50&agent=" + encodeURIComponent(id));
  fill($("reqs"), r.requests, (tr, e) => {
    cell(tr, time(e.ts));
    cell(tr, e.method);
    cell(tr, e.path, "mono");
    cell(tr, e.model || e.error || "");
    cell(tr, e.status);
    cell(tr, e.duration_ms, "num");
    cell(tr, e.cost_usd == null ? "" : usd(e.cost_usd), "num");
  });
}

async function refresh() {
  try {
    const [h, s, a, hist] = await Promise.all(
      ["/api/health", "/api/spend", "/api/agents", "/api/history?days=7"].map(get));
    renderHealth(h); renderSpend(s); renderAgents(a); renderHistory(hist);
    await renderRequests();
    $("err").textContent = "";
    $("updated").textContent = "updated " + new Date().toLocaleTimeString();
  } catch (e) {
    $("err").textContent = String(e.message || e);
  }
}
$("reqagent").addEventListener("change", () => renderRequests().catch(() => {}));
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""
