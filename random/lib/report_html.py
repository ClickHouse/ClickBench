"""The HTML report of a group of the randomized benchmark, in the style of the
ClickBench page (index.html): one self-contained file (no external scripts,
styles or fonts).

  - selectors of the machines, the systems and the metric (geomean of the
    relative times, total time, penalized time, load time, data size), the
    metrics computed in the page for the selected systems, as in
    lib/metrics.py,
  - the summary: the systems ranked by the metric, with the bars of ClickBench,
  - the detailed comparison: queries x systems, the average time and its
    ratio to the best system, colored as on ClickBench; failures marked,
  - for every query (click its number): the SQL, its features, the translation for
    every system, the time and the status of every execution, the errors and
    the beginning of the output.

The data is embedded as JSON and rendered with textContent, so the outputs of
the systems can't inject markup.
"""

import json

import metrics
import production

FAILED = ("wrong", "error", "timeout", "unsupported")


def summarize(results, payloads, missing=()):
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
    for machine in sorted({m for m, _ in latest} | {x["machine"] for x in missing if x["machine"]}):
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
        verdicts = production.check([r for (m, _), r in latest.items() if m == machine], machine,
                                    [x for x in missing if x["machine"] == machine])
        for v in verdicts:
            v["demote"] = production.demote(v)
        failed = [{"directory": x["directory"], "error": x.get("error") or "the run failed"}
                  for x in missing if x["machine"] == machine]
        machines.append({"machine": machine, "systems": systems, "production": verdicts, "failed": failed})
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
<title>Randomized ClickBench: __TITLE__</title>
<style>
/* The style of the ClickBench page (index.html). */
:root {
    --color: black; --title-color: black; --background-color: white;
    --link-color: #08F; --link-hover-color: #F40;
    --selector-text-color: black; --selector-active-text-color: black;
    --selector-background-color: #EEE; --selector-active-background-color: #FFCB80;
    --selector-hover-text-color: black; --selector-hover-background-color: #FDB;
    --summary-every-other-row-color: #F8F8F8; --highlight-color: #EEE;
    --bar-color1: oklch(calc(0.9 - 0.6) 0.1 calc(90 - 60));
    --bar-color2: oklch(calc(0.9 - 0.4) 0.1 calc(90 - 40));
    --bar-color3: oklch(calc(0.9 - 0.1) 0.1 calc(90 - 20));
    --bar-color4: oklch(0.9 0.1 90);
    --tooltip-text-color: white; --tooltip-background-color: black;
    --shadow-color: grey; --code-background: #F4F4F4;
    --pass-color: #1B5E20; --pass-background: #DFF3E2; --fail-color: #8E1B1B; --fail-background: #FBE3E1;
    --rule-color: #DDD;
}
[data-theme="dark"] {
    --color: #CCC; --title-color: white; --background-color: #04293A;
    --link-color: #8CF; --link-hover-color: #FFF;
    --selector-text-color: white; --selector-background-color: #444;
    --selector-active-text-color: white; --selector-active-background-color: #088;
    --selector-hover-text-color: black; --selector-hover-background-color: white;
    --summary-every-other-row-color: #042e41; --highlight-color: #000;
    --bar-color1: oklch(calc(0.4 + 0.6) 0.1 calc(250 - 180));
    --bar-color2: oklch(calc(0.4 + 0.4) 0.1 calc(250 - 120));
    --bar-color3: oklch(calc(0.4 + 0.2) 0.1 calc(250 - 60));
    --bar-color4: oklch(0.4 0.1 250);
    --tooltip-text-color: white; --tooltip-background-color: #444;
    --shadow-color: black; --code-background: #03202D;
    --pass-color: #B6F0C2; --pass-background: #0D4A35; --fail-color: #FFC9C4; --fail-background: #5C1F24;
    --rule-color: #0B4560;
}
html, body { color: var(--color); background-color: var(--background-color); width: 100%; height: 100%; margin: 0; overflow: auto; box-sizing: border-box; }
body { font-family: 'Inter', sans-serif; padding: 1% 3% 0 3%; }
h1, h2 { color: var(--title-color); }
table { border-spacing: 1px; }
.stick-left { position: sticky; left: 0px; }
.intro { max-width: 60rem; line-height: 1.5; }
.selectors-container { padding: 2rem 0 2rem 0; user-select: none; }
.selectors-container th { text-align: left; vertical-align: top; white-space: nowrap; padding-top: 0.5rem; padding-right: 1rem; }
.selector { display: inline-block; margin-left: 0.1rem; padding: 0.2rem 0.5rem; background: var(--selector-background-color); color: var(--selector-text-color); border: 0.2rem solid var(--background-color); border-radius: 0.5rem; cursor: pointer; }
.selector-active { color: var(--selector-active-text-color); background: var(--selector-active-background-color); }
.selector:hover { color: var(--selector-hover-text-color) !important; background: var(--selector-background-color); }
.selector-active:hover { background: var(--selector-hover-background-color); }
a, a:visited { text-decoration: none; color: var(--link-color); cursor: pointer; }
a:hover { color: var(--link-hover-color); }
#summary tr:nth-child(odd) { background: var(--summary-every-other-row-color); }
.summary-name { white-space: nowrap; text-align: right; padding-right: 1rem; }
.summary-bar-cell { width: 100%; }
.summary-bar { height: 1rem; width: 100%; }
.summary-number { font-family: monospace; text-align: right; padding-left: 1rem; white-space: nowrap; }
/* A system that failed entirely (or on every query), as on JSONBench: a black bar and a skull and crossbones. */
.summary-bar-failed { background: black; }
.summary-row-failed .summary-number { font-family: inherit; font-size: 1.5rem; line-height: 1rem; }
.summary-counts { font-family: monospace; white-space: nowrap; padding-left: 1rem; font-size: 90%; }
th { padding-bottom: 0.5rem; }
.summary-row:hover { background: var(--highlight-color) !important; font-weight: bold; }
#details th { vertical-align: bottom; white-space: pre; }
#details td { white-space: pre; font-family: monospace; text-align: right; padding: 0.1rem 0.5rem; }
#details td.details-query { text-align: left; position: sticky; left: 0; background-color: var(--background-color); }
.shadow:hover { box-shadow: 0 0 1rem var(--shadow-color); position: relative; }
#tip { position: fixed; pointer-events: none; display: none; background-color: var(--tooltip-background-color); color: var(--tooltip-text-color); box-shadow: 0 0 1rem var(--shadow-color); padding: 0.5rem 0.75rem; border-radius: 0.5rem; z-index: 2; max-width: 40rem; font-size: 90%; white-space: pre-wrap; font-family: monospace; }
.theme-switch { position: absolute; top: 1rem; right: 3%; }
.query-block { padding: 0.5rem 0; border-top: 1px solid var(--highlight-color); }
.query-block h3 { margin: 0.5rem 0; }
pre { background: var(--code-background); padding: 0.5rem; border-radius: 0.5rem; white-space: pre-wrap; word-break: break-word; max-height: 20rem; overflow: auto; }
.muted { opacity: 0.7; }
.feature { display: inline-block; margin-right: 0.3rem; padding: 0 0.4rem; border-radius: 0.5rem; background: var(--selector-background-color); font-size: 85%; }
footer { padding: 2rem 0; }
/* The table of the Production requirements. */
.prod-table { border-collapse: collapse; margin: 0.5rem 0 1.5rem 0; }
.prod-table th, .prod-table td { padding: 0.35rem 0.7rem; vertical-align: middle; }
.prod-table thead th { text-align: right; white-space: nowrap; font-weight: 600; border-bottom: 2px solid var(--rule-color); padding-bottom: 0.35rem; }
.prod-table thead tr.prod-groups th { text-align: center; font-weight: 500; opacity: 0.75; border-bottom: 1px solid var(--rule-color); }
.prod-table thead th.prod-left { text-align: left; }
.prod-table tbody tr:nth-child(odd) { background: var(--summary-every-other-row-color); }
.prod-table tbody tr:hover { background: var(--highlight-color); }
.prod-table td.prod-system { white-space: nowrap; font-weight: 600; }
.prod-table td.prod-number { text-align: right; font-family: monospace; font-size: 95%; white-space: nowrap; }
.prod-table td.prod-group-start, .prod-table th.prod-group-start { border-left: 1px solid var(--rule-color); }
.prod-zero { opacity: 0.4; }
.prod-bad { color: var(--fail-color); font-weight: bold; }
.prod-none { text-align: center; opacity: 0.55; font-style: italic; }
.prod-category { display: inline-block; padding: 0 0.45rem; border-radius: 0.5rem; background: var(--selector-background-color); font-size: 85%; }
.prod-verdict { min-width: 16rem; max-width: 40rem; }
.prod-verdict-line { display: flex; align-items: baseline; }
.prod-badge { display: inline-block; padding: 0.05rem 0.5rem; border-radius: 0.5rem; font-size: 85%; font-weight: 600; white-space: nowrap; }
.prod-pass { color: var(--pass-color); background: var(--pass-background); }
.prod-fail { color: var(--fail-color); background: var(--fail-background); }
.prod-demote { color: var(--fail-color); background: var(--fail-background); outline: 2px solid var(--fail-color); }
.prod-reason { font-size: 85%; opacity: 0.8; margin-left: 0.5rem; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; }
</style>
</head>
<body>
<div class="theme-switch"><a class="selector" id="toggle-light">Light</a><a class="selector" id="toggle-dark">Dark</a></div>
<div class="stick-left">
<h1>Randomized ClickBench</h1>
<p class="intro" id="intro"></p>
</div>
<table class="selectors-container stick-left">
<tr><th>Machine: </th><td id="selectors_machine"></td></tr>
<tr><th>System: </th><td id="selectors_system"></td></tr>
<tr><th>Metric: </th><td id="selectors_metric"></td></tr>
</table>
<table id="summary-table" class="stick-left">
<thead><tr><th class="summary-name">System &amp; Machine</th><th colspan="3" style="text-align: left">Relative <span id="what">time</span> (lower is better).</th></tr></thead>
<tbody id="summary"></tbody>
</table>
<p class="stick-left intro muted" id="metric-note"></p>
<div class="stick-left"><h2>Detailed Comparison</h2>
<p class="intro muted">The average time of the runs of every query and its ratio to the best system's average; a failed run counts as 5× the slowest correct run of the query. Hover over a cell for the runs; click a query for its SQL, the translations and the outputs.</p></div>
<table id="details"><thead><tr id="details_head"></tr></thead><tbody id="details_body"></tbody></table>
<div class="stick-left"><h2>Production Requirements</h2>
<p class="intro muted">Two requirements of the Production category of ClickBench are checked by changing the queries: "changing benchmark queries does not lead to crashes or deadlocks" (no restarts of the system, no executions that lost the server, no timeouts) and "changing benchmark queries does not widen the performance gap to the baseline by more than two times compared to ClickHouse" (the gap to ClickHouse on these queries, the geomean of the ratios of the average times, over the gap of the hot runs in the main benchmark on the same machine). A Production or Elite system that fails is demoted.</p>
<div id="production"></div></div>
<div class="stick-left"><h2>Queries</h2></div>
<div class="stick-left" id="queries"></div>
<footer class="stick-left muted" id="footer"></footer>
<div id="tip"></div>
<script id="data" type="application/json">__DATA__</script>
<script>
"use strict";
const D = JSON.parse(document.getElementById("data").textContent);
const constant_time_add = 0.01;
const failure_penalty = 5;
const FAILED = ["wrong", "error", "timeout", "unsupported"];
const STATUS_TEXT = { ok: "correct", wrong: "wrong result", error: "error", timeout: "timeout", unsupported: "unsupported", unverified: "no reference" };
const STATUS_SHORT = { wrong: "wrong", error: "error", timeout: "timeout", unsupported: "unsupp.", unverified: "?" };

