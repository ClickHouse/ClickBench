// ClickBench Playground — minimal vanilla-JS client.
//
// Talks to the host API.
//   1. On load, fetch /api/systems for the catalog and /api/state for live
//      states. Render systems as a vertical list, colored by current state.
//   2. Re-poll /api/state every 2 s and re-color the list. The currently
//      selected system also re-renders its status JSON blob below.
//   3. On click of a system row, select it. On "Run query", POST the SQL to
//      /api/query?system=<name> and render output as plain text in a <pre>.

const $ = (sel) => document.querySelector(sel);
// API base URL selection:
//   - clickbench-playground.clickhouse.com (default hosting) → same-origin,
//     use relative paths so responses stay path-transparent.
//   - Anywhere else on http/https (e.g. benchmark.clickhouse.com/playground/,
//     a mirror, a local build served via GitHub Pages) → absolute URL to
//     the live playground; CORS is open (Access-Control-Allow-Origin: *
//     is set by the server's middleware).
//   - file:// → localhost dev instance.
const API =
    location.hostname === "clickbench-playground.clickhouse.com" ? "" :
    location.protocol === "file:" ? "http://localhost:8000" :
    "https://clickbench-playground.clickhouse.com";

const listEl = $("#system-list");
const queryEl = $("#query");
const runBtn = $("#run");
const outEl = $("#output");
const outLabelEl = $("#output-label");
const timeEl = $("#time");
const stateBlob = $("#state-blob");
const lastErrorEl = $("#last-error");
const exampleSel = $("#example");
// #ui-stats and #ui-output are toggled independently by
// showResult/runQuery — only visible once there's a result for the
// selected system.
const uiActive = ["#ui-active", "#ui-query"].map($);
const uiStats = $("#ui-stats");
const uiOutput = $("#ui-output");
const uiDown = $("#ui-down");

let catalog = [];          // [{name, display_name, data_format, ...}]
let stateByName = {};      // {name: {state, ...}}
let selected = null;       // selected system name
let pollTimer = null;
let resultsByName = {};    // {name: {output, time, wall, bytes, truncated, exit}}
let queriesByName = {};    // {name: [q1, q2, ...]}
// The exact string we last auto-populated the textarea with (from an
// example). If the current textarea still equals it, the user hasn't
// edited it and we're free to swap in the next system's example.
let pristineQuery = "";

async function loadCatalog() {
    const r = await fetch(API + "/api/systems");
    catalog = await r.json();
    catalog.sort((a, b) => a.display_name.localeCompare(b.display_name));
    renderList();
    const hash = (location.hash || "").slice(1);
    if (hash && catalog.some(s => s.name === hash)) {
        select(hash);
    } else if (catalog.some(s => s.name === "clickhouse")) {
        select("clickhouse");
    } else if (catalog.length) {
        select(catalog[0].name);
    }
}

function renderList() {
    listEl.innerHTML = "";
    for (const s of catalog) {
        const sObj = stateByName[s.name];
        const st = (sObj && sObj.state) || "down";
        const row = document.createElement("div");
        row.className = `system-item state-${st}` + (s.name === selected ? " selected" : "");
        row.dataset.name = s.name;
        row.textContent = s.display_name;
        row.dataset.tooltip = tooltipFor(sObj, st);
        row.addEventListener("click", () => onSlabClick(s.name));
        // In competition mode, hovering a slab highlights its row in
        // the leaderboard so the user can scan from picker to result
        // without losing context.
        row.addEventListener("mouseenter", () => _setRailHover(s.name));
        row.addEventListener("mouseleave", () => _setRailHover(null));
        listEl.appendChild(row);
    }
}

function tooltipFor(sObj, st) {
    if (st === "ready") {
        const since = sObj && sObj.ready_since;
        if (since) {
            const ago = Math.max(0, Math.floor(Date.now() / 1000 - since));
            return "up " + formatDuration(ago);
        }
        return "up";
    }
    if (st === "snapshotted") return "ready";
    if (st === "provisioning") return "provisioning";
    if (st === "down") return "failed";
    return st;
}

