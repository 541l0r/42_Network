import express from "express";
import axios from "axios";
import mysql from "mysql2/promise";
import { WebSocketServer } from "ws";
import { createServer } from "http";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";
import pg from "pg";

const {
  API_ROOT = "https://api.intra.42.fr",
  PORT = 3000,
  CLIENT_ID,
  CLIENT_SECRET,
  REDIRECT_URI = "http://localhost:8000/callback",
  ACCESS_TOKEN = "",
  REFRESH_TOKEN,
  DB_HOST = "db",
  DB_PORT = 3306,
  DB_NAME = "api42",
  DB_USER = "api42",
  DB_PASSWORD = "api42",
} = process.env;

let refreshToken = REFRESH_TOKEN;
let cachedAccessToken = ACCESS_TOKEN;
let accessTokenExpiresAt = 0;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");

const app = express();
app.use(express.json({ limit: "2mb" }));

// Serve static files from repo root
app.use(express.static(rootDir));

// WebSocket setup for real-time updates
const server = createServer(app);
const wss = new WebSocketServer({ server });
let wsClients = [];

wss.on("connection", (ws) => {
  console.log("[WS] Client connected");
  wsClients.push(ws);

  ws.on("close", () => {
    wsClients = wsClients.filter((c) => c !== ws);
    console.log("[WS] Client disconnected. Remaining:", wsClients.length);
  });

  ws.on("error", (err) => {
    console.error("[WS] Error:", err);
  });
});

// Broadcast user updates to all connected WebSocket clients
function broadcastUserUpdate(userData) {
  const message = JSON.stringify({
    type: "user_update",
    timestamp: new Date().toISOString(),
    data: userData,
  });

  wsClients.forEach((client) => {
    if (client.readyState === 1) {
      client.send(message);
    }
  });
}

// Root route - redirect to globe
app.get("/", (req, res) => {
  res.redirect("/globe.html");
});

async function connectDb() {
  const conn = await mysql.createConnection({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_USER,
    password: DB_PASSWORD,
    database: DB_NAME,
  });
  await conn.execute(
    `CREATE TABLE IF NOT EXISTS responses (
      id BIGINT AUTO_INCREMENT PRIMARY KEY,
      endpoint VARCHAR(255) NOT NULL,
      payload JSON NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )`
  );
  await conn.execute(
    `CREATE TABLE IF NOT EXISTS coalition_scores (
      api_id BIGINT PRIMARY KEY,
      coalition_id BIGINT NOT NULL,
      user_id BIGINT NOT NULL,
      score INT NOT NULL,
      rank INT NOT NULL,
      created_at DATETIME(3) NOT NULL,
      updated_at DATETIME(3) NOT NULL,
      fetched_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    )`
  );
  return conn;
}

async function refreshAccessToken() {
  const response = await axios.post(
    `${API_ROOT}/oauth/token`,
    new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      redirect_uri: REDIRECT_URI,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
    { headers: { "Content-Type": "application/x-www-form-urlencoded" } }
  );

  cachedAccessToken = response.data.access_token;
  const expiresIn = response.data.expires_in || 0;
  accessTokenExpiresAt = Math.floor(Date.now() / 1000) + expiresIn;

  // 42 may rotate refresh tokens; persist if present
  if (response.data.refresh_token) {
    refreshToken = response.data.refresh_token;
    console.warn("Received rotated refresh_token; update your secrets storage.");
  }
}

async function ensureAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (!cachedAccessToken || now >= accessTokenExpiresAt - 30) {
    await refreshAccessToken();
  }
  return cachedAccessToken;
}

app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/auth/42", (_req, res) => {
  const authorizeUrl = `${API_ROOT}/oauth/authorize?client_id=${encodeURIComponent(
    CLIENT_ID
  )}&redirect_uri=${encodeURIComponent(REDIRECT_URI)}&response_type=code&scope=public`;
  res.redirect(authorizeUrl);
});

app.get("/callback", async (req, res) => {
  const code = req.query.code;
  if (!code) {
    return res.status(400).send("Missing ?code=");
  }

  try {
    const response = await axios.post(
      `${API_ROOT}/oauth/token`,
      new URLSearchParams({
        grant_type: "authorization_code",
        code,
        redirect_uri: REDIRECT_URI,
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
      }),
      { headers: { "Content-Type": "application/x-www-form-urlencoded" } }
    );

    cachedAccessToken = response.data.access_token;
    refreshToken = response.data.refresh_token || refreshToken;
    const expiresIn = response.data.expires_in || 0;
    accessTokenExpiresAt = Math.floor(Date.now() / 1000) + expiresIn;

    res.json({
      message: "Tokens received. Update your server config with the new refresh_token if needed.",
      access_token: cachedAccessToken,
      refresh_token: refreshToken,
      expires_in: expiresIn,
    });
  } catch (err) {
    console.error(err.response?.data || err.message);
    const status = err.response?.status || 500;
    res.status(status).json({ error: "exchange_failed", details: err.response?.data || err.message });
  }
});