function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (k === "class") e.className = v; else if (k === "style") e.style.cssText = v; else e.setAttribute(k, v);
    }
    for (const c of children) if (c !== null && c !== undefined) e.append(c instanceof Node ? c : String(c));
    return e;
}
const fmtTime = t => t === null || t === undefined ? "–" : t >= 100 ? t.toFixed(0) + "s" : t >= 10 ? t.toFixed(1) + "s" : t.toFixed(2) + "s";
const fmtSize = n => typeof n !== "number" ? "–" : (n / 1024 / 1024 / 1024).toFixed(2) + " GiB";

/// Every (system, machine) is an entry, as on the ClickBench page.
const entries = [];
for (const M of D.machines) for (const s of M.systems) entries.push({ ...s, machine: M.machine, key: s.directory + " (" + M.machine + ")" });
const machines = D.machines.map(m => m.machine);
/// The systems without a result (they failed to install, start or load): shown in the summary only.
const failedEntries = [];
for (const M of D.machines) for (const f of (M.failed || [])) failedEntries.push({ ...f, machine: M.machine, key: f.directory + " (" + M.machine + ")" });
const selectors = { machine: Object.fromEntries(machines.map(m => [m, true])), system: Object.fromEntries([...entries, ...failedEntries].map(e => [e.directory, true])), metric: "geomean" };
/// No run of the system returned a correct (or at least unverified) result.
const allFailed = e => !(e.counts.ok || e.counts.unverified);
const METRICS = { geomean: "Geomean of relative times", total: "Total time", penalized: "Penalized time", load: "Load time", size: "Data size" };

