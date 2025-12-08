"use strict";

/**
 * Export users from specific coalitions that belong to campus Brussels (campus_id=12),
 * plus all coalitions for campus_id=12. Requires ACCESS_TOKEN env var.
 *
 * Usage:
 *   ACCESS_TOKEN=xxx node scripts/export_bxl_coalition53.js
 *
 * Outputs:
 *   exports/coalitions_brussels_52_53_54.json
 *   exports/coalitions_campus12.json
 */

const fs = require("fs");
const path = require("path");

const API_ROOT = "https://api.intra.42.fr";
const TOKEN = process.env.ACCESS_TOKEN;
if (!TOKEN) {
  console.error("ACCESS_TOKEN env var is required");
  process.exit(1);
}

const CAMPUS_ID = 12; // Brussels
const TARGET_COALITION_IDS = [52, 53, 54]; // Brussels coalition IDs
const PER_PAGE = 100;

async function fetchJson(url, attempt = 1) {
  const resp = await fetch(url, {
    headers: { Authorization: `Bearer ${TOKEN}` },
  });
  if (resp.status === 429 && attempt <= 5) {
    const retryAfter = Number(resp.headers.get("retry-after")) || 2 * attempt;
    await sleep(retryAfter * 1000);
    return fetchJson(url, attempt + 1);
  }
  if (!resp.ok) {
    const msg = await resp.text();
    throw new Error(`HTTP ${resp.status} for ${url}: ${msg}`);
  }
  const data = await resp.json();
  const totalPages = Number(resp.headers.get("x-total-pages")) || null;
  return { data, totalPages };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function fetchCoalitionUsers(coalitionId) {
  const rows = [];
  let page = 1;
  let totalPages = null;
  while (totalPages === null || page <= totalPages) {
    const url = `${API_ROOT}/v2/coalitions_users?filter[coalition_id]=${coalitionId}&page=${page}&per_page=${PER_PAGE}`;
    const { data, totalPages: tp } = await fetchJson(url);
    rows.push(...data);
    totalPages = tp ?? (data.length < PER_PAGE ? page : null);
    if (!data.length) break;
    page += 1;
  }
  return rows;
}

async function fetchCampusCoalitions(campusId) {
  const rows = [];
  let page = 1;
  let totalPages = null;
  while (totalPages === null || page <= totalPages) {
    const url = `${API_ROOT}/v2/coalitions?filter[campus_id]=${campusId}&page=${page}&per_page=${PER_PAGE}`;
    const { data, totalPages: tp } = await fetchJson(url);
    rows.push(...data);
    totalPages = tp ?? (data.length < PER_PAGE ? page : null);
    if (!data.length) break;
    page += 1;
  }
  return rows;
}

async function fetchCampusUsers(campusId) {
  const rows = [];
  let page = 1;
  let totalPages = null;
  while (totalPages === null || page <= totalPages) {
    const url = `${API_ROOT}/v2/campus/${campusId}/users?page=${page}&per_page=${PER_PAGE}`;
    const { data, totalPages: tp } = await fetchJson(url);
    rows.push(...data);
    totalPages = tp ?? (data.length < PER_PAGE ? page : null);
    if (!data.length) break;
    page += 1;
  }
  return rows;
}

async function main() {
  console.log("Fetching coalition users for coalitions", TARGET_COALITION_IDS.join(", "));
  const coalitionUsers = [];
  for (const cid of TARGET_COALITION_IDS) {
    const rows = await fetchCoalitionUsers(cid);
    coalitionUsers.push(...rows);
  }

  console.log("Fetching campus Brussels users list...");
  const campusUsers = await fetchCampusUsers(CAMPUS_ID);
  const campusSet = new Map(campusUsers.map((u) => [u.id, u.login]));

  const brussels = coalitionUsers
    .map((cu) => {
      const login = campusSet.get(cu.user_id);
      return {
        user_id: cu.user_id,
        login,
        campus_id: login ? CAMPUS_ID : null,
        campus_name: login ? "Belgium" : null,
        coalition_id: cu.coalition_id,
        score: cu.score,
        rank: cu.rank,
        updated_at: cu.updated_at,
      };
    })
    .filter((row) => row.campus_id === CAMPUS_ID && row.score > 0);

  console.log(`Brussels entries (score>0): ${brussels.length}`);

  console.log("Fetching all coalitions for campus Brussels...");
  const campusCoalitions = await fetchCampusCoalitions(CAMPUS_ID);

  const outDir = path.join(process.cwd(), "exports");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, "coalitions_brussels_52_53_54.json"),
    JSON.stringify(brussels, null, 2)
  );
  fs.writeFileSync(path.join(outDir, "coalitions_campus12.json"), JSON.stringify(campusCoalitions, null, 2));
  console.log("Wrote exports/coalitions_brussels_52_53_54.json and exports/coalitions_campus12.json");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
