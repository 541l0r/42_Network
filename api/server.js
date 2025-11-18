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

if (!CLIENT_ID || !CLIENT_SECRET || !REFRESH_TOKEN) {
  console.error("Missing CLIENT_ID, CLIENT_SECRET, or REFRESH_TOKEN. Populate api/.env.");
  process.exit(1);
}

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
  return conn;
}

async function refreshAccessToken() {
  const response = await axios.post(
    `${API_ROOT}/oauth/token`,
    new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: REFRESH_TOKEN,
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

app.listen(PORT, () => {
  console.log(`API proxy listening on :${PORT}`);
});