function formatDuration(secs) {
    if (secs < 60) return `${secs} second${secs === 1 ? "" : "s"}`;
    if (secs < 3600) {
        const m = Math.floor(secs / 60);
        return `${m} minute${m === 1 ? "" : "s"}`;
    }
    if (secs < 86400) {
        const h = Math.floor(secs / 3600);
        return `${h} hour${h === 1 ? "" : "s"}`;
    }
    const d = Math.floor(secs / 86400);
    return `${d} day${d === 1 ? "" : "s"}`;
}

function onSlabClick(name) {
    // Systems that are mid-install/load aren't queryable yet; ignore
    // clicks so the user doesn't get a stranded selection.
    const st = stateByName[name] && stateByName[name].state;
    if (st === "provisioning") return;
    // Click on the already-selected system = shortcut to run the
    // current query, as long as that system is in a queryable state.
    if (name === selected) {
        if (st && st !== "down") runQuery();
        return;
    }
    select(name);
}

function select(name) {
    selected = name;
    location.hash = name;
    for (const row of listEl.children) {
        row.classList.toggle("selected", row.dataset.name === name);
    }
    if (stateByName[name]) {
        stateBlob.textContent = JSON.stringify(stateByName[name], null, 2);
    }
    showResult(resultsByName[name]);
    loadExamples(name);
    refreshDownUI();
    // Kick the restore in the background so the VM is hopefully ready
    // by the time the user presses Run query. No-op if the system is
    // already ready / provisioning / has no snapshot.
    maybeWarmup(name);
}

function maybeWarmup(name) {
    const s = stateByName[name];
    if (!s || s.state !== "snapshotted") return;
    fetch(`${API}/api/warmup/${encodeURIComponent(name)}`, {method: "POST"})
        .catch(() => {});  // fire-and-forget
}

async function loadExamples(name) {
    let qs = queriesByName[name];
    if (!qs) {
        try {
            const r = await fetch(`${API}/api/queries/${encodeURIComponent(name)}`);
            qs = r.ok ? await r.json() : [];
        } catch (e) {
            qs = [];
        }
        queriesByName[name] = qs;
    }
    if (selected !== name) return;  // user moved on
    // Preserve the example index across system switches: if the user
    // had Q5 selected for system A, switching to B keeps Q5.
    const prevIndex = parseInt(exampleSel.value, 10);
    exampleSel.innerHTML = "";
    if (!qs.length) {
        const o = document.createElement("option");
        o.textContent = "(no examples)";
        o.disabled = true;
        exampleSel.appendChild(o);
    } else {
        // Unselected placeholder so the first real change(...) the
        // user picks always counts as "different from current value"
        // and fires the change handler — even if they're re-picking
        // the option that was selected before they edited the
        // textarea. The textarea-edit handler below resets us back
        // to this entry.
        const placeholder = document.createElement("option");
        placeholder.value = "";
        placeholder.textContent = "—";
        placeholder.disabled = true;
        exampleSel.appendChild(placeholder);
        for (let i = 0; i < qs.length; i++) {
            const o = document.createElement("option");
            o.value = String(i);
            const label = qs[i].replace(/\s+/g, " ").slice(0, 90);
            o.textContent = `Q${i + 1}: ${label}`;
            exampleSel.appendChild(o);
        }
        // Clamp prevIndex into range; default to 0.
        let idx = 0;
        if (!isNaN(prevIndex) && prevIndex >= 0 && prevIndex < qs.length) {
            idx = prevIndex;
        }
        exampleSel.value = String(idx);
        refreshRunAllVisibility();
        // Replace the textarea with this system's example at the same
        // index, but only if the user hasn't edited the current text
        // (i.e., it still matches whatever example we last set, or
        // it's empty).
        const isPristine = queryEl.value === pristineQuery
            || !queryEl.value.trim();
        if (isPristine) {
            queryEl.value = qs[idx];
            pristineQuery = qs[idx];
        }
    }
}

let lastDownShownName = null;

function refreshDownUI() {
    const s = stateByName[selected];
    const isDown = s && s.state === "down";
    for (const el of uiActive) {
        if (el) el.style.display = isDown ? "none" : "";
    }
    if (isDown) {
        uiOutput.style.display = "none";
        uiStats.style.display = "none";
    }
    uiDown.style.display = isDown ? "" : "none";
    if (isDown) {
        // Render the last error once per selection. If poll picks up a
        // new last_error for the same system later, leave the UI alone
        // — the user is reading the text, we shouldn't move it under
        // their eyes.
        if (lastDownShownName !== selected) {
            const raw = (s && s.last_error) || "(no error recorded)";
            lastErrorEl.textContent = raw
                .replace(/\\n/g, "\n")
                .replace(/\\t/g, "\t")
                .replace(/\\r/g, "");
            lastDownShownName = selected;
        }
    } else {
        lastDownShownName = null;
    }
}

