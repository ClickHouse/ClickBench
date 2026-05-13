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

const listEl = $("#system-list");
const queryEl = $("#query");
const runBtn = $("#run");
const selectedEl = $("#selected-system");
const outEl = $("#output");
const outLabelEl = $("#output-label");
const timeEl = $("#time");
const stateBlob = $("#state-blob");
const lastErrorEl = $("#last-error");
const exampleSel = $("#example");
const uiActive = ["#ui-active", "#ui-query", "#ui-stats", "#ui-output"].map($);
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
    const r = await fetch("/api/systems");
    catalog = await r.json();
    catalog.sort((a, b) => a.display_name.localeCompare(b.display_name));
    renderList();
    const hash = (location.hash || "").slice(1);
    if (hash && catalog.some(s => s.name === hash)) {
        select(hash);
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
    // Click on the already-selected system = shortcut to run the
    // current query, as long as that system is in a queryable state.
    if (name === selected) {
        const s = stateByName[name];
        const st = s && s.state;
        if (st && st !== "down" && st !== "provisioning") {
            runQuery();
        }
        return;
    }
    select(name);
}

function select(name) {
    selected = name;
    location.hash = name;
    selectedEl.textContent = name;
    for (const row of listEl.children) {
        row.classList.toggle("selected", row.dataset.name === name);
    }
    if (stateByName[name]) {
        stateBlob.textContent = JSON.stringify(stateByName[name], null, 2);
    }
    showResult(resultsByName[name]);
    // If the user has typed something, keep it across system switches —
    // they're likely composing one query against multiple systems. Only
    // when the textarea is empty does loadExamples populate Q1.
    loadExamples(name);
    refreshDownUI();
}

async function loadExamples(name) {
    let qs = queriesByName[name];
    if (!qs) {
        try {
            const r = await fetch(`/api/queries/${encodeURIComponent(name)}`);
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

function showResult(r) {
    if (!r) {
        outEl.textContent = "";
        timeEl.textContent = "—";
        outLabelEl.textContent = "Output";
        return;
    }
    outEl.textContent = r.output;
    timeEl.textContent = r.time;
    outLabelEl.textContent = r.truncated === "yes" ? "Output (truncated)" : "Output";
}

async function pollState() {
    try {
        const r = await fetch("/api/state");
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

async function runQuery() {
    if (!selected) return;
    const sql = queryEl.value;
    if (!sql.trim()) return;
    runBtn.disabled = true;
    outEl.textContent = "(running …)";
    timeEl.textContent = "…";
    outLabelEl.textContent = "Output";

    const target = selected;  // capture in case the user switches mid-flight
    const t0 = performance.now();
    let payload = null;
    try {
        const r = await fetch(`/api/query?system=${encodeURIComponent(target)}`, {
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
            const err = h("X-Error");
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
exampleSel.addEventListener("change", () => {
    const i = parseInt(exampleSel.value, 10);
    const qs = queriesByName[selected];
    if (qs && !isNaN(i) && i >= 0 && i < qs.length) {
        queryEl.value = qs[i];
        pristineQuery = qs[i];
    }
});
queryEl.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") runQuery();
});

(async function init() {
    // Treat the HTML default ("SELECT COUNT(*) FROM hits;") as pristine
    // so first-system selection is free to swap it for the first
    // example.
    pristineQuery = queryEl.value;
    await loadCatalog();
    await pollState();
    pollTimer = setInterval(pollState, 2000);
})();
