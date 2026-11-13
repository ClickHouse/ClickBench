"""The HTML report of a group of the randomized benchmark: one self-contained
file (no external scripts, styles or fonts).

  - the parameters of the group,
  - for every machine type: the systems ranked by the geomean of the relative
    times (bars, see metrics.py), with the total and the penalized time,
    with the counts of correct, wrong and failed executions, the load time and
    the data size,
  - a matrix of queries x systems: the average time of the correct executions,
    colored by the ratio to the fastest system on that query; failures are
    marked with an icon and a label,
  - for every query (click a row): the SQL, its features, the translation for
    every system, the time and the status of every execution, the errors and
    the beginning of the output.

The data is embedded as JSON and rendered with textContent, so the outputs of
the systems can't inject markup.
"""

import json

import metrics

FAILED = ("wrong", "error", "timeout", "unsupported")


def summarize(results, payloads):
    """The data for the page: everything the script of the page renders."""
    first = results[0]
    latest = {}
    for r in results:
        latest[(r["machine"], r["directory"])] = r
    queries = []
    canonical = next(iter(payloads.values()))["queries"] if payloads else {"queries": []}
    for q in canonical.get("queries", []):
        queries.append({"id": q["id"], "sql": q["sql"], "features": q.get("features", []),
                        "description": q.get("description", "")})
    if not queries:
        queries = [{"id": i, "sql": "", "features": [], "description": ""}
                   for i in sorted({e["id"] for r in results for e in r["executions"]})]
    machines = []
    for machine in sorted({m for m, _ in latest}):
        geo = metrics.geomeans([r for (m, _), r in latest.items() if m == machine])
        systems = []
        for (m, directory), r in latest.items():
            if m != machine:
                continue
            counts = r["counts"]
            per_query = {}
            for e in r["executions"]:
                per_query.setdefault(e["id"], []).append(
                    {"repeat": e["repeat"], "status": e["status"], "time": e["time"],
                     "reported": e.get("reported_time"), "detail": e.get("detail", "")[:500]})
            cells = {}
            for qid, runs in per_query.items():
                ok = [x["time"] for x in runs if x["status"] == "ok"]
                statuses = sorted({x["status"] for x in runs})
                cells[qid] = {"average": sum(ok) / len(ok) if ok else None, "statuses": statuses,
                              "runs": sorted(runs, key=lambda x: x["repeat"])}
            translated = payloads.get(directory, {}).get("translated", {})
            systems.append({
                "directory": directory, "system": r.get("system") or directory,
                "penalized": metrics.penalized_time(r), "geomean": geo.get(directory),
                "total": r["total_time"], "counts": counts, "load_time": r.get("load_time"),
                "data_size": r.get("data_size"), "restarts": r.get("restarts", 0),
                "translator": r.get("translator") or translated.get("translator"),
                "translations": {q["id"]: q["sql"] for q in translated.get("queries", [])},
                "outputs": r.get("outputs", {}), "cells": cells,
                "reference": r.get("reference", {}), "commit": r.get("commit", ""),
            })
        systems.sort(key=lambda s: (s["geomean"] is None, s["geomean"] or 0))
        machines.append({"machine": machine, "systems": systems})
    meta = next(iter(payloads.values()))["queries"] if payloads else {}
    return {
        "group": first.get("group", ""), "rows": first["rows"], "repeats": first["repeats"],
        "parallel": first["parallel"], "query_timeout": first["query_timeout"],
        "clickhouse_version": first["clickhouse_version"], "seed": first.get("seed", ""),
        "model": meta.get("model", ""), "generated": meta.get("generated"), "valid": meta.get("valid"),
        "rejected": meta.get("rejected", {}), "queries": queries, "machines": machines,
    }


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Randomized ClickBench: __TITLE__</title>
<style>
:root {
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --ring: rgba(11,11,11,0.10); --bar: #2a78d6; --bar2: #9ec5f4;
  --good: #0ca30c; --warning: #fab219; --serious: #ec835a; --critical: #d03b3b;
  --s0: #cde2fb; --s1: #9ec5f4; --s2: #6da7ec; --s3: #3987e5; --s4: #256abf; --s5: #184f95; --s6: #0d366b;
  --t0: #0b0b0b; --t1: #0b0b0b; --t2: #0b0b0b; --t3: #0b0b0b; --t4: #fff; --t5: #fff; --t6: #fff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10); --bar: #3987e5; --bar2: #184f95;
    --s0: #0d366b; --s1: #104281; --s2: #184f95; --s3: #256abf; --s4: #3987e5; --s5: #6da7ec; --s6: #9ec5f4;
    --t0: #fff; --t1: #fff; --t2: #fff; --t3: #fff; --t4: #0b0b0b; --t5: #0b0b0b; --t6: #0b0b0b;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1400px; margin: 0 auto; padding: 24px; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 17px; margin: 32px 0 8px; }
h3 { font-size: 14px; margin: 16px 0 6px; color: var(--ink2); }
.sub { color: var(--ink2); margin: 0 0 16px; }
.card { background: var(--surface); border: 1px solid var(--ring); border-radius: 8px; padding: 16px; margin: 12px 0; overflow-x: auto; }
dl.params { display: grid; grid-template-columns: max-content 1fr; gap: 2px 16px; margin: 0; }
dl.params dt { color: var(--ink2); }
dl.params dd { margin: 0; font-variant-numeric: tabular-nums; }
table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { padding: 4px 8px; text-align: right; white-space: nowrap; }
th { color: var(--ink2); font-weight: 600; border-bottom: 1px solid var(--axis); }
td.l, th.l { text-align: left; }
tr.sys td { border-bottom: 1px solid var(--grid); }
.barcell { width: 30%; min-width: 200px; text-align: left; }
table.rank { width: 100%; }
.bar { position: relative; height: 18px; }
.bar span.fill { position: absolute; left: 0; top: 2px; height: 14px; background: var(--bar); border-radius: 0 4px 4px 0; }
.bar span.fill.total { border-radius: 0; }
.bar span.fill.penalty { background: var(--bar2); }
.bar span.cut { position: absolute; top: 0; width: 6px; height: 18px; background: var(--surface); transform: skewX(-20deg); }
.bar span.val { position: absolute; top: 0; font-size: 12px; color: var(--ink2); }
.status { display: inline-flex; align-items: center; gap: 4px; }
.dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; }
table.matrix td.cell { min-width: 84px; border: 2px solid var(--surface); border-radius: 4px; cursor: pointer; font-size: 12px; }
table.matrix td.q { text-align: left; cursor: pointer; color: var(--ink2); }
table.matrix tr:hover td.q { color: var(--ink); text-decoration: underline; }
td.fail { background: var(--surface); color: var(--ink); box-shadow: inset 0 0 0 1px var(--axis); }
.legend { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 12px; color: var(--ink2); font-size: 12px; margin: 8px 0; }
.legend .sw { display: inline-block; width: 28px; height: 12px; border-radius: 2px; vertical-align: middle; margin-right: 4px; }
details.q { border-top: 1px solid var(--grid); padding: 6px 0; }
details.q summary { cursor: pointer; }
pre { background: var(--page); border: 1px solid var(--ring); border-radius: 6px; padding: 8px; white-space: pre-wrap; word-break: break-word; font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; max-height: 320px; overflow: auto; margin: 4px 0; }
.tag { display: inline-block; border: 1px solid var(--axis); border-radius: 10px; padding: 0 8px; margin: 0 4px 2px 0; font-size: 12px; color: var(--ink2); }
#tip { position: fixed; pointer-events: none; background: var(--surface); color: var(--ink); border: 1px solid var(--axis); border-radius: 6px; padding: 6px 8px; font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.2); display: none; max-width: 420px; z-index: 10; }
.muted { color: var(--muted); }
</style>
</head>
<body>
<main id="app"></main>
<div id="tip" role="tooltip"></div>
<script id="data" type="application/json">__DATA__</script>
<script>
"use strict";
const D = JSON.parse(document.getElementById("data").textContent);
const app = document.getElementById("app");
const tip = document.getElementById("tip");

