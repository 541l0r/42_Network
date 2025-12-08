import express from "express";
import axios from "axios";
import mysql from "mysql2/promise";

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

const app = express();
app.use(express.json({ limit: "2mb" }));

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

app.listen(PORT, () => {
  console.log(`API proxy listening on :${PORT}`);
});