/// The same as lib/metrics.py, for the selected entries of one machine.
function geomeans(list) {
    const worst = {};
    for (const e of list) for (const [q, c] of Object.entries(e.cells)) for (const r of c.runs)
        if (!FAILED.includes(r.status)) worst[q] = Math.max(worst[q] || 0, r.time);
    const avg = list.map(e => {
        const a = {};
        for (const [q, c] of Object.entries(e.cells)) {
            if (!(q in worst)) continue;
            const ts = c.runs.map(r => FAILED.includes(r.status) ? failure_penalty * worst[q] : r.time);
            a[q] = ts.reduce((x, y) => x + y, 0) / ts.length;
        }
        return a;
    });
    const best = {};
    for (const a of avg) for (const [q, t] of Object.entries(a)) best[q] = Math.min(best[q] ?? Infinity, t);
    return { avg, best, worst, geo: avg.map(a => {
        const qs = Object.keys(best).filter(q => q in a);
        if (!qs.length) return null;
        return Math.exp(qs.reduce((s, q) => s + Math.log((constant_time_add + a[q]) / (constant_time_add + best[q])), 0) / qs.length);
    }) };
}

/// The bar of the ClickBench page: the same value at four scales, each next zoomed 10 times.
function barGradient(percentage) {
    const stop = zoom => Math.min(100, percentage * zoom);
    return `linear-gradient(to right, var(--bar-color1) 0%, var(--bar-color1) ${stop(1)}%, var(--bar-color2) ${stop(1)}%, var(--bar-color2) ${stop(10)}%, var(--bar-color3) ${stop(10)}%, var(--bar-color3) ${stop(100)}%, var(--bar-color4) ${stop(100)}%, var(--bar-color4) ${stop(1000)}%, transparent ${stop(1000)}%, transparent 100%)`;
}