function _maybePrettyJson(s) {
    // If the body parses as JSON (entire string), re-emit it with
    // 2-space indentation. Otherwise return the original — most
    // engines print plain tables and we shouldn't touch them.
    if (!s || s.length < 2) return s;
    const first = s.charCodeAt(0);
    // Cheap pre-filter: only attempt JSON.parse when the first
    // non-whitespace byte looks like '{' or '['. Avoids parsing
    // every 14 GB count(*) row through a try/catch.
    let i = 0;
    while (i < s.length && (s.charCodeAt(i) <= 32)) i++;
    const c = s.charCodeAt(i);
    if (c !== 123 /* { */ && c !== 91 /* [ */) return s;
    try {
        const parsed = JSON.parse(s);
        // Only pretty-print structured values; bare numbers/strings/
        // booleans shouldn't be re-serialized.
        if (parsed === null || typeof parsed !== "object") return s;
        return JSON.stringify(parsed, null, 2);
    } catch {
        return s;
    }
}

function showResult(r) {
    if (!r) {
        outEl.textContent = "";
        timeEl.textContent = "—";
        outLabelEl.textContent = "Output";
        uiOutput.style.display = "none";
        uiStats.style.display = "none";
        return;
    }
    outEl.textContent = _maybePrettyJson(r.output);
    timeEl.textContent = r.time;
    outLabelEl.textContent = r.truncated === "yes" ? "Output (truncated)" : "Output";
    uiOutput.style.display = "";
    uiStats.style.display = "";
}

async function pollState() {
    try {
        const r = await fetch(API + "/api/state");
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const arr = await r.json();
        stateByName = {};
        for (const s of arr) stateByName[s.name] = s;
        // Update each row's color + state badge without rebuilding the DOM
        for (const row of listEl.children) {
            const s = stateByName[row.dataset.name];
            const st = (s && s.state) || "down";
            row.className = `system-item state-${st}` +
                (row.dataset.name === selected ? " selected" : "");
            row.dataset.tooltip = tooltipFor(s, st);
        }
        if (selected && stateByName[selected]) {
            stateBlob.textContent = JSON.stringify(stateByName[selected], null, 2);
        }
        refreshDownUI();
    } catch (e) {
        stateBlob.textContent = String(e);
    }
}

// X-Error is URL-encoded on the wire because HTTP headers can't carry
// raw \n. Decode here so real newlines survive end-to-end. Falls back
// to the raw value if the header isn't actually encoded (older agents).
function _decodeXError(s) {
    if (!s) return s;
    try { return decodeURIComponent(s); }
    catch { return s; }
}

async function runQuery() {
    if (!selected) return;
    const sql = queryEl.value;
    if (!sql.trim()) return;
    // Running a single query takes us out of competition view.
    hideRunAll();
    runBtn.disabled = true;
    outEl.textContent = "(running …)";
    timeEl.textContent = "…";
    outLabelEl.textContent = "Output";
    uiOutput.style.display = "";
    uiStats.style.display = "";

    const target = selected;  // capture in case the user switches mid-flight
    const t0 = performance.now();
    let payload = null;
    try {
        const r = await fetch(`${API}/api/query?system=${encodeURIComponent(target)}`, {
            method: "POST",
            body: sql,
            headers: {"Content-Type": "application/octet-stream"},
        });
        const body = await r.arrayBuffer();
        const txt = bytesToText(body) || "(no output)";
        const h = (k) => r.headers.get(k);
        const qt = h("X-Query-Time");
        const wt = h("X-Wall-Time");
        let output = txt;
        if (r.status >= 400) {
            const err = _decodeXError(h("X-Error"));
            if (err) {
                const trailer = `\n\n(error)\n${err}`;
                output = (txt === "(no output)" ? "" : txt) + trailer;
            }
        }
        payload = {
            output,
            time: qt ? `${parseFloat(qt).toFixed(3)} s` : "—",
            wall: wt ? `${parseFloat(wt).toFixed(3)} s` : `${((performance.now() - t0) / 1000).toFixed(3)} s`,
            bytes: h("X-Output-Bytes") || String(body.byteLength),
            truncated: h("X-Output-Truncated") === "1" ? "yes" : "no",
            exit: h("X-Exit-Code") || String(r.status),
        };
        // Permalink: the server returns a base64url 64-bit id; drop
        // it in the URL bar so reload/share keeps the result.
        const qid = h("X-Query-Id");
        if (qid) {
            const u = new URL(window.location.href);
            u.searchParams.set("q", qid);
            window.history.replaceState({}, "", u.toString());
        }
    } catch (e) {
        payload = {
            output: `(client error)\n${e}`,
            time: "—", wall: "—", bytes: "—", truncated: "—", exit: "err",
        };
    } finally {
        runBtn.disabled = false;
    }
    resultsByName[target] = payload;
    if (selected === target) showResult(payload);
}

