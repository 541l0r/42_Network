# API_42 Data Visualization Scaffold

This repository is a minimal static site that fetches data from the 42 API and streams it into a Godot WebGL export. Use it as the shell around your visualizations: drop your Godot build inside `godot/`, wire up a `postMessage` listener in the exported HTML, and the UI in `index.html` will deliver fresh payloads straight from the API.

---

## Reference

### Specification

- **Current version:** v2 (`https://api.intra.42.fr/v2`)
- **Protocol:** HTTPS only. All payloads are JSON, blank fields use `null`, timestamps are ISO 8601.
- **Authentication:** OAuth2. Applications obtain a Client ID/Secret, perform an authorization code flow, and receive bearer tokens. Use `Authorization: Bearer <token>`; query parameter `access_token` is also accepted but discouraged.
- **Errors:**  
  - `400` malformed request  
  - `401` unauthorized (missing/expired token)  
  - `403` forbidden/insufficient scope  
  - `404` not found  
  - `422` validation failure  
  - `500` server error  
  - `Connection refused` typically indicates HTTP instead of HTTPS.
- **Scopes:** Define the permissions granted to a token. If the scope is insufficient the API returns `403` with a `WWW-Authenticate` header describing the missing scopes.
- **Pagination:** Index endpoints return 30 items per page by default. Use either `page`/`per_page` (up to 100 where allowed) or JSON:API style `page[number]`/`page[size]`. Pagination metadata appears in the `Link` header plus `X-Page`, `X-Per-Page`, and `X-Total`.
- **Filtering:** Use `filter[field]=value`. Multiple values are comma-separated (`filter[pool_month]=september,july`).
- **Sorting:** Pass `sort=field1,-field2`. Prefix with `-` for descending order.
- **Rate limiting:** 2 requests/second and 1200/hour per application by default. Check app dashboard for custom quotas.
- **JSON:API (deprecated):** Alpha support via `Content-Type: application/vnd.api+json`.
- **Token inspection:** `GET https://api.intra.42.fr/oauth/token/info` with an `Authorization` header returns metadata about the active token.

### Getting informations about your token

```bash
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  https://api.intra.42.fr/oauth/token/info
# => {"resource_owner_id":74,"scopes":["public"],...}
```

### Exporting/refreshing tokens via CLI helper

A small helper lives in `scripts/token_manager.sh` so you no longer have to juggle manual `curl` commands.

1. Create `.oauth_config` (git-ignored) with your credentials:

   ```ini
   CLIENT_ID="u-xxxx"
   CLIENT_SECRET="s-xxxx"
   REDIRECT_URI="http://localhost:8000/callback"
   SCOPE="public"
   ```

2. Print the authorize URL, open it in a browser, and approve:

   ```bash
   ./scripts/token_manager.sh auth-url
   ```

3. Capture the `code` in your terminal by running a temporary callback server:

   ```bash
   ./scripts/token_manager.sh listen
   # After you see "Authorization code: XXXX", copy the code and stop the script (Ctrl+C after it exits).
   ```

4. Exchange the code and persist tokens:

   ```bash
   ./scripts/token_manager.sh exchange "<paste-code-here>"
   # ACCESS_TOKEN / REFRESH_TOKEN stored in .oauth_state
   ```

5. Refresh later with a single command:

   ```bash
   ./scripts/token_manager.sh refresh
   ```

6. Test any endpoint using the saved access token:

   ```bash
   ./scripts/token_manager.sh call /v2/me
   ./scripts/token_manager.sh call "/v2/users/archimede/locations?per_page=100"
   ```

The helper writes `.oauth_state` (ignored by git) containing the latest access/refresh tokens and expiry timestamp, so subsequent commands always pick up the newest credentials.

---

## Guides

### Getting started

1. Create an application on the 42 intranet (“My apps” dashboard). Record the Client ID, Client Secret, and redirect URI. **Never commit these secrets.**
2. Exchange the authorization code for an access token using the OAuth2 token endpoint.
3. Paste short-lived tokens into this scaffold’s UI or configure a small proxy that signs server-side requests.
4. Use the endpoint dropdown or type custom endpoints to pull JSON into your Godot visualization.

### Web application flow

1. Redirect users to `https://api.intra.42.fr/oauth/authorize?client_id=...&redirect_uri=...&response_type=code&scope=...`.
2. After users approve, exchange the code:

   ```bash
   curl -X POST https://api.intra.42.fr/oauth/token \
     -u "$CLIENT_ID:$CLIENT_SECRET" \
     -d "grant_type=authorization_code" \
     -d "code=$AUTH_CODE" \
     -d "redirect_uri=https://your.app/callback"
   ```

3. Store the returned access token securely (and refresh token if applicable). Pass the access token to this UI through environment variables or a lightweight API proxy.

### Example application profile

| Field            | Value (example)                                  |
| ---------------- | ------------------------------------------------ |
| Name             | 42AuditTool                                      |
| Description      | CLI helper for exploring the 42 API              |
| Application type | Various                                          |
| Website          | `http://localhost`                               |
| Redirect URI     | `http://localhost/callback`                      |
| Rate limit       | 2 req/s (default)                                |

> Replace Client ID/Secret with your own secure values. Source control should only track environment variable names (e.g., `CLIENT_ID`, `CLIENT_SECRET`) or secrets stored in `.env.local` ignored by git.

### Contributing

1. Fork the repository or create a new branch.
2. Update `index.html`, `src/main.js`, or styling as needed.
3. Document any new endpoints or visualization flows in this README.
4. Submit a pull request detailing API usage changes, rate-limit considerations, and deployment steps.

---

## Static shell overview

### Features