/// The colors of the detailed comparison of the ClickBench page.
function colorize(elem, ratio) {
    let [r, g, b] = [0, 0, 0];
    if (ratio !== null) {
        if (ratio <= 1) { g = 255; }
        else if (ratio <= 2) { g = 255; r = (ratio - 1) * 255; }
        else if (ratio <= 10) { g = (10 - ratio) / 8 * 255; r = 255; }
        else { r = (1 - ((ratio - 10) / ((ratio - 10) + 1000))) * 255; }
    }
    if (document.documentElement.getAttribute("data-theme") == "dark") { r /= 1.5; g /= 1.5; b /= 1.5; }
    elem.style.backgroundColor = `rgb(${r}, ${g}, ${b})`;
    elem.style.color = ratio === null || ratio > 10 ? "white" : "black";
    if (ratio == 1) elem.style.fontWeight = "bold";
}

const tip = document.getElementById("tip");
function showTip(ev, text) {
    tip.textContent = text; tip.style.display = "block";
    tip.style.left = Math.min(ev.clientX + 14, window.innerWidth - tip.offsetWidth - 8) + "px";
    tip.style.top = Math.min(ev.clientY + 14, window.innerHeight - tip.offsetHeight - 8) + "px";
}
const hideTip = () => { tip.style.display = "none"; };