function bytesToText(buf) {
    try {
        return new TextDecoder("utf-8", {fatal: false}).decode(buf);
    } catch {
        return [...new Uint8Array(buf)].map(b => String.fromCharCode(b)).join("");
    }
}

runBtn.addEventListener("click", runQuery);
function applyExampleIdx(i) {
    const qs = queriesByName[selected];
    if (!qs || isNaN(i) || i < 0 || i >= qs.length) return;
    queryEl.value = qs[i];
    pristineQuery = qs[i];
}

function applyCurrentExample() {
    applyExampleIdx(parseInt(exampleSel.value, 10));
}

exampleSel.addEventListener("change", () => {
    applyCurrentExample();
    refreshRunAllVisibility();
    hideRunAll();
});
// When the user types in the textarea, mark the select as
// "unselected" (the disabled placeholder option). That way a
// subsequent click on whatever they had picked before counts as a
// real change and re-applies the example — no more blur-listener
// hack.
queryEl.addEventListener("input", () => {
    if (queryEl.value !== pristineQuery) {
        exampleSel.value = "";
    }
    refreshRunAllVisibility();
});
queryEl.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") runQuery();
});

async function maybeLoadShared() {
    // ?q=<base64url> permalink — fetch the saved query+result and
    // replay it as if we just ran it.
    const u = new URL(window.location.href);
    const qid = u.searchParams.get("q");
    if (!qid) return;
    try {
        const r = await fetch(`${API}/api/saved/${encodeURIComponent(qid)}`);
        if (!r.ok) return;
        const row = await r.json();
        // The CH parameterized view returns JSONEachRow → one object.
        const sys = row.system;
        if (sys && stateByName[sys]) {
            select(sys);
        }
        queryEl.value = row.query || "";
        pristineQuery = queryEl.value;
        const payload = {
            output: row.output || "(no output)",
            time: row.query_time != null ? `${row.query_time.toFixed(3)} s` : "—",
            wall: row.wall_time != null ? `${row.wall_time.toFixed(3)} s` : "—",
            bytes: String(row.output_bytes ?? ""),
            truncated: row.output_truncated ? "yes" : "no",
            exit: String(row.status ?? ""),
        };
        if (row.error) {
            payload.output = (payload.output === "(no output)" ? "" : payload.output)
                + `\n\n(error)\n${row.error}`;
        }
        resultsByName[selected] = payload;
        showResult(payload);
    } catch (e) {
        console.error("failed to load shared query", e);
    }
}

(async function init() {
    // Treat the HTML default ("SELECT COUNT(*) FROM hits;") as pristine
    // so first-system selection is free to swap it for the first
    // example.
    pristineQuery = queryEl.value;
    await loadCatalog();
    await pollState();
    await maybeLoadShared();
    pollTimer = setInterval(pollState, 2000);
})();

// ─── Competition mode ────────────────────────────────────────────────
// "Run all" fires the SAME example index against every snapshotted
// system in parallel, each using its OWN translation of that query
// (pandas runs hits.count(), polars runs hits.select(pl.len())..., etc.).
// Results are rendered in a table that re-sorts on every update:
// completed (fastest first), then failed (alphabetical), then running
// (alphabetical).
const runAllBtn = $("#run-all");
const runAllSection = $("#ui-runall");
const runAllTable = $("#runall-table");