function el(tag, attrs, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v; else if (k === "style") e.style.cssText = v; else e.setAttribute(k, v);
  }
  for (const c of children) if (c !== null && c !== undefined) e.append(c instanceof Node ? c : String(c));
  return e;
}
const fmtTime = t => t === null || t === undefined ? "–" : t >= 100 ? t.toFixed(0) + " s" : t >= 10 ? t.toFixed(1) + " s" : t.toFixed(2) + " s";
const fmtSize = n => { if (typeof n !== "number") return "–"; const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0; while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; } return n.toFixed(1) + " " + u[i]; };
const STATUS = {
  ok: { color: "var(--good)", icon: "✓", label: "correct" },
  wrong: { color: "var(--critical)", icon: "✕", label: "wrong result" },
  error: { color: "var(--serious)", icon: "!", label: "error" },
  timeout: { color: "var(--warning)", icon: "⏱", label: "timeout" },
  unsupported: { color: "var(--muted)", icon: "∅", label: "unsupported" },
  unverified: { color: "var(--muted)", icon: "?", label: "no reference" },
};
const ORDER = ["wrong", "error", "timeout", "unsupported", "unverified"];
const BINS = [1.1, 1.5, 2, 3, 5, 10, Infinity];
const BIN_LABELS = ["≤1.1×", "≤1.5×", "≤2×", "≤3×", "≤5×", "≤10×", ">10×"];
const binOf = r => BINS.findIndex(b => r <= b);