function selectorRow(id, items, isActive, onClick) {
    const td = document.getElementById(id);
    td.replaceChildren();
    for (const [value, label] of items) {
        const a = el("a", { class: "selector" + (isActive(value) ? " selector-active" : "") }, label);
        a.addEventListener("click", () => { onClick(value); render(); });
        td.append(a);
    }
}

function render() {
    selectorRow("selectors_machine", machines.map(m => [m, m]), m => selectors.machine[m], m => { selectors.machine[m] = !selectors.machine[m]; });
    selectorRow("selectors_system", [...new Set([...entries, ...failedEntries].map(e => e.directory))].sort().map(d => [d, d]), d => selectors.system[d], d => { selectors.system[d] = !selectors.system[d]; });
    selectorRow("selectors_metric", Object.entries(METRICS), m => selectors.metric === m, m => { selectors.metric = m; });

    const selected = entries.filter(e => selectors.machine[e.machine] && selectors.system[e.directory]);
    // The geomean is relative to the best of the selected systems on the same machine.
    const geo = new Map(), avgs = new Map(), bests = new Map();
    for (const m of machines) {
        const list = selected.filter(e => e.machine === m);
        if (!list.length) continue;
        const g = geomeans(list);
        list.forEach((e, i) => { geo.set(e.key, g.geo[i]); avgs.set(e.key, g.avg[i]); bests.set(e.key, g.best); });
    }
    const value = e => selectors.metric === "geomean" ? geo.get(e.key) : selectors.metric === "total" ? e.total
        : selectors.metric === "penalized" ? e.penalized : selectors.metric === "load" ? e.load_time : e.data_size;
    const vals = selected.map(value).filter(v => typeof v === "number" && v > 0);
    const min = Math.min(...vals);
    const ratio = e => { const v = value(e); return typeof v === "number" && v > 0 ? (selectors.metric === "geomean" ? v : v / min) : null; };
    // The systems that failed on every query come after the others, with the skull.
    const sorted = [...selected].sort((a, b) => (allFailed(a) - allFailed(b)) || ((ratio(a) ?? Infinity) - (ratio(b) ?? Infinity)));
    const maxRatio = Math.max(1, ...sorted.filter(e => !allFailed(e)).map(ratio).filter(x => x !== null));
    document.getElementById("what").textContent = selectors.metric === "size" ? "size" : "time";

    const summary = document.getElementById("summary");
    summary.replaceChildren();
    for (const e of sorted) {
        const r = ratio(e);
        const c = e.counts;
        const failed = FAILED.reduce((s, k) => s + (c[k] || 0), 0);
        const dead = allFailed(e);
        const text = dead ? "☠" : r === null ? "–" : selectors.metric === "geomean" ? `×${r.toFixed(2)}`
            : selectors.metric === "size" ? `${fmtSize(e.data_size)} (×${r.toFixed(2)})` : `${fmtTime(value(e))} (×${r.toFixed(2)})`;
        const tr = el("tr", { class: dead ? "summary-row summary-row-failed" : "summary-row" },
            el("td", { class: "summary-name" }, e.key + ": "),
            el("td", { class: "summary-bar-cell" }, dead ? el("div", { class: "summary-bar summary-bar-failed" })
                : el("div", { class: "summary-bar", style: `background:${r === null ? "none" : barGradient(r / maxRatio * 100)}` })),
            el("td", { class: "summary-number" }, text),
            el("td", { class: "summary-counts" }, `${c.ok || 0} correct` + (c.wrong ? `, ${c.wrong} wrong` : "") + (failed - (c.wrong || 0) ? `, ${failed - (c.wrong || 0)} failed` : "")));
        tr.addEventListener("mousemove", ev => showTip(ev, `${e.key}\ngeomean ×${(geo.get(e.key) ?? NaN).toFixed(3)}\ntotal time ${fmtTime(e.total)}, penalized ${fmtTime(e.penalized)}\nload ${fmtTime(e.load_time)}, data size ${fmtSize(e.data_size)}\n` +
            Object.entries(c).map(([k, v]) => `${STATUS_TEXT[k] || k}: ${v}`).join(", ") + `\ntranslator: ${e.translator || "none"}`));
        tr.addEventListener("mouseleave", hideTip);
        summary.append(tr);
    }
    for (const f of failedEntries.filter(f => selectors.machine[f.machine] && selectors.system[f.directory])) {
        const tr = el("tr", { class: "summary-row summary-row-failed" },
            el("td", { class: "summary-name" }, f.key + ": "),
            el("td", { class: "summary-bar-cell" }, el("div", { class: "summary-bar summary-bar-failed" })),
            el("td", { class: "summary-number" }, "☠"),
            el("td", { class: "summary-counts" }, "no result"));
        tr.addEventListener("mousemove", ev => showTip(ev, `${f.key}\nfailed without a result:\n${f.error}`));
        tr.addEventListener("mouseleave", hideTip);
        summary.append(tr);
    }
    document.getElementById("metric-note").textContent = {
        geomean: "Geomean: for every query, the average time of the system's runs (a failed run counts as 5× the slowest correct run of the query among the selected systems), its ratio to the best average as (0.01 + time) / (0.01 + best), and the geometric mean of the ratios. As on ClickBench, but with the average instead of the best run, to account for the concurrency and the cold runs.",
        total: "Total time: the wall-clock time of all the runs (queries × repeats) with the concurrent workers.",
        penalized: `Penalized time: the total time plus the query timeout (${D.query_timeout} s) for every failed run, divided by the number of workers.`,
        load: "Load time: the time of the system's own load script on the generated data.",
        size: "Data size: as reported by the system after the load.",
    }[selectors.metric];

    // The detailed comparison: queries × entries, in the order of the summary.
    const head = document.getElementById("details_head");
    head.replaceChildren(el("th", {}, ""), ...sorted.map(e => el("th", {}, e.directory + "\n" + e.machine)));
    const body = document.getElementById("details_body");
    body.replaceChildren();
    for (const q of D.queries) {
        const qa = el("a", { href: "#q-" + q.id }, q.id);
        const tr = el("tr", {}, el("td", { class: "details-query" }, qa));
        qa.addEventListener("mousemove", ev => showTip(ev, (q.description ? q.description + "\n\n" : "") + q.sql));
        qa.addEventListener("mouseleave", hideTip);
        for (const e of sorted) {
            const cell = e.cells[q.id];
            const a = (avgs.get(e.key) || {})[q.id];
            const best = (bests.get(e.key) || {})[q.id];
            const bad = cell ? ["wrong", "error", "timeout", "unsupported", "unverified"].find(k => cell.statuses.includes(k)) : null;
            const allFailed = cell && cell.runs.every(r => FAILED.includes(r.status));
            let text, r = null;
            if (!cell) text = "–";
            else if (allFailed) text = STATUS_SHORT[bad] || bad;
            else if (a === undefined) text = fmtTime(cell.average);
            else { r = (constant_time_add + a) / (constant_time_add + best); text = `${fmtTime(a)} (×${r.toFixed(2)})` + (bad ? " †" : ""); }
            const td = el("td", { class: "shadow" }, text);
            colorize(td, allFailed ? null : r);
            if (cell) {
                td.addEventListener("mousemove", ev => showTip(ev, `${q.id} on ${e.key}\n` + cell.runs.map(x => `run ${x.repeat}: ${STATUS_TEXT[x.status] || x.status}, ${fmtTime(x.time)}` + (x.detail ? " — " + x.detail.slice(0, 200) : "")).join("\n")));
                td.addEventListener("mouseleave", hideTip);
            }
            tr.append(td);
        }
        body.append(tr);
    }
}