const handleFetch = async (req, res) => {
  const { endpoint = "/v2/me", store = true } = req.body || {};
  if (!endpoint.startsWith("/")) {
    return res.status(400).json({ error: "endpoint must start with /" });
  }

  try {
    const token = await ensureAccessToken();
    const apiResp = await axios.get(`${API_ROOT}${endpoint}`, {
      headers: { Authorization: `Bearer ${token}` },
    });

    if (store) {
      const conn = await connectDb();
      await conn.execute("INSERT INTO responses (endpoint, payload) VALUES (?, ?)", [
        endpoint,
        JSON.stringify(apiResp.data),
      ]);
      await conn.end();
    }

    res.json({ endpoint, data: apiResp.data });
  } catch (err) {
    console.error(err.response?.data || err.message);
    const status = err.response?.status || 500;
    res.status(status).json({ error: "fetch_failed", details: err.response?.data || err.message });
  }
};

app.post("/api/fetch", handleFetch);
app.post("/fetch", handleFetch);

const handleHistory = async (_req, res) => {
  try {
    const conn = await connectDb();
    const [rows] = await conn.execute(
      "SELECT id, endpoint, created_at, payload FROM responses ORDER BY created_at DESC LIMIT 100"
    );
    await conn.end();
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: "db_failed", details: err.message });
  }
};

app.get("/api/history", handleHistory);
app.get("/history", handleHistory);