- Token-aware fetch form with a few starter endpoints (`/v2/me`, `/v2/projects_users`, `/v2/locations`).
- Optional campus / cursus filters appended automatically when the endpoint does not already include them.
- Event log + raw payload viewer to help iterate on the data contract between JavaScript and Godot.
- Auto-detects a Web export located in `godot/index.html` and embeds it via an iframe.

### Quick start

1. **Install dependencies** – none required. Everything is vanilla HTML/CSS/JS.
2. **Serve locally**

   ```sh
   # from the repo root
   python -m http.server 4173
   # or use your favorite static file server
   ```

3. Visit `http://localhost:4173`, paste a short-lived bearer token, pick an endpoint, and hit **Fetch data**.
4. Export your Godot project for the Web and copy the generated files into `godot/`. Make sure the entry file is named `index.html`.

> ⚠️ **CORS notice:** `https://api.intra.42.fr` currently disallows browser requests from arbitrary origins. When hosting this UI publicly you will need a very small proxy (Netlify Edge function, Cloudflare Worker, etc.) that attaches your server-side credentials and forwards responses back to the browser. Local testing with a development proxy (e.g., `vite dev --proxy` or `local-cors-proxy`) works as well.

### Wiring the Godot client

1. In your exported Web build (the HTML file Godot generates), register a message handler:

   ```html
   <script>
     window.addEventListener("message", (event) => {
       if (event.origin !== window.location.origin && event.origin !== "null") return;
       if (event.data?.type === "API_PAYLOAD") {
         const payload = event.data.payload;
         // TODO: forward payload into your Godot game via Godot's JavaScript bridge
       }
     });
   </script>
   ```

2. Inside Godot, use `JavaScriptBridge.get_interface("window").postMessage(...)` (Godot 4) or the equivalent in Godot 3 to acknowledge messages or request more data. Hitting the **Ping Godot client** button in the shell UI helps you confirm the bridge.

### Customizing the data flow

- The fetch logic lives in `src/main.js`. Extend `fetch42()` or add new helpers if you want to call additional endpoints, transform data, or batch multiple requests before forwarding them to Godot.
- Update the endpoint dropdown in `index.html` with any frequently-used queries.
- `assets/styles.css` defines the UI theme; feel free to adapt it to match your Godot experience.

### Security checklist

- Never ship long-lived client secrets inside this static bundle. Use short-lived bearer tokens that you mint via a secure backend or CLI.
- Disable the **Remember token** checkbox if you are on a shared machine; it stores the token in `localStorage`.
- When deploying publicly, terminate TLS and proxy API calls through infrastructure you control so the token never touches untrusted browsers.

### Next steps

- Connect the Godot build and deserialize the payload in GDScript.
- Build charts or procedural visuals based on the data you receive.
- Add automated fetching intervals (e.g., poll every minute) or websocket bridges if your use case benefits from live updates.

## Data ingestion & cron

- Reference tables stored in Postgres: achievements, campuses, cursus, projects (with *_users, users, locations ready but currently empty unless you import user-scoped data).
- Fetch helpers live in `scripts/helpers/`; upsert entrypoints are `scripts/update_{achievements,campuses,cursus,projects}.sh`. Run all at once with `scripts/update_tables.sh` (quiet summary with row deltas, export size, last fetch stamp).
- Fetch scopes: campuses only active/public with `users_count > 1`; projects use `range[updated_at]` deltas; achievements always full (API lacks reliable updated_at); cursus is tiny and refetched once per day.
- Cron wrappers in `scripts/cron/` (documented in `scripts/cron/README.md`):
  - `run_daily_update.sh` – daily at 03:00 UTC, logs to `logs/update_tables_daily.log`.
  - `run_token_refresh.sh` – hourly at minute 05, logs to `logs/42_token_refresh.log`.
- Exports live under `exports/` with stamp files (`.last_fetch_epoch`, `.last_updated_at`, `.last_fetch_stats`) for delta tracking. Running `make` + `scripts/update_tables.sh` from a clean DB will recreate the schema and refill reference tables.
# 42_Network

## Docker stack (nginx + API proxy + MariaDB)

This repo now includes a small Docker setup to serve the static UI, proxy 42 API calls through a backend, and store fetched payloads in MariaDB.

1. Copy `api/.env.example` to `api/.env` and fill in `CLIENT_ID`, `CLIENT_SECRET`, `REFRESH_TOKEN`, and (optionally) `ACCESS_TOKEN`. Redirect must match your 42 app (e.g., `http://localhost:8000/callback`) and be allowed in the 42 dashboard.
2. Start the stack:
   ```sh
   docker compose up --build
   ```
3. Visit `http://localhost:8000` for the static UI. The backend proxy is available at `/api`:
   - `POST /api/fetch` with JSON `{ "endpoint": "/v2/me" }` fetches from 42 and stores the response.
   - `GET /api/history` returns the last 100 stored rows.

Services:
- `web` (nginx) serves the static site and proxies `/api` to the backend.
- `api` (Node/Express) refreshes tokens via `REFRESH_TOKEN`, calls `https://api.intra.42.fr`, and writes payloads to MariaDB.
- `db` (MariaDB) persists responses in `responses` (id, endpoint, payload JSON, created_at). Data lives in the `db_data` volume.

Important:
- Keep `CLIENT_SECRET` and `REFRESH_TOKEN` server-side only (never ship to the browser).
- 42 may rotate refresh tokens on refresh; update your secrets store if that happens.


https://api.intra.42.fr/oauth/authorize?client_id=u-s4t2ud-4078c640940b116c44605ee9c4dfd55ae6bac6ec4da0bc7ea5368342e93da469&redirect_uri=http://localhost:8000/callback&response_type=code&scope=public