// The header and the queries.
const rejected = Object.entries(D.rejected || {}).map(([k, v]) => `${v} ${k}`).join(", ");
document.getElementById("intro").textContent =
    `Group ${D.group}: ${D.queries.length} random queries, written by ${D.model || "a model"}, on ${D.rows.toLocaleString("en")} rows of random data ` +
    `made from the ClickBench dataset by clickhouse-obfuscator with a random seed. Every query runs ${D.repeats} times, in a pseudorandom order ` +
    `(the same on every system), on ${D.parallel} concurrent workers, with a timeout of ${D.query_timeout} s. The results are checked against ClickHouse ` +
    `${D.clickhouse_version} with the standard SQL semantics. The queries and the data are new for every group, so the results are comparable only within it.` +
    (D.generated ? ` ${D.generated} candidate queries were generated, ${D.valid} passed the validation` + (rejected ? ` (rejected: ${rejected})` : "") + "." : "");
document.getElementById("footer").textContent = `Seed ${D.seed}.`;

const qdiv = document.getElementById("queries");
for (const q of D.queries) {
    const block = el("div", { class: "query-block", id: "q-" + q.id });
    block.append(el("h3", {}, q.id + ". " + q.description), el("div", {}, ...q.features.map(f => el("span", { class: "feature" }, f))), el("pre", {}, q.sql));
    const det = el("details", {}, el("summary", {}, "Translations, runs and outputs"));
    for (const e of entries) {
        const cell = e.cells[q.id];
        det.append(el("h4", {}, e.key));
        const t = e.translations[q.id];
        if (t === null) det.append(el("div", { class: "muted" }, "No translation: the system can't express this query."));
        else if (t && t !== q.sql) det.append(el("div", { class: "muted" }, e.translator && e.translator !== "none" ? `Translation (${e.translator}):` : `As run (with the suffix of random/systems/${e.directory}/config):`), el("pre", {}, t));
        if (cell) det.append(el("div", {}, cell.runs.map(x => `run ${x.repeat}: ${STATUS_TEXT[x.status] || x.status}, ${fmtTime(x.time)}` + (x.detail ? " — " + x.detail : "")).join("; ")));
        const ref = e.reference[q.id];
        if (ref) det.append(el("div", { class: "muted" }, `Reference: ${ref.status}, ${fmtTime(ref.time)}`));
        if (e.outputs[q.id]) det.append(el("div", { class: "muted" }, "Output (the beginning of the first run):"), el("pre", {}, e.outputs[q.id]));
    }
    block.append(det);
    qdiv.append(block);
}