function refreshRunAllVisibility() {
    // Always available when there's *something* to run: a picked
    // example index OR a non-empty custom query in the textarea.
    const haveExample = exampleSel.value !== ""
        && !isNaN(parseInt(exampleSel.value, 10));
    const haveCustom = queryEl.value.trim() !== "";
    runAllBtn.style.display = (haveExample || haveCustom) ? "" : "none";
}

function _setRailHover(name) {
    // Toggle a `.slab-hover` class on the matching tr in the
    // competition table. No-op when the rail isn't visible.
    if (runAllSection.style.display === "none") return;
    const tbody = runAllTable.querySelector("tbody");
    if (!tbody) return;
    for (const tr of tbody.children) {
        tr.classList.toggle("slab-hover", tr.dataset.name === name);
    }
}

function hideRunAll() {
    // Picking a different example or pressing Run are signals that
    // the user's attention has moved off the competition rail.
    // Collapse it so the right pane retakes the full width. Editing
    // the textarea does *not* trigger this — the user may want to
    // tweak the query, see the results refresh, and still compare
    // against the rail.
    if (runAllSection.style.display === "none") return;
    runAllSection.style.display = "none";
    uiSplit.classList.remove("split");
}

async function ensureQueriesLoaded(name) {
    if (queriesByName[name]) return queriesByName[name];
    try {
        const r = await fetch(`${API}/api/queries/${encodeURIComponent(name)}`);
        queriesByName[name] = r.ok ? await r.json() : [];
    } catch {
        queriesByName[name] = [];
    }
    return queriesByName[name];
}

const uiSplit = $("#ui-split");

function _measureSplitOffset() {
    // Pin the split row's height so that aside scrolls inside its
    // own track. Read the distance from the page top to #ui-split
    // and store it in a CSS var; the layout rule subtracts it from
    // 100 vh.
    const top = uiSplit.getBoundingClientRect().top + window.scrollY;
    document.documentElement.style.setProperty("--ui-split-offset", `${top + 20}px`);
}
window.addEventListener("resize", _measureSplitOffset);