function showTip(ev, lines) {
  tip.replaceChildren(...lines.map((l, i) => el("div", i ? {} : { style: "font-weight:600" }, l)));
  tip.style.display = "block";
  const x = Math.min(ev.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
  const y = Math.min(ev.clientY + 14, window.innerHeight - tip.offsetHeight - 8);
  tip.style.left = x + "px"; tip.style.top = y + "px";
}
const hideTip = () => { tip.style.display = "none"; };

// Header.
app.append(el("h1", {}, "Randomized ClickBench"),
  el("p", { class: "sub" }, `Group ${D.group}: ${D.queries.length} random queries on ${D.rows.toLocaleString("en")} random rows, the same for every system and machine. Results are comparable only within the group.`));
const params = el("dl", { class: "params" });
const p = (k, v) => params.append(el("dt", {}, k), el("dd", {}, v));
p("Rows", D.rows.toLocaleString("en"));
p("Queries × repeats", `${D.queries.length} × ${D.repeats}, in a pseudorandom order, the same on every system`);
p("Concurrent workers", D.parallel);
p("Query timeout", D.query_timeout + " s");
p("Reference", "ClickHouse " + D.clickhouse_version + " with the standard SQL semantics");
if (D.model) p("Query generator", `${D.model}: ${D.generated} candidates, ${D.valid} valid` + (Object.keys(D.rejected).length ? " (rejected: " + Object.entries(D.rejected).map(([k, v]) => `${v} ${k}`).join(", ") + ")" : ""));
p("Seed", D.seed);
app.append(el("div", { class: "card" }, params));

for (const M of D.machines) {
  app.append(el("h2", {}, M.machine));

  // Ranking by the geomean of the relative times (one measure, one hue). The
  // scale ends at 4x the best geomean, so that one slow system doesn't
  // flatten the others; longer bars are cut.
  const best = Math.min(...M.systems.map(s => s.geomean ?? Infinity));
  const scale = Math.max(...M.systems.map(s => Math.min(s.geomean ?? 0, 4 * best)));
  const rank = el("table", { class: "rank" }, el("thead", {}, el("tr", {},
    el("th", { class: "l" }, "System"), el("th", { class: "l barcell" }, "Geomean of relative times"),
    el("th", {}, "Total time"), el("th", {}, "Penalized time"),
    el("th", {}, "Correct"), el("th", {}, "Wrong"), el("th", { class: "l" }, "Failed / unverified"),
    el("th", {}, "Load time"), el("th", {}, "Data size"))));
  const tb = el("tbody");
  for (const s of M.systems) {
    const g = s.geomean ?? 0;
    const w = scale > 0 ? Math.min(100, 100 * g / scale) : 0;
    const bar = el("div", { class: "bar" },
      el("span", { class: "fill", style: `width:max(2px, calc((100% - 64px) * ${w / 100}))` }),
      g > scale ? el("span", { class: "cut", style: `left:calc((100% - 64px) * 0.9)` }) : null,
      el("span", { class: "val", style: `left:calc((100% - 64px) * ${w / 100} + 6px)` }, s.geomean === null ? "–" : g.toFixed(2) + "×"));
    const c = s.counts;
    const n = k => { const v = c[k] || 0; if (!v || k === "ok") return String(v); const st = STATUS[k];
      return el("span", { class: "status" }, el("span", { class: "dot", style: `background:${st.color}` }), `${st.icon} ${v}`); };
    const tr = el("tr", { class: "sys" }, el("td", { class: "l" }, s.directory), el("td", { class: "barcell" }, bar),
      el("td", {}, fmtTime(s.total)), el("td", {}, fmtTime(s.penalized)), el("td", {}, n("ok")), el("td", {}, n("wrong")),
      el("td", { class: "l" }, ...(["error", "timeout", "unsupported", "unverified"].filter(k => c[k]).map(k => el("span", { style: "margin-right:10px" }, n(k)))), ["error", "timeout", "unsupported", "unverified"].some(k => c[k]) ? null : "0"),
      el("td", {}, fmtTime(s.load_time)), el("td", {}, fmtSize(s.data_size)));
    tr.addEventListener("mousemove", ev => showTip(ev, [s.directory,
      `geomean ${s.geomean === null ? "–" : s.geomean.toFixed(3) + "×"}; total ${fmtTime(s.total)}; penalized ${fmtTime(s.penalized)} = total + ${(c.wrong||0)+(c.error||0)+(c.timeout||0)+(c.unsupported||0)} failed × ${D.query_timeout} s / ${D.parallel} workers`,
      `translator: ${s.translator || "none"}`, s.restarts ? `restarts: ${s.restarts}` : ""].filter(Boolean)));
    tr.addEventListener("mouseleave", hideTip);
    tb.append(tr);
  }
  rank.append(tb);
  app.append(el("div", { class: "card" }, rank,
    el("p", { class: "muted" }, "Geomean (lower is better, 1× is the best on every query), as on the ClickBench page but with averages: for every query, the average time of the system's runs, a failed run counting as 5× the slowest correct run of the query in the group; its ratio to the best system's average, as (0.01 + time) / (0.01 + best); the geometric mean of the ratios. The scale ends at 4× the best; longer bars are cut (⫽). Total time: the wall-clock time of all runs with the concurrent workers. Penalized time: the total time plus the query timeout for every failed run, divided by the number of workers.")));

  // Matrix: queries × systems.
  const legend = el("div", { class: "legend" }, "Average time of the correct runs, by its ratio to the fastest system on the query:",
    ...BIN_LABELS.map((l, i) => el("span", {}, el("span", { class: "sw", style: `background:var(--s${i})` }), l)),
    ...ORDER.map(k => el("span", {}, el("span", { class: "dot", style: `background:${STATUS[k].color}` }), ` ${STATUS[k].icon} ${STATUS[k].label}`)));
  const mt = el("table", { class: "matrix" });
  mt.append(el("thead", {}, el("tr", {}, el("th", { class: "l" }, "Query"), ...M.systems.map(s => el("th", {}, s.directory)))));
  const mb = el("tbody");
  for (const q of D.queries) {
    const meds = M.systems.map(s => (s.cells[q.id] || {}).average).filter(x => x !== null && x !== undefined);
    const best = meds.length ? Math.min(...meds) : null;
    const tr = el("tr", {}, el("td", { class: "q", title: q.description }, q.id));
    tr.firstChild.addEventListener("click", () => { const d = document.getElementById("detail-" + q.id); d.open = true; d.scrollIntoView({ block: "start" }); });
    for (const s of M.systems) {
      const cell = s.cells[q.id];
      let td;
      if (!cell) { td = el("td", { class: "cell fail" }, "–"); }
      else {
        const bad = ORDER.find(k => cell.statuses.includes(k));
        if (cell.average === null || cell.average === undefined) {
          const st = STATUS[bad || "error"];
          td = el("td", { class: "cell fail" }, el("span", { class: "status" }, el("span", { class: "dot", style: `background:${st.color}` }), `${st.icon} ${st.label}`));
        } else {
          const ratio = best > 0 ? cell.average / best : 1;
          const b = binOf(ratio);
          const text = fmtTime(cell.average) + (bad ? " " + STATUS[bad].icon : "");
          td = el("td", { class: "cell", style: `background:var(--s${b});color:var(--t${b})` }, text);
        }
        td.addEventListener("mousemove", ev => showTip(ev, [`${q.id} on ${s.directory}`,
          ...cell.runs.map(r => `run ${r.repeat}: ${STATUS[r.status].icon} ${STATUS[r.status].label}, ${fmtTime(r.time)}` + (r.detail ? ` — ${r.detail.slice(0, 120)}` : "")),
          cell.average !== null && best ? `average ${fmtTime(cell.average)}, ${(cell.average / best).toFixed(2)}× the fastest` : ""].filter(Boolean)));
        td.addEventListener("mouseleave", hideTip);
        td.addEventListener("click", () => { const d = document.getElementById("detail-" + q.id); d.open = true; d.scrollIntoView({ block: "start" }); });
      }
      tr.append(td);
    }
    mb.append(tr);
  }
  mt.append(mb);
  app.append(el("h3", {}, "Queries"), el("div", { class: "card" }, legend, mt));
}

// Details of every query.
app.append(el("h2", {}, "Queries in detail"));
const det = el("div", { class: "card" });
for (const q of D.queries) {
  const d = el("details", { class: "q", id: "detail-" + q.id });
  d.append(el("summary", {}, el("b", {}, q.id), " ", q.description));
  d.append(el("div", {}, ...q.features.map(f => el("span", { class: "tag" }, f))));
  d.append(el("h3", {}, "SQL (the reference, ClickHouse)"), el("pre", {}, q.sql));
  for (const M of D.machines) for (const s of M.systems) {
    const cell = s.cells[q.id];
    d.append(el("h3", {}, `${s.directory} on ${M.machine}`));
    const tr = s.translations[q.id];
    if (tr && tr !== q.sql) d.append(el("div", { class: "muted" }, s.translator && s.translator !== "none"
      ? `Translation (${s.translator}):` : "As run (the query with the suffix of random/systems/" + s.directory + "/config):"), el("pre", {}, tr));
    else if (tr === null) d.append(el("div", { class: "muted" }, "No translation: the system can't express this query."));
    if (cell) {
      d.append(el("div", {}, ...cell.runs.map(r => el("div", {}, el("span", { class: "status" },
        el("span", { class: "dot", style: `background:${STATUS[r.status].color}` }),
        `run ${r.repeat}: ${STATUS[r.status].icon} ${STATUS[r.status].label}, ${fmtTime(r.time)}`), r.detail ? el("span", { class: "muted" }, " — " + r.detail) : ""))));
      const ref = s.reference[q.id];
      if (ref) d.append(el("div", { class: "muted" }, `Reference: ${ref.status}, ${fmtTime(ref.time)}`));
    }
    if (s.outputs[q.id]) d.append(el("div", { class: "muted" }, "Output (the beginning, repeat 1):"), el("pre", {}, s.outputs[q.id]));
  }
  det.append(d);
}
app.append(det);
</script>
</body>
</html>
"""


def render(results, payloads):
    data = summarize(results, payloads)
    # Inside <script>, "</" could end the element: escape "<" everywhere.
    blob = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    title = f"group {data['group']}".replace("<", "&lt;")
    return PAGE.replace("__TITLE__", title).replace("__DATA__", blob)