function renderProduction() {
    const div = document.getElementById("production");
    const num = (x, digits) => x === null || x === undefined ? "–" : digits === undefined ? String(x) : x.toFixed(digits);
    /// A count of crashes or timeouts: zero is muted, anything else is a failure.
    const count = (x, start) => el("td", { class: "prod-number" + (start ? " prod-group-start" : "") },
        el("span", { class: x ? "prod-bad" : "prod-zero" }, num(x)));
    for (const M of D.machines) {
        const rows = [...(M.production || [])].sort((a, b) => (a.passes === b.passes ? 0 : a.passes ? -1 : 1)
            || ((a.widening === null) - (b.widening === null)) || ((a.widening ?? 0) - (b.widening ?? 0)));
        const head = el("thead", {},
            el("tr", { class: "prod-groups" }, el("th", { colspan: 2 }, ""),
                el("th", { colspan: 3, class: "prod-group-start" }, "Crashes and deadlocks"),
                el("th", { colspan: 3, class: "prod-group-start" }, "Gap to ClickHouse"),
                el("th", { class: "prod-group-start" }, "")),
            el("tr", {}, el("th", { class: "prod-left" }, "System"), el("th", { class: "prod-left" }, "Category"),
                el("th", { class: "prod-group-start", title: "The system went down and the driver restarted it" }, "Restarts"),
                el("th", { title: "Executions that failed with a lost connection or a crash of the server" }, "Lost server"),
                el("th", { title: `Executions that ran into the query timeout of ${D.query_timeout} s` }, "Timeouts"),
                el("th", { class: "prod-group-start", title: "Geomean of (0.01 + average) / (0.01 + average of ClickHouse) on the random queries" }, "Random"),
                el("th", { title: "The same ratio of the hot runs in the main benchmark on this machine" }, "Standard"),
                el("th", { title: `Random over standard; more than ${2} fails` }, "Widening"),
                el("th", { class: "prod-left prod-group-start" }, "Verdict")));
        const body = el("tbody");
        for (const v of rows) {
            const badge = v.passes ? el("span", { class: "prod-badge prod-pass" }, "✓ passes")
                : v.demote ? el("span", { class: "prod-badge prod-demote" }, "▼ demote")
                : el("span", { class: "prod-badge prod-fail" }, "✗ fails");
            const reason = v.reasons.join("; ");
            const verdict = el("td", { class: "prod-verdict prod-group-start" }, el("div", { class: "prod-verdict-line" }, badge,
                reason ? el("div", { class: "prod-reason", title: reason }, reason) : null));
            const tr = el("tr", {}, el("td", { class: "prod-system" }, v.directory),
                el("td", {}, v.category ? el("span", { class: "prod-category" }, v.category) : "–"));
            if (v.restarts === null) {
                tr.append(el("td", { colspan: 6, class: "prod-none prod-group-start" }, "no result: failed before the queries"));
            } else {
                const wide = v.widening !== null && v.widening > 2;
                tr.append(count(v.restarts, true), count(v.crashed), count(v.timeouts),
                    el("td", { class: "prod-number prod-group-start" }, v.random_gap === null ? "–" : "×" + num(v.random_gap, 2)),
                    el("td", { class: "prod-number" }, v.standard_gap === null ? "–" : "×" + num(v.standard_gap, 2)),
                    el("td", { class: "prod-number" }, el("span", { class: wide ? "prod-bad" : "" }, v.widening === null ? "–" : "×" + num(v.widening, 2))));
            }
            tr.append(verdict);
            body.append(tr);
        }
        div.append(el("h3", {}, M.machine), el("table", { class: "prod-table" }, head, body));
    }
}
renderProduction();

let theme = window.localStorage.getItem("theme") || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
function setTheme(t) { theme = t; document.documentElement.setAttribute("data-theme", t); window.localStorage.setItem("theme", t); render(); }
document.getElementById("toggle-light").addEventListener("click", () => setTheme("light"));
document.getElementById("toggle-dark").addEventListener("click", () => setTheme("dark"));
document.documentElement.setAttribute("data-theme", theme);
render();
</script>
</body>
</html>
"""


def render(results, payloads, missing=()):
    data = summarize(results, payloads, missing)
    # Inside <script>, "</" could end the element: escape "<" everywhere.
    blob = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    title = f"group {data['group']}".replace("<", "&lt;")
    return PAGE.replace("__TITLE__", title).replace("__DATA__", blob)
