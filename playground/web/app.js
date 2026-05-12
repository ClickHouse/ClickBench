// ClickBench Playground — minimal vanilla-JS client.
//
// Talks to the host API. Three things happen here:
//   1. On load, fetch /api/systems and populate the system dropdown. Pre-select
//      whatever's in the URL hash (e.g. #clickhouse) or the first one.
//   2. On selection change, poll /api/system/<name> every 2s and update the
//      state pill so the user can see when provisioning finishes / a VM is
//      restarted by the watchdog.
//   3. On "Run query", POST the SQL to /api/query?system=<name>, parse the
//      response headers for timing, render bytes as text (best-effort UTF-8).

const $ = (sel) => document.querySelector(sel);

const sysSelect = $("#system");
const queryEl = $("#query");
const runBtn = $("#run");
const statePill = $("#state-pill");
const outEl = $("#output");
const timeEl = $("#time");
const wallEl = $("#wall");
const bytesEl = $("#bytes");
const truncEl = $("#truncated");
const exitEl = $("#exit");
const stateBlob = $("#state-blob");

let pollTimer = null;
let knownSystems = [];

async function loadSystems() {
    const r = await fetch("/api/systems");
    knownSystems = await r.json();
    knownSystems.sort((a, b) => a.display_name.localeCompare(b.display_name));
    sysSelect.innerHTML = "";
    for (const s of knownSystems) {
        const o = document.createElement("option");
        o.value = s.name;
        o.textContent = `${s.display_name}  (${s.data_format})`;
        sysSelect.appendChild(o);
    }
    // Allow #clickhouse style deep links
    const hash = (location.hash || "").slice(1);
    if (hash && knownSystems.some(s => s.name === hash)) {
        sysSelect.value = hash;
    }
    onSystemChange();
}

async function pollState() {
    const name = sysSelect.value;
    if (!name) return;
    try {
        const r = await fetch(`/api/system/${encodeURIComponent(name)}`);
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const j = await r.json();
        statePill.textContent = j.state || "?";
        statePill.className = `pill ${j.state || ""}`;
        stateBlob.textContent = JSON.stringify(j, null, 2);
    } catch (e) {
        statePill.textContent = "err";
        statePill.className = "pill down";
        stateBlob.textContent = String(e);
    }
}

function onSystemChange() {
    if (pollTimer) clearInterval(pollTimer);
    location.hash = sysSelect.value;
    pollState();
    pollTimer = setInterval(pollState, 2000);
}

async function runQuery() {
    const name = sysSelect.value;
    const sql = queryEl.value;
    if (!sql.trim()) return;
    runBtn.disabled = true;
    outEl.textContent = "(running …)";
    timeEl.textContent = "…";
    wallEl.textContent = "…";
    bytesEl.textContent = "—";
    truncEl.textContent = "—";
    exitEl.textContent = "—";

    const t0 = performance.now();
    try {
        const r = await fetch(`/api/query?system=${encodeURIComponent(name)}`, {
            method: "POST",
            body: sql,
            headers: {"Content-Type": "application/octet-stream"},
        });
        const body = await r.arrayBuffer();
        const txt = bytesToText(body);
        outEl.textContent = txt || "(no output)";

        const h = (k) => r.headers.get(k);
        const qt = h("X-Query-Time");
        const wt = h("X-Wall-Time");
        timeEl.textContent = qt ? `${parseFloat(qt).toFixed(3)} s (script)` : "—";
        wallEl.textContent = wt ? `${parseFloat(wt).toFixed(3)} s` : `${((performance.now() - t0) / 1000).toFixed(3)} s`;
        bytesEl.textContent = h("X-Output-Bytes") || body.byteLength;
        truncEl.textContent = h("X-Output-Truncated") === "1" ? "yes" : "no";
        exitEl.textContent = h("X-Exit-Code") || r.status;
        if (r.status >= 400) {
            const err = h("X-Error");
            if (err) outEl.textContent = `(error)\n${err}\n\n` + outEl.textContent;
        }
    } catch (e) {
        outEl.textContent = `(client error)\n${e}`;
    } finally {
        runBtn.disabled = false;
    }
}

function bytesToText(buf) {
    try {
        return new TextDecoder("utf-8", {fatal: false}).decode(buf);
    } catch {
        return [...new Uint8Array(buf)].map(b => String.fromCharCode(b)).join("");
    }
}

sysSelect.addEventListener("change", onSystemChange);
runBtn.addEventListener("click", runQuery);
queryEl.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") runQuery();
});

loadSystems();