const handleCoalitionScores = async (req, res) => {
  const userId = req.body?.user_id;
  if (!userId) {
    return res.status(400).json({ error: "user_id is required" });
  }

  const perPage = 100;
  let page = 1;
  let totalPages = 1;
  const allRows = [];
  let conn;

  try {
    const token = req.body?.access_token || (await ensureAccessToken());

    while (page <= totalPages) {
      const endpoint = `/v2/users/${userId}/coalitions_users?page=${page}&per_page=${perPage}`;
      const apiResp = await axios.get(`${API_ROOT}${endpoint}`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      const data = Array.isArray(apiResp.data) ? apiResp.data : [];
      allRows.push(...data);

      const headerTotal = Number(apiResp.headers["x-total-pages"]);
      if (Number.isFinite(headerTotal) && headerTotal > 0) {
        totalPages = headerTotal;
      } else if (data.length < perPage) {
        totalPages = page;
      }

      if (data.length === 0) break;
      page += 1;
    }

    conn = await connectDb();
    await conn.beginTransaction();
    const insertSql = `
      INSERT INTO coalition_scores (api_id, coalition_id, user_id, score, rank, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE
        coalition_id=VALUES(coalition_id),
        user_id=VALUES(user_id),
        score=VALUES(score),
        rank=VALUES(rank),
        created_at=VALUES(created_at),
        updated_at=VALUES(updated_at),
        fetched_at=CURRENT_TIMESTAMP
    `;

    for (const row of allRows) {
      await conn.execute(insertSql, [
        row.id,
        row.coalition_id,
        row.user_id,
        row.score,
        row.rank,
        new Date(row.created_at),
        new Date(row.updated_at),
      ]);
    }

    await conn.commit();

    res.json({
      user_id: userId,
      stored: allRows.length,
      pages_fetched: Math.max(page - 1, 1),
    });
  } catch (err) {
    console.error(err.response?.data || err.message);
    if (conn) {
      try {
        await conn.rollback();
      } catch {
        // ignore rollback failure
      }
    }
    res.status(err.response?.status || 500).json({
      error: "coalition_fetch_failed",
      details: err.response?.data || err.message,
    });
  } finally {
    if (conn) {
      try {
        await conn.end();
      } catch {
        // ignore close failure
      }
    }
  }
};

const handleActiveCoalitionScores = async (req, res) => {
  const perPage = 100;
  const maxPages = Number(req.body?.max_pages) || null;
  const filterKey = req.body?.filter_key || "this_year_score";
  const filterValue = req.body?.filter_value || "gt:0";
  let page = 1;
  let totalPages = Number.POSITIVE_INFINITY;
  let headerTotalPages = null;
  const allRows = [];
  let conn;

  try {
    const token = req.body?.access_token || (await ensureAccessToken());

    while (page <= totalPages) {
      if (maxPages && page > maxPages) break;

      const search = new URLSearchParams();
      search.append(`filter[${filterKey}]`, filterValue);
      search.append("page", String(page));
      search.append("per_page", String(perPage));
      const endpoint = `/v2/coalitions_users?${search.toString()}`;
      const apiResp = await axios.get(`${API_ROOT}${endpoint}`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      const data = Array.isArray(apiResp.data) ? apiResp.data : [];
      allRows.push(...data);

      const headerPages = Number(apiResp.headers["x-total-pages"]);
      const headerTotal = Number(apiResp.headers["x-total"]);
      if (Number.isFinite(headerPages) && headerPages > 0) {
        totalPages = headerPages;
        headerTotalPages = headerPages;
      } else if (Number.isFinite(headerTotal) && headerTotal > 0) {
        totalPages = Math.ceil(headerTotal / perPage);
        headerTotalPages = totalPages;
      } else if (data.length < perPage) {
        totalPages = page;
      }

      if (data.length === 0) break;
      page += 1;
    }

    conn = await connectDb();
    await conn.beginTransaction();
    const insertSql = `
      INSERT INTO coalition_scores (api_id, coalition_id, user_id, score, rank, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE
        coalition_id=VALUES(coalition_id),
        user_id=VALUES(user_id),
        score=VALUES(score),
        rank=VALUES(rank),
        created_at=VALUES(created_at),
        updated_at=VALUES(updated_at),
        fetched_at=CURRENT_TIMESTAMP
    `;

    for (const row of allRows) {
      await conn.execute(insertSql, [
        row.id,
        row.coalition_id,
        row.user_id,
        row.score,
        row.rank,
        new Date(row.created_at),
        new Date(row.updated_at),
      ]);
    }

    await conn.commit();

    res.json({
      filter: { key: filterKey, value: filterValue },
      stored: allRows.length,
      pages_fetched: Math.max(page - 1, 1),
      reported_total_pages: headerTotalPages,
      max_pages_respected: maxPages || undefined,
    });
  } catch (err) {
    console.error(err.response?.data || err.message);
    if (conn) {
      try {
        await conn.rollback();
      } catch {
        // ignore rollback failure
      }
    }
    res.status(err.response?.status || 500).json({
      error: "active_coalition_fetch_failed",
      details: err.response?.data || err.message,
    });
  } finally {
    if (conn) {
      try {
        await conn.end();
      } catch {
        // ignore close failure
      }
    }
  }
};

const handleCoalitionIdScores = async (req, res) => {
  const coalitionId = req.body?.coalition_id;
  if (!coalitionId) {
    return res.status(400).json({ error: "coalition_id is required" });
  }

  const perPage = 100;
  const maxPages = Number(req.body?.max_pages) || null;
  let page = 1;
  let totalPages = Number.POSITIVE_INFINITY;
  let headerTotalPages = null;
  const allRows = [];
  let conn;

  try {
    const token = req.body?.access_token || (await ensureAccessToken());

    while (page <= totalPages) {
      if (maxPages && page > maxPages) break;

      const search = new URLSearchParams();
      search.append("filter[coalition_id]", coalitionId);
      search.append("page", String(page));
      search.append("per_page", String(perPage));
      const endpoint = `/v2/coalitions_users?${search.toString()}`;
      const apiResp = await axios.get(`${API_ROOT}${endpoint}`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      const data = Array.isArray(apiResp.data) ? apiResp.data : [];
      allRows.push(...data);

      const headerPages = Number(apiResp.headers["x-total-pages"]);
      const headerTotal = Number(apiResp.headers["x-total"]);
      if (Number.isFinite(headerPages) && headerPages > 0) {
        totalPages = headerPages;
        headerTotalPages = headerPages;
      } else if (Number.isFinite(headerTotal) && headerTotal > 0) {
        totalPages = Math.ceil(headerTotal / perPage);
        headerTotalPages = totalPages;
      } else if (data.length < perPage) {
        totalPages = page;
      }

      if (data.length === 0) break;
      page += 1;
    }

    conn = await connectDb();
    await conn.beginTransaction();
    const insertSql = `
      INSERT INTO coalition_scores (api_id, coalition_id, user_id, score, rank, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE
        coalition_id=VALUES(coalition_id),
        user_id=VALUES(user_id),
        score=VALUES(score),
        rank=VALUES(rank),
        created_at=VALUES(created_at),
        updated_at=VALUES(updated_at),
        fetched_at=CURRENT_TIMESTAMP
    `;

    for (const row of allRows) {
      await conn.execute(insertSql, [
        row.id,
        row.coalition_id,
        row.user_id,
        row.score,
        row.rank,
        new Date(row.created_at),
        new Date(row.updated_at),
      ]);
    }

    await conn.commit();

    res.json({
      coalition_id: coalitionId,
      stored: allRows.length,
      pages_fetched: Math.max(page - 1, 1),
      reported_total_pages: headerTotalPages,
      max_pages_respected: maxPages || undefined,
    });
  } catch (err) {
    console.error(err.response?.data || err.message);
    if (conn) {
      try {
        await conn.rollback();
      } catch {
        // ignore rollback failure
      }
    }
    res.status(err.response?.status || 500).json({
      error: "coalition_id_fetch_failed",
      details: err.response?.data || err.message,
    });
  } finally {
    if (conn) {
      try {
        await conn.end();
      } catch {
        // ignore close failure
      }
    }
  }
};

app.post("/api/coalition-scores", handleCoalitionScores);
app.post("/coalition-scores", handleCoalitionScores);
app.post("/api/coalition-scores/active", handleActiveCoalitionScores);
app.post("/coalition-scores/active", handleActiveCoalitionScores);
app.post("/api/coalition-scores/coalition", handleCoalitionIdScores);
app.post("/coalition-scores/coalition", handleCoalitionIdScores);

// Endpoint to receive user upsert events from pipeline
app.post("/api/user-updated", express.json(), (req, res) => {
  const {
    id,
    login,
    campus_id,
    wallet,
    correction_point,
    location,
    change_type,
  } = req.body;

  const userData = {
    id,
    login,
    campus_id,
    wallet,
    correction_point,
    location,
    change_type: change_type || "update",
  };

  console.log(`[UPDATE] User ${id} (${login}) - Campus: ${campus_id}, Wallet: ${wallet}`);
  broadcastUserUpdate(userData);
  res.json({ ok: true });
});

// Endpoint to get current stats
// Broadcast pipeline metrics to all WebSocket clients
let lastFetchCount = 0;
let lastFetchTime = Date.now();

function broadcastPipelineMetrics(metrics) {
  const message = JSON.stringify({
    type: "pipeline_metrics",
    timestamp: new Date().toISOString(),
    data: metrics,
  });

  wsClients.forEach((client) => {
    if (client.readyState === 1) {
      client.send(message);
    }
  });
}

// Helper to read queue file sizes
function getQueueStats() {
  const readQueueSize = (filename) => {
    const filepath = path.join(rootDir, ".backlog", filename);
    if (!fs.existsSync(filepath)) return 0;
    const content = fs.readFileSync(filepath, "utf8");
    return content.trim().split("\n").filter(line => line.length > 0).length;
  };
  
  return {
    fetch_queue: readQueueSize("fetch_queue.txt"),
    process_queue: readQueueSize("process_queue.txt"),
  };
}

// Helper to get active process count
function getProcessStats() {
  try {
    // In Docker, ps aux won't see host processes
    // Read from config file instead - this is the EXPECTED configuration
    const configFile = path.join(rootDir, 'scripts', 'config', 'agents.config');
    let fetchers = 3;
    let upserters = 1;
    
    if (fs.existsSync(configFile)) {
      const content = fs.readFileSync(configFile, 'utf8');
      const fetcherMatch = content.match(/FETCHER_INSTANCES\s*=\s*(\d+)/);
      if (fetcherMatch) {
        fetchers = parseInt(fetcherMatch[1]);
      }
    }
    
    // Return the configured values (these should be running)
    return { fetchers, upserters };
  } catch (error) {
    console.warn('Could not determine process count:', error.message);
    return { fetchers: 3, upserters: 1 };
  }
}

app.get("/api/stats", async (req, res) => {
  try {
    // Return mock stats for now - the data will be counted from user updates
    res.json({
      total_users: 39971,
      campuses: [1, 12, 13, 14, 16, 20, 21, 22, 25, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 69],
    });
  } catch (err) {
    console.error("[Stats] Error:", err);
    res.status(500).json({ error: err.message });
  }
});

// Endpoint to get pipeline metrics
app.get("/api/pipeline/metrics", (req, res) => {
  try {
    const queues = getQueueStats();
    const processes = getProcessStats();
    const now = Date.now();
    const elapsed = (now - lastFetchTime) / 1000; // seconds
    
    res.json({
      timestamp: new Date().toISOString(),
      queues,
      processes,
      rate_limit_delay: 4.0,
      estimated_throughput: queues.fetch_queue > 0 ? (60 / 4.0).toFixed(1) : 0,
    });
  } catch (err) {
    console.error("[Pipeline Metrics] Error:", err);
    res.status(500).json({ error: err.message });
  }
});

// Periodic metrics broadcast (every 5 seconds)
setInterval(() => {
  const queues = getQueueStats();
  const processes = getProcessStats();
  const now = Date.now();
  const elapsed = (now - lastFetchTime) / 1000; // seconds
  
  broadcastPipelineMetrics({
    queues,
    processes,
    rate_limit_delay: 4.0,
    estimated_throughput: queues.fetch_queue > 0 ? (60 / 4.0).toFixed(1) : 0,
  });
  
  lastFetchTime = now;
}, 5000);

server.listen(PORT, () => {
  console.log(`API proxy listening on :${PORT}`);
  console.log(`WebSocket server ready at ws://localhost:${PORT}`);
});