async function runAll() {
    const idx = parseInt(exampleSel.value, 10);
    const useExampleIndex = !isNaN(idx);
    const customQuery = queryEl.value;
    if (!useExampleIndex && !customQuery.trim()) return;
    // Track which mode the competition was launched in. pickFromRunAll
    // uses this to decide whether to update pristineQuery on rail
    // clicks: in example-mode, each row click should re-baseline
    // pristineQuery to the new system's example translation so it
    // tracks the visible textarea cleanly; in custom-mode the
    // original pristineQuery is intentionally stale (different from
    // the textarea) so the user's edit isn't treated as pristine and
    // clobbered by loadExamples.
    runAllExampleMode = useExampleIndex;
    runAllBtn.disabled = true;
    runAllSection.style.display = "";
    uiSplit.classList.add("split");
    _measureSplitOffset();
    runAllSection.focus();

    // Collect candidate systems. With an example picked, each system
    // runs its OWN translation of the example at the same index
    // (the apples-to-apples ClickBench format). With a custom query
    // in the textarea, every system runs the exact same string —
    // the systems whose query language doesn't accept it will just
    // show up in the failed bucket.
    const candidates = Object.values(stateByName)
        .filter(s => s.state === "snapshotted" || s.state === "ready");
    const targets = [];
    for (const s of candidates) {
        if (useExampleIndex) {
            const qs = await ensureQueriesLoaded(s.name);
            if (qs && idx < qs.length) targets.push({name: s.name, query: qs[idx]});
        } else {
            targets.push({name: s.name, query: customQuery});
        }
    }

    const status = {};
    for (const t of targets) {
        status[t.name] = {
            state: "running",
            runs: [{state: "running"}, {state: "pending"}, {state: "pending"}],
            query: t.query,
        };
    }
    // Reset the flash-diff cache so the first render seeds 'running'
    // for every row without animating them all at once.
    runAllLast = {};
    runAllSelected = null;
    runAllStatus = status;
    renderRunAll(status);

    // Random order: keep the table sorted but fire requests in a
    // shuffled sequence so no single system gets a systematic head
    // start.
    const shuffled = targets.slice();
    for (let i = shuffled.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }

    async function _runOne(t) {
        const t0 = performance.now();
        try {
            const r = await fetch(`${API}/api/query?system=${encodeURIComponent(t.name)}`, {
                method: "POST",
                body: t.query,
                headers: {"Content-Type": "application/octet-stream"},
            });
            const body = await r.arrayBuffer();
            const txt = bytesToText(body) || "(no output)";
            const h = (k) => r.headers.get(k);
            const qid = h("X-Query-Id");
            if (r.status >= 400) {
                const err = _decodeXError(h("X-Error")) || `HTTP ${r.status}`;
                return {
                    ok: false, note: err, qid,
                    payload: {
                        output: `(error)\n${err}`,
                        time: "—", wall: "—", bytes: "—",
                        truncated: "—", exit: String(r.status),
                    },
                };
            }
            const qt = h("X-Query-Time");
            const wt = h("X-Wall-Time");
            const tsec = qt != null && qt !== ""
                ? parseFloat(qt)
                : (wt != null && wt !== "" ? parseFloat(wt) : (performance.now() - t0) / 1000);
            return {
                ok: true, time: tsec, qid,
                payload: {
                    output: txt,
                    time: qt ? `${parseFloat(qt).toFixed(3)} s` : "—",
                    wall: wt ? `${parseFloat(wt).toFixed(3)} s` : `${tsec.toFixed(3)} s`,
                    bytes: h("X-Output-Bytes") || String(body.byteLength),
                    truncated: h("X-Output-Truncated") === "1" ? "yes" : "no",
                    exit: h("X-Exit-Code") || String(r.status),
                },
            };
        } catch (e) {
            return {ok: false, note: String(e)};
        }
    }

    function _recordRun(name, idx, res, query) {
        const s = status[name];
        if (!s) return;
        s.runs[idx] = res.ok
            ? {state: "done", time: res.time}
            : {state: "failed", note: res.note};
        // Cache the first successful run's payload for click-to-show.
        if (res.ok && !s.payload) {
            s.payload = res.payload;
            s.qid = res.qid;
            s.query = query;
        } else if (!res.ok && !s.payload && idx === 0) {
            s.payload = res.payload || {
                output: `(error)\n${res.note || ""}`,
                time: "—", wall: "—", bytes: "—", truncated: "—", exit: "err",
            };
            s.query = query;
        }
        // Overall: failed if any run failed; done when all 3 are done;
        // running otherwise. bestTime tracks the min of whatever runs
        // have completed so far so partial-done systems can sort into
        // the done group instead of sitting in running until the last
        // round lands.
        const doneRuns = s.runs.filter(r => r.state === "done");
        s.bestTime = doneRuns.length
            ? Math.min(...doneRuns.map(r => r.time))
            : undefined;
        if (s.runs.some(r => r.state === "failed")) {
            s.state = "failed";
            s.note = s.runs.find(r => r.state === "failed").note;
        } else if (s.runs.every(r => r.state === "done")) {
            s.state = "done";
            s.time = s.bestTime;
        } else {
            s.state = "running";
        }
        runAllStatus = status;
        renderRunAll(status);
    }

    // Run all three rounds in the shuffled order; rounds 2 and 3 only
    // fire for systems whose round 1 succeeded.
    await Promise.all(shuffled.map(async (t) => {
        const r1 = await _runOne(t);
        _recordRun(t.name, 0, r1, t.query);
        if (!r1.ok) return;
        const r2 = await _runOne(t);
        _recordRun(t.name, 1, r2, t.query);
        if (!r2.ok) return;
        const r3 = await _runOne(t);
        _recordRun(t.name, 2, r3, t.query);
    }));
    runAllBtn.disabled = false;
}

let runAllStatus = {};
let runAllSelected = null;
let runAllExampleMode = false;

function pickFromRunAll(name) {
    const entry = runAllStatus[name];
    if (!entry) return;
    runAllSelected = name;
    // Switch the system list highlight + state panel to this system.
    if (stateByName[name]) select(name);
    // Rewrite the query textarea + result pane to this system's run.
    // pristineQuery handling depends on which mode the competition is
    // in. In example-mode, entry.query IS the new system's example
    // translation, so re-baseline pristineQuery so subsequent rail
    // clicks see the textarea as pristine and let loadExamples swap
    // in the next system's translation cleanly. In custom-mode,
    // entry.query is the user's edited string; leaving pristineQuery
    // alone keeps loadExamples from thinking the edit is pristine
    // and replacing it with that system's example.
    if (entry.query) {
        queryEl.value = entry.query;
        if (runAllExampleMode) pristineQuery = entry.query;
    }
    if (entry.payload) {
        resultsByName[name] = entry.payload;
        showResult(entry.payload);
    }
    // Update URL: prefer the X-Query-Id for sharability, fall back
    // to a system-scoped permalink so reload at least reopens the
    // right system.
    const u = new URL(window.location.href);
    if (entry.qid) {
        u.searchParams.set("q", entry.qid);
    } else {
        u.searchParams.delete("q");
    }
    window.history.replaceState({}, "", u.toString());
    renderRunAll(runAllStatus);  // re-paint to highlight the selected row
}

