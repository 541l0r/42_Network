"use strict";

const API_ROOT = "https://api.intra.42.fr";
const STORAGE_KEYS = {
  token: "api42.token",
  remember: "api42.remember",
};
const GODOT_TARGET_ORIGIN = window.location.origin.startsWith("http")
  ? window.location.origin
  : "*";

const els = {
  status: document.getElementById("status-text"),
  form: document.getElementById("settings-form"),
  token: document.getElementById("token-input"),
  endpoint: document.getElementById("endpoint-select"),
  campus: document.getElementById("campus-input"),
  cursus: document.getElementById("cursus-input"),
  remember: document.getElementById("remember-token"),
  ping: document.getElementById("ping-godot"),
  godotFrame: document.getElementById("godot-frame"),
  godotBadge: document.getElementById("godot-status"),
  output: document.getElementById("data-output"),
  log: document.getElementById("event-log"),
  logTemplate: document.getElementById("log-entry"),
  clearLog: document.getElementById("clear-log"),
};

const state = {
  godotReady: false,
};

function init() {
  restorePreferences();
  attachListeners();
  detectGodotBuild();
  logEvent("Scaffold ready. Configure your API token to start fetching data.");
}

function attachListeners() {
  els.form.addEventListener("submit", handleSubmit);
  els.remember.addEventListener("change", handleRememberToggle);
  els.ping.addEventListener("click", () => {
    sendToGodot({ type: "PING", timestamp: Date.now() });
    logEvent("Ping sent to Godot client.");
  });
  els.clearLog.addEventListener("click", () => (els.log.innerHTML = ""));

  window.addEventListener("message", (event) => {
    if (event.origin !== window.location.origin) return;
    if (!event.data) return;
    logEvent(`Godot message: ${JSON.stringify(event.data)}`);
  });
}

async function detectGodotBuild() {
  try {
    const response = await fetch("./godot/index.html", { method: "HEAD" });
    if (!response.ok) throw new Error("missing");
    els.godotFrame.src = "./godot/index.html";
    els.godotBadge.textContent = "Loaded";
    els.godotBadge.classList.remove("badge-warning");
    els.godotBadge.classList.add("badge-success");
    state.godotReady = true;
    logEvent("Godot build detected and loaded into the iframe.");
  } catch {
    state.godotReady = false;
    els.godotFrame.removeAttribute("src");
    els.godotBadge.textContent = "No build detected";
    els.godotBadge.classList.add("badge-warning");
    els.godotBadge.classList.remove("badge-success");
    logEvent("No Godot build found at ./godot/index.html", "error");
  }
}

function restorePreferences() {
  const rememberValue = localStorage.getItem(STORAGE_KEYS.remember);
  const shouldRemember = rememberValue === "true";
  els.remember.checked = shouldRemember;
  if (shouldRemember) {
    const savedToken = localStorage.getItem(STORAGE_KEYS.token);
    if (savedToken) {
      els.token.value = savedToken;
      logEvent("Token restored from local storage.");
    }
  }
}

function handleRememberToggle() {
  const remember = els.remember.checked;
  localStorage.setItem(STORAGE_KEYS.remember, remember);
  if (!remember) {
    localStorage.removeItem(STORAGE_KEYS.token);
  } else if (els.token.value) {
    localStorage.setItem(STORAGE_KEYS.token, els.token.value);
  }
}

async function handleSubmit(event) {
  event.preventDefault();
  const token = els.token.value.trim();
  const endpoint = els.endpoint.value;
  if (!token) {
    logEvent("Token is required.", "error");
    return;
  }
  if (els.remember.checked) {
    localStorage.setItem(STORAGE_KEYS.token, token);
  }

  try {
    setStatus("Fetching data…");
    const response = await fetch42({
      token,
      endpoint,
      campusId: els.campus.value,
      cursusId: els.cursus.value,
    });
    renderData(response);
    sendToGodot({ type: "API_PAYLOAD", payload: response });
    setStatus("Data fetched successfully.");
    logEvent(`Fetched ${Array.isArray(response.data) ? response.data.length : 1} record(s).`);
  } catch (error) {
    console.error(error);
    setStatus("Fetch failed. See log for details.");
    logEvent(error.message, "error");
  }
}

async function fetch42({ token, endpoint, campusId, cursusId }) {
  const url = new URL(endpoint, API_ROOT);
  appendQuery(url, "campus_id", campusId);
  appendQuery(url, "cursus_id", cursusId);

  const response = await fetch(url.toString(), {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
  });

  if (!response.ok) {
    const payload = await safeParse(response);
    throw new Error(`API error ${response.status}: ${JSON.stringify(payload)}`);
  }

  const data = await response.json();
  return {
    meta: {
      endpoint: url.pathname + url.search,
      fetchedAt: new Date().toISOString(),
    },
    data,
  };
}

function appendQuery(url, key, value) {
  if (!value && value !== 0) return;
  if (!url.searchParams.has(key)) {
    url.searchParams.set(key, value);
  }
}

async function safeParse(response) {
  try {
    return await response.json();
  } catch {
    return { message: await response.text() };
  }
}

function renderData(payload) {
  els.output.textContent = JSON.stringify(payload, null, 2);
}

function sendToGodot(message) {
  if (!state.godotReady || !els.godotFrame.contentWindow) {
    logEvent("Godot iframe is not ready.", "error");
    return;
  }
  els.godotFrame.contentWindow.postMessage(message, GODOT_TARGET_ORIGIN);
}

function logEvent(message, level = "info") {
  const node = els.logTemplate.content.cloneNode(true);
  const li = node.querySelector("li");
  li.classList.add(level);
  node.querySelector(".timestamp").textContent = new Date().toLocaleTimeString();
  node.querySelector(".message").textContent = message;
  els.log.prepend(node);
}

function setStatus(text) {
  els.status.textContent = text;
}

document.addEventListener("DOMContentLoaded", init);