let runAllLast = {};

function _runAllRowKey(s) {
    const runs = (s.runs || []).map(r => {
        if (!r) return "-";
        if (r.state === "done") return `d:${r.time}`;
        if (r.state === "failed") return `f`;
        if (r.state === "pending") return `p`;
        return r.state;
    }).join("|");
    return `${s.state}|${runs}`;
}

function renderRunAll(status) {
    const done = [], failed = [], running = [];
    for (const [name, s] of Object.entries(status)) {
        if (s.state === "failed") failed.push({name, ...s});
        // Include partial-done systems in the timed group so the
        // table sorts as soon as the first run lands rather than
        // waiting for all three rounds.
        else if (s.bestTime != null) done.push({name, ...s});
        else running.push({name, ...s});
    }
    done.sort((a, b) => a.bestTime - b.bestTime);
    failed.sort((a, b) => a.name.localeCompare(b.name));
    running.sort((a, b) => a.name.localeCompare(b.name));
    // Diff against the previous render so only rows whose status
    // string actually changed get the flash animation; otherwise the
    // mere act of re-sorting would re-animate everyone every tick.
    const changed = new Set();
    for (const [name, s] of Object.entries(status)) {
        const key = _runAllRowKey(s);
        if (runAllLast[name] !== undefined && runAllLast[name] !== key) {
            changed.add(name);
        }
        runAllLast[name] = key;
    }
    const tbody = runAllTable.querySelector("tbody");
    tbody.innerHTML = "";
    const fragment = document.createDocumentFragment();
    const all = [...done, ...failed, ...running];
    for (let i = 0; i < all.length; i++) {
        const row = all[i];
        const tr = document.createElement("tr");
        const cls = [row.state];
        if (changed.has(row.name)) cls.push("flash");
        if (runAllSelected === row.name) cls.push("selected");
        tr.className = cls.join(" ");
        tr.dataset.name = row.name;
        tr.addEventListener("click", () => pickFromRunAll(row.name));
        const td1 = document.createElement("td");
        td1.textContent = row.name;
        tr.appendChild(td1);
        const runs = row.runs || [{state: row.state, time: row.time, note: row.note}];
        for (let k = 0; k < 3; k++) {
            const td = document.createElement("td");
            td.className = "time";
            const r = runs[k];
            if (!r || r.state === "pending") {
                td.textContent = "—";
                td.classList.add("pending");
            } else if (r.state === "done") {
                td.textContent = `${r.time.toFixed(3)} s`;
            } else if (r.state === "failed") {
                td.textContent = "failed";
                td.title = r.note || "";
            } else {
                td.textContent = "running";
            }
            tr.appendChild(td);
        }
        fragment.appendChild(tr);
    }
    tbody.appendChild(fragment);
    runAllOrder = all.map(r => r.name);
}

// Up/down navigation through the rail. The aside is focusable
// (tabindex=0) so the user can tab into it; arrow keys then walk
// the current sort order and pick the next/prev row.
let runAllOrder = [];
runAllSection.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    if (!runAllOrder.length) return;
    e.preventDefault();
    let i = runAllOrder.indexOf(runAllSelected);
    if (i === -1) i = e.key === "ArrowDown" ? -1 : runAllOrder.length;
    const step = e.key === "ArrowDown" ? 1 : -1;
    const next = runAllOrder[Math.max(0, Math.min(runAllOrder.length - 1, i + step))];
    pickFromRunAll(next);
    // Keep the picked row in view inside the scrollable rail.
    const sel = runAllTable.querySelector("tr.selected");
    if (sel) sel.scrollIntoView({block: "nearest"});
});

runAllBtn.addEventListener("click", runAll);
